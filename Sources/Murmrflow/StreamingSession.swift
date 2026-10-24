import Foundation

/// One live transcription over the server's `/v1/audio/stream` WebSocket.
/// Callbacks are delivered on the main queue.
final class StreamingSession {
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onDone: ((String) -> Void)?
    var onError: ((Error) -> Void)?

    private let task: URLSessionWebSocketTask
    private var finished = false

    init(port: Int) {
        task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/v1/audio/stream")!)
    }

    func start() {
        task.resume()
        task.send(.string(#"{"sample_rate":16000,"format":"pcm_s16le"}"#)) { [weak self] in self?.sendFailed($0) }
        receive()
    }

    func send(_ pcm: Data) {
        task.send(.data(pcm)) { [weak self] in self?.sendFailed($0) }
    }

    func end() {
        task.send(.string(#"{"type":"end"}"#)) { [weak self] in self?.sendFailed($0) }
    }

    func cancel() {
        finished = true
        task.cancel(with: .normalClosure, reason: nil)
    }

    private func sendFailed(_ error: Error?) {
        if let error { fail(error) }
    }

    private func fail(_ error: Error) {
        DispatchQueue.main.async {
            guard !self.finished else { return }
            self.finished = true
            self.task.cancel(with: .goingAway, reason: nil)
            self.onError?(error)
        }
    }

    private func receive() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.fail(error)
            case .success(let message):
                guard case .string(let json) = message,
                      let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                      let type = obj["type"] as? String else { self.receive(); return }
                let text = obj["text"] as? String ?? ""
                DispatchQueue.main.async {
                    guard !self.finished else { return }
                    switch type {
                    case "partial": self.onPartial?(text)
                    case "final": self.onFinal?(text)
                    case "done":
                        self.finished = true
                        self.task.cancel(with: .normalClosure, reason: nil)
                        self.onDone?(text)
                    case "error":
                        self.finished = true
                        self.task.cancel(with: .goingAway, reason: nil)
                        self.onError?(NSError(domain: "ASR", code: 2, userInfo: [NSLocalizedDescriptionKey: obj["message"] as? String ?? "stream error"]))
                    default: break
                    }
                }
                if type != "done" && type != "error" { self.receive() }
            }
        }
    }
}
