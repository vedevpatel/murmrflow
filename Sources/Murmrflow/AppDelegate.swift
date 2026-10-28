import AppKit
import AVFoundation
import SwiftUI
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let port = 8010
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let stateItem = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    private let lastItem = NSMenuItem(title: "No dictation yet", action: #selector(copyLast), keyEquivalent: "")
    private let basicItem = NSMenuItem(title: "Basic", action: #selector(chooseBasic), keyEquivalent: "")
    private let aiItem = NSMenuItem(title: "AI cleanup", action: #selector(chooseAI), keyEquivalent: "")
    private let recorder = AudioRecorder()
    private let hotkey = HotkeyMonitor()
    private lazy var client = ASRClient(port: port)
    private lazy var server = ServerManager(root: projectRoot(), port: port)
    private let overlay = CaptionOverlay()
    private var session: StreamingSession?
    private var finalsText = ""
    private var pendingSamples: [Int16] = []
    private var streamFailed = false
    private var dictationSeconds = 0.0
    private var dictationRecorded = false
    private var targetAppName: String?
    private var targetAppBundle: String?
    private var dashboardWindow: NSWindow?
    private var state: State = .loading
    private var lastText = ""
    private var recording = false
    private var recordStart = Date()
    /// With cleanup on, phrases are held back and pasted once the whole dictation has been rewritten.
    private var buffering = false
    private var cleaning = false
    /// Command Mode: the speech is an instruction for the selected text, see CommandMode.
    private var commandMode = false
    private var selectionTask: Task<String?, Never>?
    /// Hands-free: started by double-tapping the hotkey, it records until the hotkey is tapped again
    /// or nothing has been said for `handsFreeSilence`.
    private var handsFree = false
    private var lastTapEnd = Date.distantPast
    private var lastSpeech = Date()
    private var silenceTimer: Timer?
    /// Drops other voices in the room during hands-free; nil while dictating with the key held.
    private var gate: PhraseGate?
    private static let doubleTapGap: TimeInterval = 0.4
    private static let handsFreeSilence: TimeInterval = 60

    private enum State { case loading, ready, recording, transcribing, needsPermission, needsAccessibility, error }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        setState(.loading)
        if CommandLine.arguments.contains("--dashboard") { openDashboard() }

        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary)

        hotkey.onPress = { [weak self] shift in self?.hotkeyPressed(shift: shift) }
        hotkey.onShift = { [weak self] in self?.switchToCommand() }
        // Letting go ends a held dictation; a hands-free one keeps going until the next tap.
        hotkey.onRelease = { [weak self] in if self?.handsFree == false { self?.finishRecording() } }
        hotkey.onKeyDown = { EditLearner.shared.noteKeyDown() }
        waitForHotkeyPermission()

        Task {
            await server.startIfNeeded(client: client)
            while !(await client.isReady()) { try? await Task.sleep(nanoseconds: 500_000_000) }
            await MainActor.run { if !self.recording { self.setState(.ready) } }
        }
    }

    func applicationWillTerminate(_ notification: Notification) { server.stop() }

    // MARK: - Dictation flow

    /// A press right after a quick tap is a double-tap, which starts hands-free; a press during hands-free stops it.
    private func hotkeyPressed(shift: Bool) {
        if handsFree {
            if recording { return stopHandsFree() }
            // Hands-free with nothing recording should not happen; recover rather than ignore every release.
            handsFree = false
            silenceTimer?.invalidate()
        }
        let doubleTap = Date().timeIntervalSince(lastTapEnd) < Self.doubleTapGap
        beginRecording(command: shift, handsFree: doubleTap)
        if doubleTap && recording { startHandsFree() }
    }

    private func startHandsFree() {
        handsFree = true
        lastSpeech = Date()
        gate = PhraseGate(learned: VoiceLevel.learnedPhraseLevel(mic: recorder.level.mic))
        overlay.title = commandMode ? "Command · Hands-free" : "Hands-free"
        overlay.update("")
        stateItem.title = "Hands-free — tap Right Option to stop"
        // A safety net for a session left running by mistake; pauses to think are much shorter than this.
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, Date().timeIntervalSince(self.lastSpeech) > Self.handsFreeSilence else { return }
            NSLog("hands-free stopped after \(Int(Self.handsFreeSilence))s without speech")
            self.stopHandsFree()
        }
    }

    private func stopHandsFree() {
        handsFree = false
        silenceTimer?.invalidate()
        silenceTimer = nil
        finishRecording()
    }

    private func beginRecording(command: Bool, handsFree startsHandsFree: Bool = false) {
        guard !recording, !cleaning else { return }
        // Command Mode always goes through Groq; without a key there is nothing it can do.
        if command && !CleanupSettings.shared.hasKey { NSSound.beep(); return }
        // Fixes made to the last dictation must be learned before this one is cleaned up.
        EditLearner.shared.finish()
        buffering = command || CleanupSettings.shared.isActive
        finalsText = ""
        lastText = ""
        streamFailed = false
        dictationRecorded = false
        let target = NSWorkspace.shared.frontmostApplication
        targetAppName = target?.localizedName
        targetAppBundle = target?.bundleIdentifier
        commandMode = command
        gate = nil
        overlay.title = command ? "Command" : nil
        selectionTask = command ? captureSelection() : nil
        let stream = StreamingSession(port: port)
        stream.onPartial = { [weak self] in self?.showPartial($0) }
        stream.onFinal = { [weak self] in self?.commit($0) }
        stream.onDone = { [weak self] in self?.streamDone($0) }
        stream.onError = { [weak self] in self?.streamError($0) }
        session = stream
        recorder.onChunk = { [weak stream] in stream?.send($0) }
        stream.start()
        do {
            try recorder.start(handsFree: startsHandsFree)
            recording = true
            recordStart = Date()
            overlay.update("")
            setState(.recording)
        } catch {
            NSLog("mic start failed: \(error)")
            stream.cancel()
            session = nil
            setState(.error)
        }
    }

    /// Shift pressed after the hotkey: still Command Mode, as long as nothing has been pasted yet.
    private func switchToCommand() {
        guard recording, !commandMode, lastText.isEmpty, CleanupSettings.shared.hasKey else { return }
        commandMode = true
        buffering = true
        overlay.title = "Command"
        overlay.update("")
        selectionTask = captureSelection()
    }

    /// The selected text, read through Accessibility or, where the app doesn't expose it, copied with ⌘C.
    /// Code editors are only asked through Accessibility: with nothing selected their ⌘C copies the whole line.
    private func captureSelection() -> Task<String?, Never> {
        let kind = AppKind(bundle: targetAppBundle)
        return Task { @MainActor in
            switch CursorContext.selection() {
            case .text(let text): return text
            case .none: return nil
            case .unknown: return kind == .code ? nil : await TextInserter.copySelection()
            }
        }
    }

    private func finishRecording() {
        guard recording else { return }
        recording = false
        let samples = recorder.stop()
        let seconds = Date().timeIntervalSince(recordStart)
        guard seconds > 0.3, !samples.isEmpty else {
            // Too short to be speech: a tap, and maybe the first half of a double-tap.
            lastTapEnd = Date()
            session?.cancel(); session = nil
            overlay.hide(); setState(.ready)
            return
        }
        pendingSamples = samples
        dictationSeconds = seconds
        setState(.transcribing)
        if streamFailed {
            fallbackToBatch()
        } else {
            session?.end()
            // If the server never answers, don't leave the app stuck on "Transcribing…".
            let current = session
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self, self.session === current, current != nil else { return }
                self.streamError(NSError(domain: "ASR", code: 3, userInfo: [NSLocalizedDescriptionKey: "stream timed out"]))
            }
        }
    }

    /// Live captions, except in hands-free for speech too quiet to be the speaker's (a TV, someone nearby).
    private func showPartial(_ text: String) {
        if let gate, !gate.wouldAccept(recorder.level.phraseLevelSoFar) { return }
        overlay.update(text)
    }

    /// Where a finished phrase's text came from, which decides how hands-free's gate measures it.
    private enum PhraseSource {
        /// A phrase the server finished while recording went on.
        case live
        /// What the server finished when the recording ended.
        case end
        /// The whole recording re-transcribed after the stream broke: not judged, since its phrases can't be told apart.
        case rerun
    }

    /// A finished phrase: paste it into the focused app, or hold it for cleanup. In hands-free, it must first pass
    /// the gate against other voices.
    private func commit(_ phrase: String, from source: PhraseSource = .live) {
        let text = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if source != .rerun, var gate {
            let level = source == .live ? recorder.level.takePhraseLevel() : recorder.level.takeRemainingLevel()
            let accepted = gate.accept(level)
            self.gate = gate
            guard accepted else {
                NSLog("hands-free: dropped a phrase too quiet to be the speaker (level \(level))")
                overlay.update("")
                return
            }
            // Only the speaker's own phrases keep hands-free going.
            lastSpeech = Date()
        }
        finalsText += (finalsText.isEmpty ? "" : " ") + text
        overlay.update("")
        // Basic mode: tidied by rules and pasted phrase by phrase while the speaker keeps talking.
        if !buffering {
            let tidied = PersonalDictionary.shared.apply(BasicCleanup.apply(text))
            if !tidied.isEmpty { paste(tidied) }
        }
    }

    /// The transcript is complete: rewrite and paste it if it was held back, then record the dictation.
    private func finishDictation() {
        if commandMode { return runCommand() }
        overlay.hide()
        guard buffering, !finalsText.isEmpty else {
            recordDictation()
            if state != .needsAccessibility { setState(.ready) }
            return
        }
        let raw = finalsText
        let dictionary = PersonalDictionary.shared
        let edits = StatsStore.shared.learnFromEdits ? StatsStore.shared.recentCorrections(for: AppKind(bundle: targetAppBundle)) : []
        cleaning = true
        Task {
            // Applied after cleanup as well, since the model can still re-case or re-split a term.
            let text = dictionary.apply(await Cleanup.run(dictionary.apply(raw), appName: targetAppName, appBundle: targetAppBundle,
                                                          vocabulary: dictionary.terms, edits: edits, settings: .shared))
            await MainActor.run {
                self.cleaning = false
                if !text.isEmpty { self.paste(text, whole: true) }
                self.recordDictation()
                if self.state != .needsAccessibility { self.setState(.ready) }
            }
        }
    }

    /// Command Mode: the transcript is an instruction, applied to the selection or used to write new text.
    /// History keeps the spoken instruction, not the result.
    private func runCommand() {
        let instruction = finalsText, selection = selectionTask
        let appName = targetAppName, appBundle = targetAppBundle
        selectionTask = nil
        lastText = instruction
        guard !instruction.isEmpty else {
            overlay.hide()
            recordDictation()
            if state != .needsAccessibility { setState(.ready) }
            return
        }
        overlay.update("Working on it…")
        cleaning = true
        Task {
            let selected = await selection?.value
            let result = await CommandMode.run(instruction: instruction, selection: selected, appName: appName,
                                               appBundle: appBundle, settings: .shared)
            await MainActor.run {
                self.cleaning = false
                self.overlay.hide()
                if let result, !result.isEmpty {
                    self.pasteCommandResult(result, replacing: selected != nil)
                } else {
                    NSSound.beep()
                }
                self.recordDictation()
                if self.state != .needsAccessibility { self.setState(.ready) }
            }
        }
    }

    private func streamDone(_ full: String) {
        session = nil
        // Phrases already pasted via `final` messages must not be pasted again.
        let full = full.trimmingCharacters(in: .whitespacesAndNewlines)
        if full.hasPrefix(finalsText) {
            let rest = full.dropFirst(finalsText.count).trimmingCharacters(in: .whitespacesAndNewlines)
            if !rest.isEmpty { commit(String(rest), from: .end) }
        } else if finalsText.isEmpty {
            commit(full, from: .end)
        }
        finishDictation()
    }

    private func streamError(_ error: Error) {
        NSLog("stream failed: \(error)")
        session?.cancel()
        session = nil
        streamFailed = true
        overlay.hide()
        if !recording { fallbackToBatch() }
    }

    /// One-shot transcription of the whole recording, used when the live stream breaks.
    private func fallbackToBatch() {
        let samples = pendingSamples
        // Held-back phrases were never pasted, so the whole recording can be transcribed again.
        if buffering { finalsText = "" }
        guard finalsText.isEmpty, !samples.isEmpty else { overlay.hide(); recordDictation(); setState(.ready); return }
        let wav = AudioRecorder.wav(from: samples)
        Task {
            do {
                let text = try await client.transcribe(wav: wav, hotwords: PersonalDictionary.shared.terms)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                await MainActor.run {
                    if !text.isEmpty { self.commit(text, from: .rerun) }
                    self.finishDictation()
                }
            } catch {
                NSLog("transcription failed: \(error)")
                await MainActor.run { self.setState(.error) }
            }
        }
    }

    private func recordDictation() {
        guard !dictationRecorded else { return }
        dictationRecorded = true
        if !finalsText.isEmpty { recorder.level.finish() }
        StatsStore.shared.record(text: lastText, raw: finalsText, seconds: dictationSeconds, appName: targetAppName, appBundle: targetAppBundle)
    }

    /// `whole` is a complete cleaned dictation rather than one streamed phrase of it.
    private func paste(_ text: String, whole: Bool = false) {
        lastText += (lastText.isEmpty ? "" : " ") + text
        lastItem.title = "Last: " + String(text.prefix(50))
        let kind = AppKind(bundle: targetAppBundle)
        var out = whole && kind == .chat ? CursorContext.droppingChatPeriod(text) : text
        let context = CursorContext.read()
        // Without a readable field, a trailing space keeps the next dictation from running into this one.
        out = context?.fit(out) ?? out + " "
        let rich = kind == .general || kind == .email ? RichText.flavors(for: out) : nil
        // A pasted list reads back without its "1." markers, which would look like edits.
        if insert(out, rich: rich), let context, rich == nil, StatsStore.shared.learnFromEdits {
            EditLearner.shared.watch(context, pasted: out, bundle: targetAppBundle, whole: whole)
        }
    }

    /// Command Mode's result replaces the selection exactly as written; with nothing selected it is fitted in
    /// at the cursor like a dictation. It is not watched for edits: it is the model's writing, not the user's.
    private func pasteCommandResult(_ text: String, replacing: Bool) {
        lastItem.title = "Last command: " + String(lastText.prefix(40))
        let kind = AppKind(bundle: targetAppBundle)
        let out = replacing ? text : (CursorContext.read()?.fit(text) ?? text + " ")
        insert(out, rich: kind == .general || kind == .email ? RichText.flavors(for: out) : nil)
    }

    /// Pastes into the focused app, or leaves the text on the clipboard and asks for Accessibility.
    @discardableResult
    private func insert(_ text: String, rich: (html: String, rtf: Data)?) -> Bool {
        if TextInserter.insert(text, rich: rich) {
            if state == .needsAccessibility { setState(recording ? .recording : .transcribing) }
            return true
        }
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary)
        setState(.needsAccessibility)
        return false
    }

    // MARK: - Permissions

    private func waitForHotkeyPermission() {
        if hotkey.start() { return }
        setState(.needsPermission)
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if self.hotkey.start() {
                timer.invalidate()
                // A fresh Input Monitoring grant only takes effect for a new process, so relaunch.
                self.relaunch()
            }
        }
    }

    private func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-n", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }

    // MARK: - UI

    private func buildMenu() {
        let menu = NSMenu()
        stateItem.isEnabled = false
        menu.addItem(stateItem)
        menu.addItem(.separator())
        let modeHeader = NSMenuItem(title: "Mode", action: nil, keyEquivalent: "")
        modeHeader.isEnabled = false
        menu.addItem(modeHeader)
        for item in [basicItem, aiItem] {
            item.target = self
            item.indentationLevel = 1
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.delegate = self
        lastItem.target = self
        menu.addItem(lastItem)
        let dash = NSMenuItem(title: "Open Dashboard…", action: #selector(openDashboard), keyEquivalent: "d")
        dash.target = self
        menu.addItem(dash)
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Murmrflow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func setState(_ state: State) {
        self.state = state
        let (symbol, text): (String, String) = switch state {
        case .loading: ("hourglass", "Loading model…")
        case .ready: ("mic", "Ready — hold Right Option to dictate (double-tap for hands-free, add Shift for Command Mode)")
        case .recording: ("mic.fill", "Listening…")
        case .transcribing: ("waveform", "Transcribing…")
        case .needsPermission: ("exclamationmark.triangle", "Enable Murmrflow under Input Monitoring & Accessibility in System Settings")
        case .needsAccessibility: ("exclamationmark.triangle", "Enable Murmrflow under Accessibility to paste (text copied to clipboard)")
        case .error: ("exclamationmark.circle", "Error — see ~/Library/Logs/Murmrflow")
        }
        stateItem.title = text
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: text)
    }

    @objc private func chooseBasic() { CleanupSettings.shared.enabled = false }
    @objc private func chooseAI() { CleanupSettings.shared.enabled = true }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            NSLog("launch at login failed: \(error)")
        }
        loginItem.state = service.status == .enabled ? .on : .off
        // macOS may need the user to approve the item once in System Settings → General → Login Items.
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    @objc private func openDashboard() {
        if dashboardWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 660),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.contentView = NSHostingView(rootView: DashboardView(store: .shared))
            window.title = "Murmrflow"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.center()
            dashboardWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        dashboardWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func copyLast() {
        guard !lastText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastText, forType: .string)
    }

    private func projectRoot() -> String {
        Bundle.main.object(forInfoDictionaryKey: "MurmrflowRoot") as? String
            ?? FileManager.default.currentDirectoryPath
    }
}

extension AppDelegate: NSMenuDelegate {
    /// The mode can also change in the dashboard, so the checkmarks are refreshed each time the menu opens.
    func menuWillOpen(_ menu: NSMenu) {
        let settings = CleanupSettings.shared
        basicItem.state = settings.enabled ? .off : .on
        aiItem.state = settings.enabled ? .on : .off
        aiItem.title = settings.hasKey ? "AI cleanup" : "AI cleanup (add a Groq key in Settings)"
    }
}
