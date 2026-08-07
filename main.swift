// Open-Wispr — local Wispr Flow alternative.
// fn (hold or tap) -> record mic -> transcribe -> paste at cursor.
//
// Two ways to transcribe: upload the finished clip (OpenRouter or OpenAI), or
// stream it live over OpenAI's realtime socket and watch the text arrive as you
// speak. Both meet again in finishTranscription().
//
// This file is the menu-bar app itself. See also:
//   Config.swift        settings/log/history on disk
//   LiveTranscribe.swift  the streaming realtime path
//   Replacements.swift  the "heard this -> type that" dictionary
//   Corrections.swift   learns a replacement when you fix a word after a paste
//   Theme.swift, SettingsUI.swift, SettingsPanes.swift   the settings window
import Cocoa
import AVFoundation
import ApplicationServices

let HOLD_THRESHOLD: TimeInterval = 0.6   // held longer than this => push-to-talk (release stops)
let MIN_CLIP_SECONDS: TimeInterval = 0.4 // discard accidental blips
let MAX_CLIP_SECONDS: TimeInterval = 300 // safety auto-stop
let FN_KEYCODE: UInt16 = 63

enum AppState { case idle, recording, transcribing }
enum PillState { case idle, recording, transcribing, success, attention, learned }

func mouseScreen() -> NSScreen {
    let loc = NSEvent.mouseLocation
    return NSScreen.screens.first { NSMouseInRect(loc, $0.frame, false) }
        ?? NSScreen.main ?? NSScreen.screens[0]
}

final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Pill (floating status bar)

final class PillView: NSView {
    var state: PillState = .idle { didSet { needsDisplay = true } }
    var level: CGFloat = 0      // mic level 0..1 while recording
    var phase: CGFloat = 0      // animation phase
    var onClick: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }

    private func barColor(_ i: Int, of n: Int, alpha: CGFloat) -> NSColor {
        let t = CGFloat(i) / CGFloat(n - 1)
        // cyan -> violet -> pink sweep
        return NSColor(calibratedHue: 0.52 + t * 0.38, saturation: 0.85, brightness: 1.0, alpha: alpha)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()

        let n = 9
        let mid = CGFloat(n - 1) / 2
        let insetX = r.height * 0.5
        let barW = (r.width - insetX * 2) / CGFloat(2 * n - 1)
        for i in 0..<n {
            let fi = CGFloat(i)
            let centerWeight = 1.0 - abs(fi - mid) / mid * 0.45
            var h: CGFloat = 3
            var color = NSColor.white.withAlphaComponent(0.4)
            switch state {
            case .idle:
                break
            case .recording:
                let s = sin(phase + fi * 0.85)
                let wobble = 0.30 + 0.70 * s * s
                let effLevel = 0.25 + 0.75 * level
                h = 3 + (r.height - 11) * effLevel * wobble * centerWeight
                color = barColor(i, of: n, alpha: 1.0)
            case .transcribing:
                let wave = 0.5 + 0.5 * sin(phase * 0.7 + fi * 0.6)
                h = 3 + (r.height - 14) * 0.55 * wave * centerWeight
                color = barColor(i, of: n, alpha: 0.65)
            case .success:
                h = 4
                color = NSColor.systemGreen
            case .attention:
                h = 4
                color = NSColor.systemOrange
            case .learned:
                // brief teal sparkle — "I just remembered that word"
                let wave = 0.5 + 0.5 * sin(phase * 1.4 + fi * 1.1)
                h = 4 + 7 * wave * centerWeight
                color = Theme.teal
            }
            h = max(3, min(h, r.height - 8))
            let rect = NSRect(x: insetX + fi * barW * 2, y: (r.height - h) / 2, width: barW, height: h)
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: barW / 2, yRadius: barW / 2).fill()
        }
    }
}

final class Pill {
    static let idleSize = NSSize(width: 54, height: 22)
    static let activeSize = NSSize(width: 106, height: 40)
    let panel: NSPanel
    let view: PillView

