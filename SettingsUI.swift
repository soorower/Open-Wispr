// The settings window: a sidebar shell plus the General and About panes.
// (Dictionary and Activity live in SettingsPanes.swift.)
import Cocoa
import AVFoundation

// MARK: - Sidebar row

final class NavRow: NSView {
    let key: String
    private let iconView = NSImageView()
    private let titleField: NSTextField
    private var hovering = false { didSet { needsDisplay = true } }
    var selected = false { didSet { restyle(); needsDisplay = true } }
    var onClick: ((String) -> Void)?

    init(key: String, symbol: String, title: String) {
        self.key = key
        titleField = Theme.line(title, 12.5, .medium)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7

        iconView.image = Theme.symbol(symbol, 12.5, .medium)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 17).isActive = true

        let row = Theme.hstack([iconView, titleField], spacing: 9)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 30),
        ])
        restyle()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                      options: [.mouseEnteredAndExited, .activeInActiveApp],
                                      owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { onClick?(key) }

    private func restyle() {
        titleField.textColor = selected ? .labelColor : .secondaryLabelColor
        iconView.contentTintColor = selected ? Theme.violet : .secondaryLabelColor
        titleField.font = .systemFont(ofSize: 12.5, weight: selected ? .semibold : .medium)
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let bg: NSColor = selected ? Theme.navPick : (hovering ? Theme.navHover : .clear)
        layer?.backgroundColor = bg.cgColor
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

// MARK: - Window shell

final class SettingsUI: NSObject, NSWindowDelegate {
    static let shared = SettingsUI()

    private var window: NSWindow?
    private let contentHost = NSView()
    private var rows: [NavRow] = []
    private var panes: [String: PaneView] = [:]
    private var currentKey = ""
    private var statusChip: NSTextField?

    private let items: [(key: String, symbol: String, title: String)] = [
        ("general", "slider.horizontal.3", "General"),
        ("dictionary", "character.book.closed", "Dictionary"),
        ("activity", "waveform.and.magnifyingglass", "Activity"),
        ("about", "sparkles", "About"),
    ]

    // MARK: Presenting

    func present(selecting key: String? = nil) {
        if window == nil { build() }
        installMainMenuIfNeeded()
        // Become a regular app while the window is up, so it gets a proper window
        // experience and Cmd+C/V work in the text fields. Back to menu-bar-only on close.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.center()
        let wanted = key ?? (currentKey.isEmpty ? "general" : currentKey)
        if wanted == currentKey {
            panes[wanted]?.paneAppeared()   // already showing — just refresh it
        } else {
            select(wanted)
        }
    }

    func windowWillClose(_ notification: Notification) {
        panes[currentKey]?.paneDisappeared()
        NSApp.setActivationPolicy(.accessory)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        panes[currentKey]?.paneAppeared()
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Open-Wispr"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.minSize = NSSize(width: 820, height: 560)
        w.delegate = self
        w.isReleasedWhenClosed = false

        let root = NSVisualEffectView()
        root.material = .underWindowBackground
        root.blendingMode = .behindWindow
        root.state = .active
        w.contentView = root

        // Sidebar
        let side = NSVisualEffectView()
        side.material = .sidebar
        side.blendingMode = .behindWindow
        side.state = .followsWindowActiveState
        side.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(side)

        let edge = ColorView(color: Theme.hairline)
        edge.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(edge)

        contentHost.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(contentHost)

        NSLayoutConstraint.activate([
            side.topAnchor.constraint(equalTo: root.topAnchor),
            side.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            side.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            side.widthAnchor.constraint(equalToConstant: 214),

            edge.topAnchor.constraint(equalTo: root.topAnchor),
            edge.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            edge.leadingAnchor.constraint(equalTo: side.trailingAnchor),
            edge.widthAnchor.constraint(equalToConstant: 1),

            contentHost.topAnchor.constraint(equalTo: root.topAnchor),
            contentHost.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            contentHost.leadingAnchor.constraint(equalTo: edge.trailingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])

        buildSidebar(in: side)
        window = w
    }

    private func buildSidebar(in side: NSView) {
        // Wordmark
        let markView = NSImageView(image: Theme.mark(24))
        markView.translatesAutoresizingMaskIntoConstraints = false
        markView.widthAnchor.constraint(equalToConstant: 24).isActive = true
        markView.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let name = Theme.line("Open-Wispr", 13.5, .semibold)
        let version = Theme.dimLine("v\(APP_VERSION)", 10.5)
        let brand = Theme.hstack([markView, Theme.vstack([name, version], spacing: 0)], spacing: 9)

        rows = items.map { item in
            let r = NavRow(key: item.key, symbol: item.symbol, title: item.title)
            r.onClick = { [weak self] k in self?.select(k) }
            return r
        }

        let chip = Theme.dimLine("", 11)
        statusChip = chip

        let quit = NSButton(title: "Quit Open-Wispr", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quit.bezelStyle = .inline
        quit.isBordered = false
        quit.font = .systemFont(ofSize: 11.5)
        quit.contentTintColor = .secondaryLabelColor

        let nav = NSStackView(views: rows)
        nav.orientation = .vertical
        nav.alignment = .leading
        nav.spacing = 2
        nav.translatesAutoresizingMaskIntoConstraints = false

        let column = NSStackView(views: [brand, nav])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 18
        column.translatesAutoresizingMaskIntoConstraints = false
        side.addSubview(column)

        let footer = NSStackView(views: [chip, quit])
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = 6
        footer.translatesAutoresizingMaskIntoConstraints = false
        side.addSubview(footer)

        NSLayoutConstraint.activate([
            // clear of the traffic lights
            column.topAnchor.constraint(equalTo: side.topAnchor, constant: 44),
            column.leadingAnchor.constraint(equalTo: side.leadingAnchor, constant: 14),
            column.trailingAnchor.constraint(equalTo: side.trailingAnchor, constant: -14),
            nav.widthAnchor.constraint(equalTo: column.widthAnchor),
            footer.leadingAnchor.constraint(equalTo: side.leadingAnchor, constant: 16),
            footer.bottomAnchor.constraint(equalTo: side.bottomAnchor, constant: -16),
        ])
        for r in rows { r.widthAnchor.constraint(equalTo: nav.widthAnchor).isActive = true }
        refreshChip()
    }

    func refreshChip() {
        guard let chip = statusChip else { return }
        let learned = ReplacementStore.shared.rules.filter { $0.learned }.count
        let total = ReplacementStore.shared.rules.count
        chip.stringValue = total == 0
            ? "No replacements yet"
            : "\(total) replacement\(total == 1 ? "" : "s")\(learned > 0 ? " · \(learned) learned" : "")"
    }

    // MARK: Pane switching

    private func pane(for key: String) -> PaneView {
        if let existing = panes[key] { return existing }
        let made: PaneView
        switch key {
        case "dictionary": made = DictionaryPane()
        case "activity":   made = ActivityPane()
        case "about":      made = AboutPane()
        default:           made = GeneralPane()
        }
        panes[key] = made
        return made
    }

    func select(_ key: String) {
        guard key != currentKey else { return }
        panes[currentKey]?.paneDisappeared()
        contentHost.subviews.forEach { $0.removeFromSuperview() }
        let p = pane(for: key)
        p.fill(contentHost)
        currentKey = key
        rows.forEach { $0.selected = ($0.key == key) }
        p.paneAppeared()
        refreshChip()
    }

    // MARK: Menu (for Cmd+C/V inside the window)

    private var menuInstalled = false
    private func installMainMenuIfNeeded() {
        guard !menuInstalled else { return }
        menuInstalled = true
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Hide Open-Wispr", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Open-Wispr", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }
}

// MARK: - General pane

final class GeneralPane: PaneView, NSComboBoxDelegate {
    private let keyField = NSSecureTextField()
    private let keyPlain = WrapLabel()
    private let revealButton = NSButton()
    private let keyStatus = Theme.dimLine("", 11)
    private let modelBox = NSComboBox()
    private let keySlot = NSView()
    private let modelStatus = Theme.dim("", 11)
    private var keySlotHeight: NSLayoutConstraint!
    private var permissionRows: [String: StatusRow] = [:]
    private var permTimer: Timer?

    private let providerPicker = NSSegmentedControl(
        labels: Provider.allCases.map { $0.title },
        trackingMode: .selectOne, target: nil, action: nil)
    private let providerNote = Theme.dim("", 11)
    private let keyLabel = Theme.line("", 11.5, .medium, .secondaryLabelColor)
    private let modelHint = Theme.dim("", 11)
    private let liveNote = Theme.dim("", 11)
    private var liveRow: ToggleRow!
    private var liveDivider: NSView!
    /// Which provider's key is currently shown in the box — the save target,
    /// pinned so a provider switch mid-edit can't write it to the wrong one.
    private var keyFieldProvider: Provider = .openrouter

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let header = makePaneHeader("General", "Your transcription key, the model, and how dictation behaves.")

        // --- Transcription
        let transcription = Card("Transcription", "Where your audio goes. The key is stored in ~/.config/openwispr/.env (chmod 600).")

        providerPicker.selectedSegment = Provider.allCases.firstIndex(of: Config.shared.provider) ?? 0
        providerPicker.segmentDistribution = .fillEqually
        providerPicker.target = self
        providerPicker.action = #selector(providerChanged)
        providerPicker.translatesAutoresizingMaskIntoConstraints = false
        providerPicker.widthAnchor.constraint(equalToConstant: 240).isActive = true
        transcription.add(Theme.line("Provider", 11.5, .medium, .secondaryLabelColor))
        transcription.add(Theme.hstack([providerPicker, Theme.spacer()], spacing: 8))
        transcription.add(providerNote)
        transcription.addDivider()

        keyField.font = .systemFont(ofSize: 12.5)
        keyField.bezelStyle = .roundedBezel
        keyField.target = self
        keyField.action = #selector(saveKey)
        keyField.cell?.sendsActionOnEndEditing = true

        // An OpenRouter key is ~73 characters with no spaces, so revealing it in a
        // single-line field only ever shows "sk-or-v1-…". Wrap it by character
        // across as many lines as it needs.
        keyPlain.isHidden = true
        keyPlain.isEditable = true
        keyPlain.isSelectable = true
        keyPlain.isBezeled = true
        keyPlain.bezelStyle = .roundedBezel
        keyPlain.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        keyPlain.usesSingleLineMode = false
        keyPlain.cell?.wraps = true
        keyPlain.cell?.isScrollable = false
        keyPlain.maximumNumberOfLines = 4
        keyPlain.lineBreakMode = .byCharWrapping
        keyPlain.setContentCompressionResistancePriority(.init(rawValue: 200), for: .horizontal)
        keyPlain.target = self
        keyPlain.action = #selector(saveKeyPlain)
        keyPlain.cell?.sendsActionOnEndEditing = true

        revealButton.image = Theme.symbol("eye", 12, .regular)
        revealButton.bezelStyle = .rounded
        revealButton.setButtonType(.momentaryPushIn)
        revealButton.target = self
        revealButton.action = #selector(toggleReveal)
        revealButton.translatesAutoresizingMaskIntoConstraints = false
        revealButton.widthAnchor.constraint(equalToConstant: 30).isActive = true

        // The two fields share one slot; the revealed one may be several lines tall,
        // so the slot grows with it while the masked field stays a single line.
        keySlot.translatesAutoresizingMaskIntoConstraints = false
        keyField.translatesAutoresizingMaskIntoConstraints = false
        keyPlain.translatesAutoresizingMaskIntoConstraints = false
        keySlot.addSubview(keyField)
        keySlot.addSubview(keyPlain)
        keySlotHeight = keySlot.heightAnchor.constraint(equalToConstant: 22)
        NSLayoutConstraint.activate([
            keyPlain.topAnchor.constraint(equalTo: keySlot.topAnchor),
            keyPlain.bottomAnchor.constraint(equalTo: keySlot.bottomAnchor),
            keyPlain.leadingAnchor.constraint(equalTo: keySlot.leadingAnchor),
            keyPlain.trailingAnchor.constraint(equalTo: keySlot.trailingAnchor),

            keyField.leadingAnchor.constraint(equalTo: keySlot.leadingAnchor),
            keyField.trailingAnchor.constraint(equalTo: keySlot.trailingAnchor),
            keyField.topAnchor.constraint(equalTo: keySlot.topAnchor),
            keyField.heightAnchor.constraint(equalToConstant: 22),
            keySlotHeight,
        ])

        let save = Theme.accentButton("Save", target: self, action: #selector(saveKey))
        let verify = Theme.plainButton("Verify", target: self, action: #selector(verifyKey))
        let keyRow = Theme.hstack([keySlot, revealButton, save, verify], spacing: 6)
        keySlot.setContentHuggingPriority(.init(1), for: .horizontal)

        transcription.add(keyLabel)
        transcription.add(keyRow)
        transcription.add(keyStatus)
        transcription.addDivider()

        modelBox.font = .systemFont(ofSize: 12.5)
        modelBox.completes = true
        modelBox.target = self
        modelBox.action = #selector(saveModel)
        // Without this the action only fires on Return — typing a model name and
        // clicking away would look saved but silently wasn't.
        modelBox.cell?.sendsActionOnEndEditing = true
        modelBox.delegate = self
        modelBox.translatesAutoresizingMaskIntoConstraints = false
        modelBox.widthAnchor.constraint(equalToConstant: 300).isActive = true

        transcription.add(Theme.line("Model", 11.5, .medium, .secondaryLabelColor))
        transcription.add(Theme.hstack([modelBox, Theme.spacer()], spacing: 8))
        transcription.add(modelStatus)
        transcription.add(modelHint)

        // Live streaming is OpenAI-only, so this whole block collapses out of the
        // card on OpenRouter rather than sitting there as a dead switch.
        liveDivider = Theme.divider()
        transcription.add(liveDivider)
        liveRow = ToggleRow("Live streaming",
                            "Stream the audio as you talk and watch the words land, instead of uploading the clip at the end.",
                            isOn: Config.shared.live) { [weak self] on in
            Config.shared.setFlag("LIVE", on)
            Config.shared.log("Live streaming toggled: \(on)")
            self?.refreshProviderUI()
        }
        transcription.add(liveRow)
        transcription.add(liveNote)

        // --- Behaviour
        let behaviour = Card("Dictation")
        behaviour.add(ToggleRow("Clean up speech",
                                "Strips “um”, “uh”, stutters and cut-off fragments before pasting.",
                                isOn: Config.shared.cleanup) { on in
            Config.shared.setFlag("CLEANUP", on)
        })
        behaviour.addDivider()
        behaviour.add(ToggleRow("Learn my corrections",
                                "If you fix a word right after a paste, that fix becomes a replacement. "
                                + "Asks Chrome/Electron apps to expose their text so it can see the edit.",
                                isOn: Config.shared.autoLearn) { on in
            Config.shared.setFlag("AUTOLEARN", on)
        })
        behaviour.addDivider()
        behaviour.add(ToggleRow("Sound cues",
                                "Little clicks when recording starts, stops, or something goes wrong.",
                                isOn: Config.shared.sounds) { on in
            Config.shared.setFlag("SOUNDS", on)
        })
        behaviour.addDivider()
        behaviour.add(ToggleRow("Launch at login",
                                "Starts Open-Wispr automatically — takes effect at your next login.",
                                isOn: Config.shared.launchAtLogin) { on in
            Config.shared.launchAtLogin = on
        })

        // --- Permissions
        let permissions = Card("Permissions", "macOS asks for these once. Without them the fn key or the paste goes dead.")
        let ax = StatusRow("Accessibility", "checking…", buttonTitle: "Open") {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
        let input = StatusRow("Input Monitoring", "Needed to see the fn key.", buttonTitle: "Open") {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
        }
        let mic = StatusRow("Microphone", "checking…", buttonTitle: "Open") {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        }
        let fnHint = StatusRow("fn key", "System Settings → Keyboard → “Press 🌐 key to” → Do Nothing.", buttonTitle: "Open") {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.keyboard")!)
        }
        fnHint.set(ok: nil, detail: "System Settings → Keyboard → “Press 🌐 key to” → Do Nothing.")
        permissionRows = ["ax": ax, "input": input, "mic": mic]
        permissions.add(ax); permissions.addDivider()
        permissions.add(input); permissions.addDivider()
        permissions.add(mic); permissions.addDivider()
        permissions.add(fnHint)

        let scroll = makeCardScroll([header, transcription, behaviour, permissions], topInset: 46)
        scroll.fill(self, inset: 0)
        refreshProviderUI()
    }

    @objc private func providerChanged() {
        let picked = Provider.allCases[max(0, providerPicker.selectedSegment)]
        guard picked != Config.shared.provider else { return }
        // Commit anything typed but not yet saved — against the OLD provider,
        // which is still what keyFieldProvider points at.
        saveKey()
        Config.shared.provider = picked
        Config.shared.log("Provider set to \(picked.rawValue)")
        refreshProviderUI()
    }

    /// Every provider-dependent label, field and list in one place — called on
    /// launch, on a provider switch, and when live mode is toggled.
    private func refreshProviderUI() {
        let provider = Config.shared.provider
        let live = Config.shared.liveEnabled

        providerPicker.selectedSegment = Provider.allCases.firstIndex(of: provider) ?? 0
        providerNote.stringValue = provider == .openai
            ? "Straight to OpenAI. Needed for models OpenRouter hasn't picked up yet, and the only way to stream live."
            : "One key, many vendors' models. No live streaming — OpenRouter has no realtime endpoint."

        // Each provider's key is kept in its own line in .env, so switching back
        // and forth never makes you paste a key twice.
        keyLabel.stringValue = "\(provider.title) API key"
        keyField.placeholderString = provider.keyPlaceholder
        keyPlain.placeholderString = provider.keyPlaceholder
        let saved = Config.shared.env()[provider.keyVar] ?? ""
        keyFieldProvider = provider
        keyField.stringValue = saved
        keyPlain.stringValue = saved

        modelBox.removeAllItems()
        modelBox.addItems(withObjectValues: live ? LIVE_MODELS : provider.suggestedModels)
        modelBox.stringValue = Config.shared.model
        // The live models are missing from this list until streaming is on, which
        // looks like they're unavailable — say so rather than let it read as a bug.
        if live {
            modelHint.stringValue = "Realtime models only — these run on the streaming socket, not the upload endpoint."
        } else if provider == .openai {
            modelHint.stringValue = "Upload models only. Turn on Live streaming below to use \(LIVE_MODEL) — "
                + "it's streaming-only, so it can't transcribe an uploaded clip."
        } else {
            modelHint.stringValue = "Must be a model that accepts audio on \(provider.title)'s transcriptions endpoint — an image or chat-only model will fail."
        }

        let showLive = provider == .openai
        liveRow.isHidden = !showLive
        liveDivider.isHidden = !showLive
        liveNote.isHidden = !showLive || !Config.shared.live
        liveNote.stringValue = "Deltas arrive over a WebSocket while you speak, so releasing fn pastes almost instantly. "
            + "\(LIVE_MODEL) bills $0.017 per minute of audio."

        refreshKeyStatus()
        refreshModelStatus()
        updateKeySlotHeight()
    }

    override func paneAppeared() {
        refreshPermissions()
        refreshProviderUI()
        permTimer?.invalidate()
        permTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshPermissions()
        }
    }

    override func paneDisappeared() {
        permTimer?.invalidate()
        permTimer = nil
    }

    private func refreshPermissions() {
        let trusted = AXIsProcessTrusted()
        permissionRows["ax"]?.set(ok: trusted,
                                  detail: trusted ? "Granted — pasting works."
                                                  : "Missing — transcripts land on the clipboard instead of pasting.")
        // There is no public API to query Input Monitoring, and fn detection keeps
        // working without it on most Macs, so this row stays informational.
        permissionRows["input"]?.set(ok: nil, detail: "Needed to see the fn key. Re-grant it if fn stops working.")

        let micState = AVCaptureDevice.authorizationStatus(for: .audio)
        let micOK = micState == .authorized
        permissionRows["mic"]?.set(ok: micOK ? true : (micState == .notDetermined ? nil : false),
                                   detail: micOK ? "Granted." : (micState == .notDetermined ? "Not asked yet — start a dictation." : "Denied — dictation can't record."))
    }

    private func refreshKeyStatus() {
        if let k = Config.shared.apiKey {
            let tail = String(k.suffix(4))
            keyStatus.stringValue = "Key set (…\(tail))."
            keyStatus.textColor = .secondaryLabelColor
        } else {
            keyStatus.stringValue = "No \(Config.shared.provider.title) key yet — dictation is disabled until you add one."
            keyStatus.textColor = .systemOrange
        }
    }

    // MARK: Actions

    @objc private func toggleReveal() {
        let showing = keyPlain.isHidden   // hidden now => we are about to reveal
        if showing {
            keyPlain.stringValue = keyField.stringValue
        } else {
            keyField.stringValue = keyPlain.stringValue
        }
        keyPlain.isHidden = !showing
        keyField.isHidden = showing
        revealButton.image = Theme.symbol(showing ? "eye.slash" : "eye", 12, .regular)
        revealButton.toolTip = showing ? "Hide the key" : "Show the key"
        updateKeySlotHeight()
        if showing { window?.makeFirstResponder(keyPlain) }
    }

    override func layout() {
        super.layout()
        updateKeySlotHeight()
    }

    /// A revealed key needs however many lines the wrap takes. Intrinsic sizing on a
    /// wrapping NSTextField doesn't settle reliably here, so measure it directly.
    private func updateKeySlotHeight() {
        let wanted: CGFloat
        if keyPlain.isHidden || keyPlain.stringValue.isEmpty {
            wanted = 22
        } else {
            let width = max(140, keySlot.bounds.width) - 10
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byCharWrapping
            let attrs: [NSAttributedString.Key: Any] = [
                .font: keyPlain.font ?? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .paragraphStyle: para,
            ]
            let measured = (keyPlain.stringValue as NSString).boundingRect(
                with: NSSize(width: width, height: 4000),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attrs).height
            wanted = min(max(ceil(measured) + 9, 22), 120)
        }
        if abs(keySlotHeight.constant - wanted) > 0.5 {
            keySlotHeight.constant = wanted
        }
    }

    @objc private func saveKeyPlain() {
        keyField.stringValue = keyPlain.stringValue
        saveKey()
    }

    /// Two rules here, both learned the hard way:
    ///
    /// 1. Save against the provider the field was POPULATED for, never whatever
    ///    is selected right now. Clicking the provider picker ends editing, which
    ///    fires this, and AppKit does not guarantee that happens before the
    ///    picker's own action — so `Config.shared.provider` may already be the
    ///    new one while the box still holds the old provider's text.
    /// 2. An empty box NEVER deletes a key. Switching providers repopulates the
    ///    field, so blank overwhelmingly means "nothing typed here", not "throw
    ///    away my credential". Losing a key you can't get back is far worse than
    ///    making deletion a manual edit.
    @objc private func saveKey() {
        let target = keyFieldProvider
        let value = (keyPlain.isHidden ? keyField.stringValue : keyPlain.stringValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !value.isEmpty else {
            if Config.shared.apiKey(for: target) != nil {
                keyStatus.stringValue = "Box is empty — your saved \(target.title) key is untouched."
                keyStatus.textColor = .secondaryLabelColor
            } else {
                refreshKeyStatus()
            }
            return
        }
        guard value != Config.shared.apiKey(for: target) else { refreshKeyStatus(); return }

        Config.shared.set(target.keyVar, value)
        Config.shared.log("\(target.title) API key updated from settings")
        refreshKeyStatus()
    }

    /// Picking from the dropdown doesn't go through the action, and stringValue
    /// isn't updated yet at this point — read the selected item directly.
    func comboBoxSelectionDidChange(_ notification: Notification) {
        DispatchQueue.main.async {
            if let picked = self.modelBox.objectValueOfSelectedItem as? String {
                self.modelBox.stringValue = picked
            }
            self.saveModel()
        }
    }

    @objc private func saveModel() {
        let m = modelBox.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !m.isEmpty else { refreshModelStatus(); return }
        guard m != Config.shared.model else { refreshModelStatus(); return }
        // Live mode keeps its own model slot — a realtime-only name must not leak
        // into the batch setting and break uploads when streaming goes back off.
        Config.shared.set(Config.shared.liveEnabled ? "LIVE_MODEL" : Config.shared.provider.modelVar, m)
        Config.shared.log("Model set to \(m)")
        refreshModelStatus()
    }

    /// Reads the model back out of the config, so the label is proof it stuck
    /// rather than an echo of what's in the box.
    private func refreshModelStatus() {
        let effective = Config.shared.model
        if let override = ProcessInfo.processInfo.environment["OPENWISPR_MODEL"], !override.isEmpty {
            modelStatus.stringValue = "⚠️ OPENWISPR_MODEL in the environment is overriding this — using “\(override)”."
            modelStatus.textColor = .systemOrange
        } else if effective == modelBox.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) {
            modelStatus.stringValue = "In use for every dictation: \(effective)"
            modelStatus.textColor = .secondaryLabelColor
        } else {
            modelStatus.stringValue = "Unsaved — press Return to use “"
                + modelBox.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) + "”."
            modelStatus.textColor = .systemOrange
        }
    }

    /// Cheap key check. OpenRouter's /key endpoint reports the label and usage;
    /// OpenAI has no equivalent, so we list the models — which doubles as the
    /// answer to "does my account actually have the live model yet?".
    @objc private func verifyKey() {
        saveKey()
        let provider = Config.shared.provider
        guard let key = Config.shared.apiKey else {
            keyStatus.stringValue = "Add a key first."
            keyStatus.textColor = .systemOrange
            return
        }
        keyStatus.stringValue = "Checking…"
        keyStatus.textColor = .secondaryLabelColor
        var req = URLRequest(url: URL(string: provider == .openai ? OPENAI_KEY_URL : OPENROUTER_KEY_URL)!)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 20
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let err = err {
                    self.keyStatus.stringValue = "Couldn't reach \(provider.title) — \(err.localizedDescription)"
                    self.keyStatus.textColor = .systemOrange
                    return
                }
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    self.keyStatus.stringValue = "Unexpected reply (HTTP \(code))."
                    self.keyStatus.textColor = .systemOrange
                    return
                }
                if provider == .openai {
                    if let models = json["data"] as? [[String: Any]] {
                        let ids = Set(models.compactMap { $0["id"] as? String })
                        let wanted = Config.shared.model
                        if ids.contains(wanted) {
                            self.keyStatus.stringValue = "✓ Valid — \(ids.count) models, including \(wanted)."
                            self.keyStatus.textColor = Theme.teal
                        } else {
                            // Not fatal: /v1/models has been known to omit newly
                            // launched names that still work when you call them.
                            self.keyStatus.stringValue = "✓ Key works (\(ids.count) models), but “\(wanted)” isn't listed — try a dictation to be sure."
                            self.keyStatus.textColor = .systemOrange
                        }
                    } else {
                        let msg = (json["error"] as? [String: Any])?["message"] as? String ?? "rejected (HTTP \(code))"
                        self.keyStatus.stringValue = "✕ \(msg)"
                        self.keyStatus.textColor = .systemOrange
                    }
                    return
                }
                if let d = json["data"] as? [String: Any] {
                    let label = d["label"] as? String ?? "key"
                    let usage = d["usage"] as? Double ?? 0
                    let limit = d["limit"] as? Double
                    let limitText = limit.map { String(format: " of $%.2f", $0) } ?? ""
                    self.keyStatus.stringValue = String(format: "✓ Valid — “%@”, $%.4f used%@", label, usage, limitText)
                    self.keyStatus.textColor = Theme.teal
                } else {
                    let msg = (json["error"] as? [String: Any])?["message"] as? String ?? "rejected (HTTP \(code))"
                    self.keyStatus.stringValue = "✕ \(msg)"
                    self.keyStatus.textColor = .systemOrange
                }
            }
        }.resume()
    }
}

