// Everything that lives in ~/.config/openwispr: .env settings, the log file,
// and the dictation history. Shared by the menu-bar app and the settings window.
import Cocoa

let DEFAULT_MODEL = "openai/gpt-4o-mini-transcribe"
let OPENROUTER_URL = "https://openrouter.ai/api/v1/audio/transcriptions"
let OPENROUTER_KEY_URL = "https://openrouter.ai/api/v1/key"
let OPENAI_URL = "https://api.openai.com/v1/audio/transcriptions"
let OPENAI_KEY_URL = "https://api.openai.com/v1/models"
/// Transcription sessions take `?intent=transcription`. Passing the model as a
/// `?model=` query param instead is rejected with `invalid_model` — that param is
/// for voice-agent models only, so the model goes in the session.update payload.
let OPENAI_REALTIME_URL = "wss://api.openai.com/v1/realtime?intent=transcription"
/// Single source of truth is Info.plist — the DMG is named from the same value.
let APP_VERSION = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.1"

let SUGGESTED_MODELS = [
    "microsoft/mai-transcribe-1.5",
    "openai/gpt-4o-transcribe",
    "openai/gpt-4o-mini-transcribe",
    "openai/whisper-1",
    "mistralai/voxtral-mini-transcribe",
]

/// Where the audio goes. OpenRouter is one key for many vendors' models; OpenAI
/// direct is the only way to reach models OpenRouter hasn't picked up yet, and
/// the only one with a realtime streaming endpoint.
enum Provider: String, CaseIterable {
    case openrouter, openai

    var title: String { self == .openrouter ? "OpenRouter" : "OpenAI" }
    var keyVar: String { self == .openrouter ? "OPENROUTER_API_KEY" : "OPENAI_API_KEY" }
    var modelVar: String { self == .openrouter ? "MODEL" : "OPENAI_MODEL" }
    var keyPlaceholder: String { self == .openrouter ? "sk-or-v1-…" : "sk-…" }
    var transcriptionsURL: String { self == .openrouter ? OPENROUTER_URL : OPENAI_URL }
    var keysPage: String {
        self == .openrouter ? "https://openrouter.ai/settings/keys"
                            : "https://platform.openai.com/api-keys"
    }

    var defaultModel: String { self == .openrouter ? DEFAULT_MODEL : "gpt-4o-mini-transcribe" }

    var suggestedModels: [String] {
        self == .openrouter ? SUGGESTED_MODELS
                            : ["gpt-4o-transcribe", "gpt-4o-mini-transcribe", "whisper-1"]
    }
}

// MARK: - Live (streaming) transcription

/// Streams transcript deltas over a WebSocket while you are still talking,
/// instead of uploading a finished clip. OpenAI-only — OpenRouter has no
/// realtime endpoint.
let LIVE_MODEL = "gpt-live-transcribe"
/// The transcription intent accepts ONLY transcription models — the socket
/// rejects voice-agent models (gpt-realtime-2.1 etc.) with invalid_value, so
/// they don't belong here no matter what the pricing page groups them with.
let LIVE_MODELS = ["gpt-live-transcribe", "gpt-transcribe", "gpt-4o-transcribe", "gpt-4o-mini-transcribe", "gpt-realtime-whisper"]
/// The realtime session speaks 24 kHz mono PCM16 both ways.
let LIVE_SAMPLE_RATE: Double = 24000

extension Notification.Name {
    static let owSettingsChanged = Notification.Name("openwispr.settingsChanged")
    static let owRulesChanged    = Notification.Name("openwispr.rulesChanged")
    static let owHistoryChanged  = Notification.Name("openwispr.historyChanged")
}

final class Config {
    static let shared = Config()

    let dir: URL

