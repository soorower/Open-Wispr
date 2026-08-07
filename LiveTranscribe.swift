// Live streaming transcription over OpenAI's realtime WebSocket.
//
// The batch path in main.swift records a whole clip to disk and uploads it once.
// This one opens a socket the moment you press fn, streams 24 kHz PCM16 out of
// the mic as you speak, and gets transcript deltas back in flight — so by the
// time you let go the text is already written and the paste is instant.
//
// Ownership of mutable state, because two threads are involved:
//   • sendQueue  owns `ready`, `pending`, `stopping` (the audio tap runs on a
//                render thread and must never block on the main queue)
//   • main queue owns the transcript tables — the URLSession delivers every
//                socket event straight to .main, so event handling is serial
import AVFoundation
import Cocoa

final class LiveTranscriber {
    /// Running transcript, fired on the main queue every time it grows.
    var onText: ((String) -> Void)?
    /// Mic level 0…1 for the pill animation, main queue.
    var onLevel: ((CGFloat) -> Void)?
    /// Fired exactly once on the main queue when the session ends.
    var onFinish: ((Result<String, Error>) -> Void)?

    private let model: String
    private let key: String
    private let engine = AVAudioEngine()
    private let sendQueue = DispatchQueue(label: "openwispr.live.send")
    private var session: URLSession?
    private var ws: URLSessionWebSocketTask?
    private var converter: AVAudioConverter?
    private var tapped = false

    // sendQueue-owned
    private var ready = false
    private var pending: [String] = []
    private var stopping = false
    private var commitWhenReady = false

    // main-owned
    private var sentKeywords = true
    private var configured = false
    private var finished = false
    private var order: [String] = []
    private var deltas: [String: String] = [:]
    private var finals: [String: String] = [:]
    private var deadline: Timer?

    init(model: String, key: String) {
        self.model = model
        self.key = key
    }