    var state: PillState = .idle {
        didSet {
            view.state = state
            let size = (state == .recording || state == .transcribing) ? Pill.activeSize : Pill.idleSize
            if panel.frame.size != size {
                let f = panel.frame
                panel.setFrame(NSRect(x: f.midX - size.width / 2, y: f.minY,
                                      width: size.width, height: size.height), display: true)
            }
        }
    }

    init(onClick: @escaping () -> Void) {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Pill.idleSize),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        view = PillView(frame: NSRect(origin: .zero, size: Pill.idleSize))
        view.autoresizingMask = [.width, .height]
        view.onClick = onClick
        panel.contentView = view
        panel.orderFrontRegardless()
    }

    var frame: NSRect { panel.frame }

    func reposition(on screen: NSScreen) {
        let f = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: f.minY + 26))
    }
}

// MARK: - Last-transcript popup (click the pill)

final class TranscriptPopup {
    private let panel: NSPanel
    private let effect: NSVisualEffectView
    private let title: NSTextField
    private let scroll: NSScrollView
    private let textView: NSTextView
    private let copyButton: FirstMouseButton
    private(set) var isVisible = false
    var onCopy: (() -> Void)?

    private let width: CGFloat = 340
    private let pad: CGFloat = 12

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 120),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        effect = NSVisualEffectView(frame: panel.contentView!.bounds)
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(effect)

        title = NSTextField(labelWithString: "Last transcript")
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor

        textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .labelColor
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.documentView = textView

        copyButton = FirstMouseButton(title: "Copy", target: nil, action: nil)
        copyButton.bezelStyle = .rounded

        effect.addSubview(title)
        effect.addSubview(scroll)
        effect.addSubview(copyButton)

        copyButton.target = self
        copyButton.action = #selector(copyClicked)
    }

    @objc private func copyClicked() { onCopy?() }

    func show(text: String, abovePillFrame pf: NSRect) {
        textView.string = text
        let textW = width - pad * 2
        let measured = (text as NSString).boundingRect(
            with: NSSize(width: textW - 6, height: 10_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 13)]).height
        let textH = min(max(measured + 10, 26), 150)

        let buttonH: CGFloat = 26
        let titleH: CGFloat = 15
        let panelH = pad + buttonH + 8 + textH + 6 + titleH + 10

        copyButton.frame = NSRect(x: width - pad - 70, y: pad, width: 70, height: buttonH)
        scroll.frame = NSRect(x: pad, y: pad + buttonH + 8, width: textW, height: textH)
        textView.frame = NSRect(x: 0, y: 0, width: textW, height: textH)
        title.frame = NSRect(x: pad, y: pad + buttonH + 8 + textH + 6, width: textW, height: titleH)

        panel.setFrame(NSRect(x: pf.midX - width / 2, y: pf.maxY + 10, width: width, height: panelH),
                       display: true)
        panel.orderFrontRegardless()
        isVisible = true
    }

    func repositionAbove(pillFrame pf: NSRect) {
        panel.setFrameOrigin(NSPoint(x: pf.midX - width / 2, y: pf.maxY + 10))
    }

    func hide() {
        panel.orderOut(nil)
        isVisible = false
    }
}

// MARK: - Transient message bubble