    private init() {
        dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/openwispr", isDirectory: true)
        Config.migrateLegacyDirectory(into: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Config.seedDefaults(in: dir)
    }

    /// First launch: write the behaviour defaults so a fresh install arrives with
    /// speech cleanup, correction-learning and sound cues already switched on.
    /// Never writes a key — that is the user's to paste in Settings.
    private static func seedDefaults(in dir: URL) {
        let env = dir.appendingPathComponent(".env")
        guard !FileManager.default.fileExists(atPath: env.path) else { return }
        let text = """
        # Open-Wispr settings — edit here or from the settings window.
        # Add your own OpenRouter key in Settings → Transcription (nothing ships with one).
        CLEANUP=1
        AUTOLEARN=1
        SOUNDS=1

        """
        try? text.write(to: env, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: env.path)
    }

    /// The app used to be called Wispr-Soro and kept everything in
    /// ~/.config/wisprsoro. Carry that over once so an upgrade keeps the key,
    /// dictionary and history instead of starting from scratch.
    private static func migrateLegacyDirectory(into dir: URL) {
        let fm = FileManager.default
        let legacy = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/wisprsoro", isDirectory: true)
        guard fm.fileExists(atPath: legacy.path), !fm.fileExists(atPath: dir.path) else { return }
        guard (try? fm.moveItem(at: legacy, to: dir)) != nil else { return }

        let oldLog = dir.appendingPathComponent("wisprsoro.log")
        let newLog = dir.appendingPathComponent("openwispr.log")
        if fm.fileExists(atPath: oldLog.path), !fm.fileExists(atPath: newLog.path) {
            try? fm.moveItem(at: oldLog, to: newLog)
        }

        // The old LaunchAgent points at the old binary — drop it and re-register
        // under the new label so "launch at login" keeps working.
        let oldAgent = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.sorower.wisprsoro.plist")
        if fm.fileExists(atPath: oldAgent.path) {
            try? fm.removeItem(at: oldAgent)
            DispatchQueue.main.async { Config.shared.launchAtLogin = true }
        }
    }

    var envURL: URL { dir.appendingPathComponent(".env") }
    var logURL: URL { dir.appendingPathComponent("openwispr.log") }
    var rulesURL: URL { dir.appendingPathComponent("replacements.json") }
    var historyURL: URL { dir.appendingPathComponent("history.json") }

    // MARK: - .env

    func env() -> [String: String] {
        var out: [String: String] = [:]
        guard let text = try? String(contentsOf: envURL, encoding: .utf8) else { return out }
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") || trimmed.isEmpty { continue }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            let val = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            out[key] = val
        }
        return out
    }

    func write(_ env: [String: String]) {
        let text = env.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n") + "\n"
        try? text.write(to: envURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: envURL.path)
        NotificationCenter.default.post(name: .owSettingsChanged, object: nil)
    }

    func set(_ key: String, _ value: String?) {
        var e = env()
        if let v = value, !v.isEmpty { e[key] = v } else { e.removeValue(forKey: key) }
        write(e)
    }

    func flag(_ key: String, default def: Bool) -> Bool {
        guard let v = env()[key]?.lowercased() else { return def }
        return !(v == "0" || v == "false" || v == "no" || v == "off")
    }

    func setFlag(_ key: String, _ on: Bool) { set(key, on ? "1" : "0") }

    /// Existing installs have no PROVIDER line and an OpenRouter key, so the
    /// default has to stay OpenRouter — an upgrade must not silently repoint
    /// their audio at a provider they have no key for.
    var provider: Provider {
        get {
            let raw = ProcessInfo.processInfo.environment["OPENWISPR_PROVIDER"] ?? env()["PROVIDER"] ?? ""
            return Provider(rawValue: raw.lowercased()) ?? .openrouter
        }
        set { set("PROVIDER", newValue.rawValue) }
    }

    func apiKey(for provider: Provider) -> String? {
        if let k = ProcessInfo.processInfo.environment[provider.keyVar], !k.isEmpty { return k }
        if let k = env()[provider.keyVar], !k.isEmpty { return k }
        return nil
    }

    var apiKey: String? { apiKey(for: provider) }

