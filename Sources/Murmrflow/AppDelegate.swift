import AppKit
import AVFoundation
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let port = 8010
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let stateItem = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let lastItem = NSMenuItem(title: "No dictation yet", action: #selector(copyLast), keyEquivalent: "")
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

    private enum State { case loading, ready, recording, transcribing, needsPermission, needsAccessibility, error }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        setState(.loading)
        if CommandLine.arguments.contains("--dashboard") { openDashboard() }

        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary)

        hotkey.onPress = { [weak self] in self?.beginRecording() }
        hotkey.onRelease = { [weak self] in self?.finishRecording() }
        waitForHotkeyPermission()

        Task {
            await server.startIfNeeded(client: client)
            while !(await client.isReady()) { try? await Task.sleep(nanoseconds: 500_000_000) }
            await MainActor.run { if !self.recording { self.setState(.ready) } }
        }
    }

    func applicationWillTerminate(_ notification: Notification) { server.stop() }

    // MARK: - Dictation flow

    private func beginRecording() {
        guard !recording else { return }
        finalsText = ""
        lastText = ""
        streamFailed = false
        dictationRecorded = false
        let target = NSWorkspace.shared.frontmostApplication
        targetAppName = target?.localizedName
        targetAppBundle = target?.bundleIdentifier
        let stream = StreamingSession(port: port)
        stream.onPartial = { [weak self] in self?.overlay.update($0) }
        stream.onFinal = { [weak self] in self?.commit($0) }
        stream.onDone = { [weak self] in self?.streamDone($0) }
        stream.onError = { [weak self] in self?.streamError($0) }
        session = stream
        recorder.onChunk = { [weak stream] in stream?.send($0) }
        stream.start()
        do {
            try recorder.start()
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

    private func finishRecording() {
        guard recording else { return }
        recording = false
        let samples = recorder.stop()
        let seconds = Date().timeIntervalSince(recordStart)
        guard seconds > 0.3, !samples.isEmpty else {
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

    /// A finished phrase: paste it into the focused app.
    private func commit(_ phrase: String) {
        let text = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        finalsText += (finalsText.isEmpty ? "" : " ") + text
        overlay.update("")
        paste(text)
    }

    private func streamDone(_ full: String) {
        session = nil
        // Phrases already pasted via `final` messages must not be pasted again.
        let full = full.trimmingCharacters(in: .whitespacesAndNewlines)
        if full.hasPrefix(finalsText) {
            let rest = full.dropFirst(finalsText.count).trimmingCharacters(in: .whitespacesAndNewlines)
            if !rest.isEmpty { commit(String(rest)) }
        } else if finalsText.isEmpty {
            commit(full)
        }
        overlay.hide()
        recordDictation()
        if state != .needsAccessibility { setState(.ready) }
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
        guard finalsText.isEmpty, !samples.isEmpty else { overlay.hide(); recordDictation(); setState(.ready); return }
        let wav = AudioRecorder.wav(from: samples)
        Task {
            do {
                let text = try await client.transcribe(wav: wav).trimmingCharacters(in: .whitespacesAndNewlines)
                await MainActor.run {
                    if !text.isEmpty { self.commit(text) }
                    self.recordDictation()
                    if self.state != .needsAccessibility { self.setState(.ready) }
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
        StatsStore.shared.record(text: lastText, seconds: dictationSeconds, appName: targetAppName, appBundle: targetAppBundle)
    }

    private func paste(_ text: String) {
        lastText += (lastText.isEmpty ? "" : " ") + text
        lastItem.title = "Last: " + String(text.prefix(50))
        if TextInserter.insert(text + " ") {
            if state == .needsAccessibility { setState(recording ? .recording : .transcribing) }
        } else {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary)
            setState(.needsAccessibility)
        }
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
        lastItem.target = self
        menu.addItem(lastItem)
        let dash = NSMenuItem(title: "Open Dashboard…", action: #selector(openDashboard), keyEquivalent: "d")
        dash.target = self
        menu.addItem(dash)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Murmrflow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func setState(_ state: State) {
        self.state = state
        let (symbol, text): (String, String) = switch state {
        case .loading: ("hourglass", "Loading model…")
        case .ready: ("mic", "Ready — hold Right Option to dictate")
        case .recording: ("mic.fill", "Listening…")
        case .transcribing: ("waveform", "Transcribing…")
        case .needsPermission: ("exclamationmark.triangle", "Enable Murmrflow under Input Monitoring & Accessibility in System Settings")
        case .needsAccessibility: ("exclamationmark.triangle", "Enable Murmrflow under Accessibility to paste (text copied to clipboard)")
        case .error: ("exclamationmark.circle", "Error — see ~/Library/Logs/Murmrflow")
        }
        stateItem.title = text
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: text)
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
