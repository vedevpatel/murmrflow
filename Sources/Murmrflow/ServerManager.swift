import Foundation

/// Starts and supervises `fermion serve` so the model stays loaded between dictations.
/// If something already answers on the port (e.g. a manually started server) it is reused and left alone.
final class ServerManager {
    let port: Int
    private let fermionPath: String
    private var process: Process?

    init(root: String, port: Int) {
        self.port = port
        self.fermionPath = root + "/.venv/bin/fermion"
    }

    func startIfNeeded(client: ASRClient) async {
        if await client.isReady() { return }
        guard FileManager.default.isExecutableFile(atPath: fermionPath) else {
            NSLog("fermion not found at \(fermionPath)")
            return
        }
        let logDir = NSHomeDirectory() + "/Library/Logs/Murmrflow"
        try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        let logPath = logDir + "/server.log"
        FileManager.default.createFile(atPath: logPath, contents: nil)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: fermionPath)
        p.arguments = ["serve", "phonon-2.5-en", "--port", String(port)]
        if let log = FileHandle(forWritingAtPath: logPath) {
            p.standardOutput = log
            p.standardError = log
        }
        do { try p.run(); process = p } catch { NSLog("failed to launch server: \(error)") }
    }

    func stop() {
        process?.terminate()
        process = nil
    }
}