    /// Each provider keeps its own model, because the names aren't portable:
    /// OpenRouter wants "openai/gpt-4o-transcribe", OpenAI wants "gpt-4o-transcribe".
    /// Live mode gets its own slot again — those models only exist on the
    /// realtime endpoint, so they'd break the batch path if they leaked into it.
    func model(for provider: Provider, live: Bool = false) -> String {
        if let m = ProcessInfo.processInfo.environment["OPENWISPR_MODEL"], !m.isEmpty { return m }
        if live {
            if let m = env()["LIVE_MODEL"], !m.isEmpty { return m }
            return LIVE_MODEL
        }
        if let m = env()[provider.modelVar], !m.isEmpty { return m }
        return provider.defaultModel
    }

    var model: String { model(for: provider, live: liveEnabled) }

    /// The realtime WebSocket path. Only OpenAI has one, so the toggle is inert
    /// on OpenRouter rather than being a setting that silently does nothing.
    var live: Bool { flag("LIVE", default: false) }
    var liveEnabled: Bool { provider == .openai && live }

    var cleanup: Bool { flag("CLEANUP", default: true) }
    var autoLearn: Bool { flag("AUTOLEARN", default: true) }
    var sounds: Bool { flag("SOUNDS", default: true) }

    // MARK: - Log

    func log(_ msg: String) {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "[\(fmt.string(from: Date()))] \(msg)\n"
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? line.write(to: logURL, atomically: true, encoding: .utf8)
        }
    }

    /// Last chunk of the log — enough for the Activity pane without loading a huge file.
    func logTail(maxBytes: Int = 120_000) -> String {
        guard let data = try? Data(contentsOf: logURL) else { return "" }
        let slice = data.count > maxBytes ? data.suffix(maxBytes) : data
        return String(decoding: slice, as: UTF8.self)
    }

    func clearLog() {
        try? "".write(to: logURL, atomically: true, encoding: .utf8)
        log("Log cleared")
    }

    // MARK: - Launch at login

    var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.openwispr.app.plist")
    }

    /// A plain LaunchAgent plist — launchd picks it up at the next login. Chosen over
    /// SMAppService because that needs a Developer-ID-signed bundle in /Applications.
    var launchAtLogin: Bool {
        get { FileManager.default.fileExists(atPath: launchAgentURL.path) }
        set {
            let fm = FileManager.default
            if newValue {
                guard let exec = Bundle.main.executableURL?.path else { return }
                let plist: [String: Any] = [
                    "Label": "com.openwispr.app",
                    // --background: start quietly at login without opening the window.
                    "ProgramArguments": [exec, "--background"],
                    "RunAtLoad": true,
                    "KeepAlive": false,
                    "ProcessType": "Interactive",
                ]
                try? fm.createDirectory(at: launchAgentURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
                if let data = try? PropertyListSerialization.data(fromPropertyList: plist,
                                                                  format: .xml, options: 0) {
                    try? data.write(to: launchAgentURL)
                }
            } else {
                try? fm.removeItem(at: launchAgentURL)
            }
        }
    }
}

// MARK: - Dictation history

struct HistoryEntry: Codable {
    var date: Date
    var text: String
    var seconds: Double
    var model: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = (try? c.decode(Date.self, forKey: .date)) ?? Date()
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        seconds = (try? c.decode(Double.self, forKey: .seconds)) ?? 0
        model = (try? c.decode(String.self, forKey: .model)) ?? ""
    }

    init(date: Date, text: String, seconds: Double, model: String) {
        self.date = date; self.text = text; self.seconds = seconds; self.model = model
    }
}

final class HistoryStore {
    static let shared = HistoryStore()
    private(set) var entries: [HistoryEntry] = []   // newest first
    private let cap = 200

    private init() { load() }

    private func load() {
        guard let data = try? Data(contentsOf: Config.shared.historyURL),
              let list = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return }
        entries = list
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = .prettyPrinted
        if let data = try? enc.encode(entries) {
            try? data.write(to: Config.shared.historyURL, options: .atomic)
        }
        NotificationCenter.default.post(name: .owHistoryChanged, object: nil)
    }

    func add(text: String, seconds: Double, model: String) {
        entries.insert(HistoryEntry(date: Date(), text: text, seconds: seconds, model: model), at: 0)
        if entries.count > cap { entries.removeLast(entries.count - cap) }
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }
}