final class HUD {
    private let panel: NSPanel
    private let label: NSTextField
    private var hideTimer: Timer?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 40),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false

        let effect = NSVisualEffectView(frame: panel.contentView!.bounds)
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]

        label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.alignment = .center
        label.textColor = .labelColor
        label.frame = NSRect(x: 8, y: 11, width: 284, height: 18)
        label.autoresizingMask = [.width]

        effect.addSubview(label)
        panel.contentView?.addSubview(effect)
    }

    func show(_ text: String, autohide: TimeInterval? = nil) {
        DispatchQueue.main.async {
            self.hideTimer?.invalidate()
            self.label.stringValue = text
            // Size to the message so longer notices (a learned word pair) aren't clipped.
            let measured = (text as NSString).size(withAttributes: [.font: self.label.font!]).width
            let width = min(max(measured + 34, 200), 520)
            self.panel.setFrame(NSRect(x: 0, y: 0, width: width, height: 40), display: false)
            self.label.frame = NSRect(x: 8, y: 11, width: width - 16, height: 18)
            let f = mouseScreen().visibleFrame
            self.panel.setFrameOrigin(NSPoint(x: f.midX - self.panel.frame.width / 2, y: f.minY + 76))
            self.panel.orderFrontRegardless()
            if let t = autohide {
                self.hideTimer = Timer.scheduledTimer(withTimeInterval: t, repeats: false) { _ in
                    self.panel.orderOut(nil)
                }
            }
        }
    }

    func hide() {
        DispatchQueue.main.async {
            self.hideTimer?.invalidate()
            self.panel.orderOut(nil)
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var hud = HUD()
    var pill: Pill!
    var popup = TranscriptPopup()
    var state: AppState = .idle
    var recorder: AVAudioRecorder?
    /// Non-nil only in live mode — it replaces `recorder` for that dictation.
    var live: LiveTranscriber?
    var liveStartedAt = Date()
    var fnMonitor: Any?
    var fnIsDown = false
    var fnPressedAt = Date.distantPast
    var startedByThisPress = false
    var maxLenTimer: Timer?
    var animTimer: Timer?
    var screenTimer: Timer?
    var successTimer: Timer?
    var clipboardRestoreWork: DispatchWorkItem?
    var lastTranscript = ""
    var toggleMenuItem: NSMenuItem!
    var cleanupMenuItem: NSMenuItem!
    var autoLearnMenuItem: NSMenuItem!
    var learnedTimer: Timer?
    let watcher = CorrectionWatcher()

    let audioURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("openwispr.wav")

    // MARK: - Config / logging (all state lives in Config.shared)

    func apiKey() -> String? { Config.shared.apiKey }
    func modelName() -> String { Config.shared.model }
    func log(_ msg: String) { Config.shared.log(msg) }
    var cleanupEnabled: Bool { Config.shared.cleanup }
    var autoLearnEnabled: Bool { Config.shared.autoLearn }

    func playSound(_ name: String) {
        guard Config.shared.sounds else { return }
        NSSound(named: name)?.play()
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setStatusIcon("🎤")
        buildMenu()

        pill = Pill(onClick: { [weak self] in self?.pillClicked() })
        repositionUI()
        screenTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.repositionUI()
        }

        let axOpts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(axOpts)
        log("Launched. Accessibility trusted: \(trusted). Model: \(modelName())")

        AVCaptureDevice.requestAccess(for: .audio) { granted in
            self.log("Microphone access granted: \(granted)")
        }

        fnMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }

        watcher.onLearn = { [weak self] from, to in self?.learned(from: from, to: to) }

        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged),
                                               name: .owSettingsChanged, object: nil)

        let ruleCount = ReplacementStore.shared.rules.count
        if ruleCount > 0 { log("Loaded \(ruleCount) replacement rule(s)") }

        if apiKey() == nil {
            hud.show("⚠️ No API key — add one in the window that just opened", autohide: 3)
        }

        // Show the window on launch so the app is never just an invisible menu-bar
        // icon. Skipped when launchd starts us at login (--background in the
        // LaunchAgent), where stealing focus would be rude.
        if !CommandLine.arguments.contains("--background") {
            let pane = CommandLine.arguments.firstIndex(of: "--settings").flatMap { i in
                CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : nil
            }
            SettingsUI.shared.present(selecting: pane ?? "general")
        }
    }

    @objc func settingsChanged() {
        cleanupMenuItem.state = cleanupEnabled ? .on : .off
        autoLearnMenuItem.state = autoLearnEnabled ? .on : .off
    }

    // Menu-bar icon: same waveform mark as the app logo. The idle version is a
    // template image so macOS tints it for light/dark menu bars automatically.
    func makeStatusImage(color: NSColor?) -> NSImage {
        let size = NSSize(width: 20, height: 18)
        let img = NSImage(size: size, flipped: false) { rect in
            let heights: [CGFloat] = [0.32, 0.55, 0.80, 0.55, 0.32]
            let barW: CGFloat = 2.6
            let gap: CGFloat = 1.7
            let totalW = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
            var x = (rect.width - totalW) / 2
            (color ?? .black).setFill()
            for h in heights {
                let bh = rect.height * h
                let bar = NSRect(x: x, y: (rect.height - bh) / 2, width: barW, height: bh)
                NSBezierPath(roundedRect: bar, xRadius: barW / 2, yRadius: barW / 2).fill()
                x += barW + gap
            }
            return true
        }
        img.isTemplate = (color == nil)
        return img
    }

    lazy var iconIdle = makeStatusImage(color: nil)
    lazy var iconRecording = makeStatusImage(color: .systemRed)
    lazy var iconTranscribing = makeStatusImage(color: .systemPurple)

    func setStatusIcon(_ s: String) {
        DispatchQueue.main.async {
            guard let button = self.statusItem.button else { return }
            button.title = ""
            switch s {
            case "🔴": button.image = self.iconRecording
            case "✨": button.image = self.iconTranscribing
            default: button.image = self.iconIdle
            }
        }
    }

    func buildMenu() {
        let menu = NSMenu()
        let info = NSMenuItem(title: "Open-Wispr — hold fn to dictate", action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
        menu.addItem(.separator())
        let openItem = NSMenuItem(title: "Open Main Window", action: #selector(menuSettings), keyEquivalent: ",")
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(.separator())
        toggleMenuItem = NSMenuItem(title: "Start Dictation", action: #selector(menuToggle), keyEquivalent: "")
        toggleMenuItem.target = self
        menu.addItem(toggleMenuItem)
        let lastItem = NSMenuItem(title: "Show Last Transcript", action: #selector(menuLastTranscript), keyEquivalent: "")
        lastItem.target = self
        menu.addItem(lastItem)
        cleanupMenuItem = NSMenuItem(title: "Clean Up Speech (fillers, stutters)", action: #selector(menuToggleCleanup), keyEquivalent: "")
        cleanupMenuItem.target = self
        cleanupMenuItem.state = cleanupEnabled ? .on : .off
        menu.addItem(cleanupMenuItem)
        autoLearnMenuItem = NSMenuItem(title: "Learn My Corrections", action: #selector(menuToggleAutoLearn), keyEquivalent: "")
        autoLearnMenuItem.target = self
        autoLearnMenuItem.state = autoLearnEnabled ? .on : .off
        menu.addItem(autoLearnMenuItem)
        menu.addItem(.separator())
        let dictItem = NSMenuItem(title: "Word Replacements…", action: #selector(menuDictionary), keyEquivalent: "")
        dictItem.target = self
        menu.addItem(dictItem)
        let helpItem = NSMenuItem(title: "Setup Help", action: #selector(menuHelp), keyEquivalent: "")
        helpItem.target = self
        menu.addItem(helpItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Open-Wispr", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    // MARK: - Pill UI

    func repositionUI() {
        let screen = mouseScreen()
        pill.reposition(on: screen)
        if popup.isVisible { popup.repositionAbove(pillFrame: pill.frame) }
    }

    func pillClicked() {
        switch state {
        case .recording:
            stopAndTranscribe()
        case .transcribing:
            break
        case .idle:
            if popup.isVisible {
                popup.hide()
            } else if !lastTranscript.isEmpty {
                if pill.state == .attention { pill.state = .idle }
                popup.onCopy = { [weak self] in self?.copyLastTranscript() }
                popup.show(text: lastTranscript, abovePillFrame: pill.frame)
            } else {
                hud.show("Nothing dictated yet", autohide: 1.2)
            }
        }
    }

    func copyLastTranscript() {
        clipboardRestoreWork?.cancel()
        clipboardRestoreWork = nil
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(lastTranscript, forType: .string)
        popup.hide()
        if pill.state == .attention { pill.state = .idle }
        hud.show("✓ Copied", autohide: 1)
        log("Last transcript copied via pill popup")
    }

    func startAnim() {
        animTimer?.invalidate()
        animTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 24.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.state == .recording, let rec = self.recorder {
                rec.updateMeters()
                let db = CGFloat(rec.averagePower(forChannel: 0))
                self.pill.view.level = max(0, min(1, (db + 50) / 45))
            }
            self.pill.view.phase += 0.30
            self.pill.view.needsDisplay = true
        }
    }

    func stopAnim() {
        animTimer?.invalidate()
        animTimer = nil
    }

    func flashSuccess() {
        pill.state = .success
        successTimer?.invalidate()
        successTimer = Timer.scheduledTimer(withTimeInterval: 0.9, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            if self.pill.state == .success { self.pill.state = .idle }
        }
    }

    // MARK: - fn key handling

    func handleFlagsChanged(_ event: NSEvent) {
        guard event.keyCode == FN_KEYCODE else { return }
        let down = event.modifierFlags.contains(.function)
        guard down != fnIsDown else { return }
        fnIsDown = down
        DispatchQueue.main.async { down ? self.fnDown() : self.fnUp() }
    }

    func fnDown() {
        fnPressedAt = Date()
        switch state {
        case .idle:
            startedByThisPress = true
            startRecording()
        case .recording:
            startedByThisPress = false
            stopAndTranscribe()
        case .transcribing:
            break
        }
    }

    func fnUp() {
        let heldFor = Date().timeIntervalSince(fnPressedAt)
        if state == .recording && startedByThisPress && heldFor > HOLD_THRESHOLD {
            stopAndTranscribe()
        }
        startedByThisPress = false
    }

    @objc func menuToggle() {
        switch state {
        case .idle: startRecording()
        case .recording: stopAndTranscribe()
        case .transcribing: break
        }
    }

    @objc func menuLastTranscript() {
        if lastTranscript.isEmpty {
            hud.show("Nothing dictated yet", autohide: 1.2)
        } else {
            popup.onCopy = { [weak self] in self?.copyLastTranscript() }
            popup.show(text: lastTranscript, abovePillFrame: pill.frame)
        }
    }

    @objc func menuToggleCleanup() {
        let on = !cleanupEnabled
        Config.shared.setFlag("CLEANUP", on)
        cleanupMenuItem.state = on ? .on : .off
        hud.show(on ? "✓ Cleanup on" : "Cleanup off", autohide: 1.2)
        log("Cleanup toggled: \(on)")
    }

    @objc func menuToggleAutoLearn() {
        let on = !autoLearnEnabled
        Config.shared.setFlag("AUTOLEARN", on)
        autoLearnMenuItem.state = on ? .on : .off
        if !on { watcher.stop() }
        hud.show(on ? "✓ Learning corrections" : "Not learning corrections", autohide: 1.4)
        log("Auto-learn toggled: \(on)")
    }

    @objc func menuSettings() { SettingsUI.shared.present() }

    @objc func menuDictionary() { SettingsUI.shared.present(selecting: "dictionary") }

    // MARK: - Learned corrections

    /// Called by CorrectionWatcher when you hand-fix a word right after a paste.
    func learned(from: String, to: String) {
        guard ReplacementStore.shared.upsert(from: from, to: to, learned: true,
                                             caseSensitive: from.lowercased() == to.lowercased()) else { return }
        log("Learned correction: \(from) -> \(to)")
        hud.show("✓ Learned “\(from)” → “\(to)”", autohide: 2.6)
        flashLearned()
    }

    func flashLearned() {
        pill.state = .learned
        startAnim()
        learnedTimer?.invalidate()
        learnedTimer = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            if self.pill.state == .learned {
                self.pill.state = .idle
                if self.state == .idle { self.stopAnim() }
            }
        }
    }

    // MARK: - Disfluency cleanup

    /// Remove filler words ("um"/"uh"), cut-off word fragments ("al- already"),
    /// and comma-separated repeats ("I, I" -> "I") before pasting. Pure text, no
    /// network — it never changes which real words you said, only trims noise.
    func cleanTranscript(_ raw: String) -> String {
        if !cleanupEnabled { return raw }
        var s = raw

        func sub(_ pattern: String, _ template: String, caseInsensitive: Bool = true) {
            var opts: NSRegularExpression.Options = []
            if caseInsensitive { opts.insert(.caseInsensitive) }
            guard let re = try? NSRegularExpression(pattern: pattern, options: opts) else { return }
            let range = NSRange(s.startIndex..<s.endIndex, in: s)
            s = re.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: template)
        }

        // Cut-off fragments: a word ending in a hyphen then a space ("al- already", "No- Node").
        sub("\\b\\p{L}+-\\s+", " ")
        // Filler words, optionally eating one trailing comma. \b guards real words/names.
        sub("\\b(?:u+h+|u+m+|e+r+|a+h+|h+m+|m+h+m+|erm|mm+)\\b,?", "")
        // Immediate comma-separated repeats ("how, how, how" -> "how"); apostrophes kept
        // so contractions survive.
        sub("\\b([\\p{L}']+)(?:\\s*,\\s*\\1\\b)+", "$1")
        // Space-separated repeats ("we we" -> "we"), but never "that that" / "had had",
        // which are valid English doubles.
        sub("\\b(?!(?:that|had)\\b)([\\p{L}']+)(?:\\s+\\1\\b)+", "$1")
        // Tidy leftover whitespace and punctuation.
        sub("\\s+", " ")
        sub("\\s+([,.;:!?])", "$1")
        sub("(?:,\\s*){2,}", ", ")
        sub("^[\\s,]+", "")
        // Lone lowercase "i" -> "I".
        sub("\\bi\\b", "I", caseInsensitive: false)

        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return capitalizeSentences(s)
    }

    /// Re-capitalize the first letter and any letter after . ! ? — our edits above
    /// can lowercase a new leading word once a filler is stripped.
    func capitalizeSentences(_ text: String) -> String {
        var chars = Array(text)
        var capNext = true
        for i in chars.indices {
            let c = chars[i]
            if c.isLetter {
                if capNext { chars[i] = Character(c.uppercased()) }
                capNext = false
            } else if ".!?".contains(c) {
                // Sentence end only when followed by whitespace/end — so "Node.js",
                // "e.g." and decimals don't trigger a mid-word capital.
                let next = i + 1 < chars.count ? chars[i + 1] : " "
                capNext = next.isWhitespace
            } else if !c.isWhitespace {
                capNext = false
            }
        }
        return String(chars)
    }

    // MARK: - Recording

    func startRecording() {
        guard state == .idle else { return }
        guard apiKey() != nil else {
            hud.show("⚠️ No API key — add one in Settings", autohide: 2.5)
            playSound("Basso")
            SettingsUI.shared.present(selecting: "general")
            return
        }
        popup.hide()
        watcher.stop()   // whatever you were editing, you've moved on
        // Give a Chromium/Electron target the record+transcribe window to build its
        // accessibility tree, so we can see your edit once the text lands.
        if autoLearnEnabled { CorrectionWatcher.prepareFrontmostApp() }
        // Live mode never touches the disk — it streams straight to the socket.
        if Config.shared.liveEnabled {
            startLiveRecording()
            return
        }
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            try? FileManager.default.removeItem(at: audioURL)
            let rec = try AVAudioRecorder(url: audioURL, settings: settings)
            rec.isMeteringEnabled = true
            rec.prepareToRecord()
            guard rec.record() else { throw NSError(domain: "Open-Wispr", code: 1, userInfo: [NSLocalizedDescriptionKey: "recorder.record() returned false"]) }
            recorder = rec
            state = .recording
            pill.state = .recording
            startAnim()
            setStatusIcon("🔴")
            toggleMenuItem.title = "Stop & Transcribe"
            playSound("Pop")
            maxLenTimer = Timer.scheduledTimer(withTimeInterval: MAX_CLIP_SECONDS, repeats: false) { [weak self] _ in
                self?.stopAndTranscribe()
            }
            log("Recording started")
        } catch {
            log("Recording failed to start: \(error.localizedDescription)")
            hud.show("⚠️ Mic error — check permissions", autohide: 2.5)
            playSound("Basso")
        }
    }

    func stopAndTranscribe() {
        if live != nil { stopLive(); return }
        guard state == .recording, let rec = recorder else { return }
        maxLenTimer?.invalidate()
        let duration = rec.currentTime
        rec.stop()
        recorder = nil

        if duration < MIN_CLIP_SECONDS {
            state = .idle
            stopAnim()
            pill.state = .idle
            setStatusIcon("🎤")
            toggleMenuItem.title = "Start Dictation"
            log("Clip too short (\(String(format: "%.2f", duration))s), discarded")
            return
        }

        state = .transcribing
        pill.state = .transcribing
        setStatusIcon("✨")
        toggleMenuItem.title = "Transcribing…"
        playSound("Tink")
        log("Recording stopped (\(String(format: "%.1f", duration))s), transcribing")

        transcribe(fileURL: audioURL) { [weak self] result in
            self?.finishTranscription(result, duration: duration)
        }
    }

    /// The tail both paths share: clean it up, apply your dictionary, remember it,
    /// paste it. Whether the words arrived in one upload or streamed in live makes
    /// no difference from here on.
    func finishTranscription(_ result: Result<String, Error>, duration: TimeInterval) {
        state = .idle
        stopAnim()
        setStatusIcon("🎤")
        toggleMenuItem.title = "Start Dictation"
        switch result {
        case .success(let text):
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.isEmpty {
                pill.state = .idle
                hud.show("🤷 No speech detected", autohide: 1.2)
                log("Empty transcript")
            } else {
                let cleaned = cleanTranscript(clean)
                // Your dictionary runs last so its exact spelling ("ReqKey") survives.
                let final = ReplacementStore.shared.apply(to: cleaned)
                lastTranscript = final
                if final != clean {
                    log("Transcript raw (\(clean.count)): \(clean.prefix(160))")
                    log("Transcript final (\(final.count)): \(final.prefix(160))")
                } else {
                    log("Transcript (\(final.count) chars): \(final.prefix(160))")
                }
                HistoryStore.shared.add(text: final, seconds: duration, model: modelName())
                pasteText(final)
            }
        case .failure(let err):
            pill.state = .idle
            log("Transcription error: \(err.localizedDescription)")
            hud.show("⚠️ \(err.localizedDescription)", autohide: 2.5)
            playSound("Basso")
        }
    }

    // MARK: - Live transcription

    /// Same lifecycle as the file path — start, stop, hand the text to
    /// finishTranscription — except the words arrive while you are still talking.
    func startLiveRecording() {
        guard let key = apiKey() else { return }
        let model = Config.shared.model
        let session = LiveTranscriber(model: model, key: key)
        session.onLevel = { [weak self] level in self?.pill.view.level = level }
        session.onText = { [weak self] text in self?.showLivePreview(text) }
        session.onFinish = { [weak self] result in
            guard let self = self, self.live != nil else { return }
            self.live = nil
            self.hud.hide()
            self.finishTranscription(result, duration: Date().timeIntervalSince(self.liveStartedAt))
        }
        do {
            try session.start()
        } catch {
            log("Live session failed to start: \(error.localizedDescription)")
            hud.show("⚠️ \(error.localizedDescription)", autohide: 2.5)
            playSound("Basso")
            return
        }
        live = session
        liveStartedAt = Date()
        state = .recording
        pill.state = .recording
        startAnim()
        setStatusIcon("🔴")
        toggleMenuItem.title = "Stop & Transcribe"
        playSound("Pop")
        maxLenTimer = Timer.scheduledTimer(withTimeInterval: MAX_CLIP_SECONDS, repeats: false) { [weak self] _ in
            self?.stopAndTranscribe()
        }
        log("Live session started (\(model))")
    }

    func stopLive() {
        guard let session = live else { return }
        maxLenTimer?.invalidate()
        let duration = Date().timeIntervalSince(liveStartedAt)

        if duration < MIN_CLIP_SECONDS {
            live = nil
            session.cancel()
            hud.hide()
            state = .idle
            stopAnim()
            pill.state = .idle
            setStatusIcon("🎤")
            toggleMenuItem.title = "Start Dictation"
            log("Clip too short (\(String(format: "%.2f", duration))s), discarded")
            return
        }

        state = .transcribing
        pill.state = .transcribing
        setStatusIcon("✨")
        toggleMenuItem.title = "Transcribing…"
        playSound("Tink")
        log("Live recording stopped (\(String(format: "%.1f", duration))s), finalising")
        // Most of the transcript is already in hand, so this usually returns in
        // well under the grace period rather than the full upload round-trip.
        session.finish()
    }

    /// The point of live mode: the words show up in the HUD as you say them.
    /// Only the tail, so a long dictation doesn't grow a banner off-screen.
    func showLivePreview(_ text: String) {
        guard live != nil, !text.isEmpty else { return }
        hud.show(text.count > 110 ? "…" + String(text.suffix(110)) : text)
    }

    // MARK: - Batch transcription (OpenRouter or OpenAI)

    func transcribe(fileURL: URL, completion: @escaping (Result<String, Error>) -> Void) {
        let provider = Config.shared.provider
        func fail(_ msg: String) {
            completion(.failure(NSError(domain: "Open-Wispr", code: 2, userInfo: [NSLocalizedDescriptionKey: msg])))
        }
        guard let key = apiKey() else {
            DispatchQueue.main.async { fail("No API key configured") }
            return
        }
        guard let audioData = try? Data(contentsOf: fileURL) else {
            DispatchQueue.main.async { fail("Could not read recording") }
            return
        }
        // OpenAI-style transcriptions endpoint: multipart form with `model` + `file`.
        let boundary = "openwispr-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n\(modelName())\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: URL(string: provider.transcriptionsURL)!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 90
        req.httpBody = body

        URLSession.shared.dataTask(with: req) { data, resp, err in
            DispatchQueue.main.async {
                if let err = err { return fail(err.localizedDescription) }
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return fail("Bad response from \(provider.title)")
                }
                if let apiErr = json["error"] as? [String: Any], let msg = apiErr["message"] as? String {
                    return fail(msg)
                }
                guard let text = json["text"] as? String else {
                    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    return fail("Unexpected response (HTTP \(status))")
                }
                completion(.success(text))
            }
        }.resume()
    }

    // MARK: - Paste

    func pasteText(_ text: String) {
        let pb = NSPasteboard.general
        let previous = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)

        // Without Accessibility, CGEvent posting is silently dropped — leave the
        // transcript on the clipboard and flag the pill instead.
        guard AXIsProcessTrusted() else {
            log("Paste skipped: Accessibility not granted. Transcript left on clipboard.")
            pill.state = .attention
            hud.show("⚠️ Copied — grant Accessibility to auto-paste (click the pill for the text)", autohide: 3)
            playSound("Basso")
            let axOpts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(axOpts)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            let src = CGEventSource(stateID: .combinedSessionState)
            let vDown = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)
            let vUp = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
            vDown?.flags = .maskCommand
            vUp?.flags = .maskCommand
            vDown?.post(tap: .cghidEventTap)
            vUp?.post(tap: .cghidEventTap)
            self.flashSuccess()
            // Once the text has landed, watch for a hand-fix so we can learn it.
            if Config.shared.autoLearn {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    self.watcher.begin(pasted: text)
                }
            }
            // Give the paste a moment to land, then restore the old clipboard.
            if let previous = previous {
                self.clipboardRestoreWork?.cancel()
                let work = DispatchWorkItem {
                    pb.clearContents()
                    pb.setString(previous, forType: .string)
                }
                self.clipboardRestoreWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
            }
        }
    }

    // MARK: - Menu actions

    @objc func menuHelp() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Open-Wispr Setup"
        alert.informativeText = """
        1. System Settings → Keyboard → set “Press 🌐 key to” to “Do Nothing” \
        (otherwise fn opens the emoji picker).

        2. Grant Accessibility AND Input Monitoring to Open-Wispr in \
        System Settings → Privacy & Security. Needed to see the fn key, to paste, \
        and to notice the words you fix.

        3. Allow Microphone access when prompted.

        Usage: HOLD fn while speaking, release to transcribe & paste. \
        Or TAP fn to start hands-free, tap again to finish. \
        Click the floating pill to see the last transcript with a Copy button. \
        Everything else lives in Settings (⌘,).
        """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Open Accessibility")
        alert.addButton(withTitle: "Close")
        let resp = alert.runModal()
        if resp == .alertFirstButtonReturn {
            SettingsUI.shared.present(selecting: "general")
        } else if resp == .alertSecondButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