    /// Everything we have heard so far: a completed transcript wins over the
    /// deltas that built it, and unfinished turns still show their partial text.
    private var transcript: String {
        order.map { finals[$0] ?? deltas[$0] ?? "" }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Start

    func start() throws {
        var req = URLRequest(url: URL(string: OPENAI_REALTIME_URL)!)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        // Delivering socket events on .main keeps event handling serial, so the
        // transcript tables below need no locking.
        let session = URLSession(configuration: .default, delegate: nil, delegateQueue: .main)
        self.session = session
        ws = session.webSocketTask(with: req)
        ws?.resume()
        listen()
        try startEngine()
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw err("No microphone input available")
        }
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                            sampleRate: LIVE_SAMPLE_RATE,
                                            channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw err("Can't resample the mic to 24 kHz")
        }
        // One converter for the whole session — it carries the resampler state,
        // so a fresh one per buffer would click at every boundary.
        self.converter = converter
        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buffer, _ in
            self?.handle(buffer, converter: converter, outFormat: outFormat)
        }
        tapped = true
        engine.prepare()
        try engine.start()
    }

    // MARK: - Audio

    private func handle(_ buffer: AVAudioPCMBuffer,
                        converter: AVAudioConverter,
                        outFormat: AVAudioFormat) {
        report(level: buffer)

        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }

        // The converter pulls until it is satisfied; we have exactly one buffer to
        // give, so every later pull reports "nothing right now" rather than EOF —
        // an endOfStream here would tear down the resampler mid-session.
        var consumed = false
        var convError: NSError?
        converter.convert(to: out, error: &convError) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard convError == nil, out.frameLength > 0, let pcm = out.int16ChannelData else { return }
        append(Data(bytes: pcm[0], count: Int(out.frameLength) * 2))
    }

    private func report(level buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let samples = channel[0]
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += samples[i] * samples[i] }
        let db = 20 * log10(max(sqrt(sum / Float(n)), 1e-7))
        // Same curve the AVAudioRecorder meter feeds the pill, so the bars move
        // identically in both modes.
        let level = CGFloat(max(0, min(1, (db + 50) / 45)))
        DispatchQueue.main.async { self.onLevel?(level) }
    }

    private func append(_ pcm: Data) {
        let audio = pcm.base64EncodedString()
        sendQueue.async {
            guard !self.stopping else { return }
            if self.ready {
                self.send(["type": "input_audio_buffer.append", "audio": audio])
            } else if self.pending.count < 500 {
                // Audio recorded before the session handshake lands — held back
                // rather than dropped, so the first word survives.
                self.pending.append(audio)
            }
        }
    }

    // MARK: - Socket

    private func send(_ payload: [String: Any]) {
        guard let ws = ws,
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        ws.send(.string(text)) { [weak self] error in
            guard let self = self, let error = error else { return }
            DispatchQueue.main.async { self.fail("Connection lost — \(error.localizedDescription)") }
        }
    }

    private func listen() {
        ws?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                guard !self.finished, !self.stopping else { return }
                self.fail(self.ready ? "Connection lost — \(error.localizedDescription)"
                                     : "Couldn't open the live session — check the key has access to \(self.model)")
            case .success(let message):
                switch message {
                case .string(let text): self.event(text)
                case .data(let data): self.event(String(decoding: data, as: UTF8.self))
                @unknown default: break
                }
                self.listen()
            }
        }
    }

    /// `turn_detection` stays null: gpt-live-transcribe rejects it outright
    /// ("Turn detection is not supported for this transcription model"), and the
    /// deltas stream while you talk regardless — the turn only has to be closed
    /// by hand with a commit when you let go. Measured against the live API.
    private func configure(withKeywords: Bool) {
        var transcription: [String: Any] = ["model": model]
        // Your replacement dictionary is exactly the list of words this model
        // keeps getting wrong, so hand it over as hints. Measurably works:
        // the same clip came back "Whisper" without it and "Whispr" with it.
        let hints = ReplacementStore.shared.rules.map { $0.to }.prefix(80)
        if withKeywords, !hints.isEmpty { transcription["keywords"] = Array(hints) }

        let input: [String: Any] = [
            "format": ["type": "audio/pcm", "rate": Int(LIVE_SAMPLE_RATE)],
            "transcription": transcription,
            "turn_detection": NSNull(),
        ]
        send(["type": "session.update",
              "session": ["type": "transcription", "audio": ["input": input]]])
    }

    private func event(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case "session.created", "transcription_session.created":
            configure(withKeywords: sentKeywords)

        case "session.updated", "transcription_session.updated":
            configured = true
            sendQueue.async {
                guard !self.ready else { return }
                self.ready = true
                for chunk in self.pending {
                    self.send(["type": "input_audio_buffer.append", "audio": chunk])
                }
                self.pending.removeAll()
                if self.commitWhenReady { self.send(["type": "input_audio_buffer.commit"]) }
            }

        case "conversation.item.input_audio_transcription.delta":
            guard let id = json["item_id"] as? String,
                  let delta = json["delta"] as? String else { return }
            if deltas[id] == nil, finals[id] == nil { order.append(id) }
            deltas[id, default: ""] += delta
            onText?(transcript)

        case "conversation.item.input_audio_transcription.completed":
            guard let id = json["item_id"] as? String else { return }
            let text = (json["transcript"] as? String) ?? deltas[id] ?? ""
            if deltas[id] == nil, finals[id] == nil { order.append(id) }
            finals[id] = text
            onText?(transcript)
            // Once every turn we know about is final there is nothing left to
            // wait for — don't sit out the rest of the grace period.
            if stoppingOnMain, order.allSatisfy({ finals[$0] != nil }) { complete() }

        case "conversation.item.input_audio_transcription.failed":
            let error = json["error"] as? [String: Any]
            fail((error?["message"] as? String) ?? "The model couldn't transcribe that audio")

        case "error":
            let message = (json["error"] as? [String: Any])?["message"] as? String ?? "Realtime API error"
            // Models differ in which context fields they accept — turn detection
            // is already known to be refused by this one — so a rejected
            // handshake is worth one retry with nothing but the model set,
            // rather than losing live mode over an optional hint.
            if !configured, sentKeywords {
                sentKeywords = false
                Config.shared.log("Live: session.update rejected (\(message)); retrying without keyword hints")
                configure(withKeywords: false)
                return
            }
            fail(message)

        default:
            break
        }
    }

    // MARK: - Stop

    /// Called when you release fn. The mic stops immediately, but the socket gets
    /// a short grace period to turn the last of the audio into text.
    func finish(grace: TimeInterval = 2.0) {
        guard !finished else { return }
        stopEngine()

        // Server VAD ends a turn on silence — and once the mic is off, no silence
        // ever arrives. Send some, so the last sentence finalises instead of
        // hanging on the deltas.
        // Committing closes the turn and is what produces the final transcript.
        // It queues behind the audio already in flight, so nothing is truncated.
        sendQueue.async {
            // If the handshake hasn't landed yet the audio is still queued, so the
            // commit has to wait for the flush or it would close an empty turn.
            if self.ready { self.send(["type": "input_audio_buffer.commit"]) }
            else { self.commitWhenReady = true }
            self.stopping = true
        }
        stoppingOnMain = true
        deadline?.invalidate()
        deadline = Timer.scheduledTimer(withTimeInterval: grace, repeats: false) { [weak self] _ in
            // Grace expired: the deltas we already have are the transcript. This
            // is the safety net that makes the whole thing robust — we never lose
            // text just because a `completed` event didn't arrive.
            self?.complete()
        }
    }

    /// Abandon the session without pasting anything (clip too short, or an error).
    func cancel() {
        guard !finished else { return }
        finished = true
        onFinish = nil
        onText = nil
        onLevel = nil
        teardown()
    }

    private var stoppingOnMain = false

    private func complete() {
        guard !finished else { return }
        finished = true
        deliver(.success(transcript))
    }

    private func fail(_ message: String) {
        guard !finished else { return }
        // Deltas already on screen beat an error message — if we heard anything
        // at all, hand it over instead of throwing the dictation away.
        let salvaged = transcript
        finished = true
        if salvaged.isEmpty {
            deliver(.failure(err(message)))
        } else {
            Config.shared.log("Live: \(message) — keeping the \(salvaged.count) chars already transcribed")
            deliver(.success(salvaged))
        }
    }

    /// The callback is what drops the app's last reference to this object, so it
    /// runs on the next turn of the runloop — after this call stack has unwound
    /// and nothing here will touch `self` again.
    private func deliver(_ result: Result<String, Error>) {
        teardown()
        let callback = onFinish
        onFinish = nil
        onText = nil
        onLevel = nil
        DispatchQueue.main.async { callback?(result) }
    }

    private func stopEngine() {
        if tapped {
            engine.inputNode.removeTap(onBus: 0)
            tapped = false
        }
        if engine.isRunning { engine.stop() }
    }

    private func teardown() {
        deadline?.invalidate()
        deadline = nil
        stopEngine()
        ws?.cancel(with: .goingAway, reason: nil)
        ws = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private func err(_ message: String) -> NSError {
        NSError(domain: "Open-Wispr", code: 3, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