// MARK: - About pane

final class AboutPane: PaneView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let markView = NSImageView(image: Theme.mark(44))
        markView.translatesAutoresizingMaskIntoConstraints = false
        markView.widthAnchor.constraint(equalToConstant: 44).isActive = true
        markView.heightAnchor.constraint(equalToConstant: 44).isActive = true

        let title = Theme.line("Open-Wispr", 22, .semibold)
        let sub = Theme.dimLine("Version \(APP_VERSION) · dictation that stays on your Mac", 12)
        let brand = Theme.hstack([markView, Theme.vstack([title, sub], spacing: 2)], spacing: 14)

        let how = Card("How it works")
        for line in [
            ("mic.fill", "Hold fn and speak — release to transcribe and paste. Or tap fn to go hands-free, tap again to finish."),
            ("wand.and.stars", "Filler words, stutters and cut-off fragments are trimmed locally before the text is pasted."),
            ("character.book.closed", "Your replacement dictionary is applied last, so names and product names come out spelled your way."),
            ("brain.head.profile", "Fix a word straight after a paste and Open-Wispr learns it, so the next dictation is already right."),
        ] {
            let icon = NSImageView(image: Theme.symbol(line.0, 12.5, .medium) ?? NSImage())
            icon.contentTintColor = Theme.violet
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
            let row = Theme.hstack([icon, Theme.label(line.1, 12)], spacing: 9)
            row.alignment = .firstBaseline
            how.add(row)
        }

        let privacy = Card("Privacy")
        privacy.add(Theme.label("Recordings go straight to whichever provider you picked — OpenRouter or OpenAI — for transcription, and are not kept on disk beyond the current clip. In live streaming mode nothing is written to disk at all: the audio goes over the socket as you speak. Transcripts, replacements and logs stay in ~/.config/openwispr.\n\nWhen “Learn my corrections” is on, the app reads the text of the field you just dictated into — via the same Accessibility permission it needs to paste — purely to spot the word you changed. Only the word pair is saved.\n\nChrome and Electron apps hide their text from Accessibility until an assistive client asks, so for those Open-Wispr sets “AXEnhancedUserInterface” on the app you're dictating into — the same switch VoiceOver uses — once per app, per session. Switching “Learn my corrections” off stops that entirely.", 12))

        let links = Card("Links")
        let keysButton = Theme.plainButton("API keys", target: self, action: #selector(openKeys))
        let creditsButton = Theme.plainButton("Usage & credits", target: self, action: #selector(openCredits))
        let configButton = Theme.plainButton("Open config folder", target: self, action: #selector(openConfig))
        links.add(Theme.hstack([keysButton, creditsButton, configButton, Theme.spacer()], spacing: 8))

        let scroll = makeCardScroll([brand, how, privacy, links], topInset: 46)
        scroll.fill(self, inset: 0)
    }

    /// Follows the provider you're actually using, so these never send you to the
    /// wrong dashboard.
    @objc private func openKeys() {
        NSWorkspace.shared.open(URL(string: Config.shared.provider.keysPage)!)
    }

    @objc private func openCredits() {
        let url = Config.shared.provider == .openai
            ? "https://platform.openai.com/usage" : "https://openrouter.ai/credits"
        NSWorkspace.shared.open(URL(string: url)!)
    }
    @objc private func openConfig() { NSWorkspace.shared.open(Config.shared.dir) }
}
