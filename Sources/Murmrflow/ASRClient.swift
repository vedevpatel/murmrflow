import Foundation

/// Talks to the local `fermion serve` process (OpenAI-compatible transcription endpoint).
struct ASRClient {
    let baseURL: URL

    init(port: Int) { baseURL = URL(string: "http://127.0.0.1:\(port)")! }

    func isReady() async -> Bool {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/models"))
        req.timeoutInterval = 1
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    /// `hotwords` are names and terms the decoder should favour; the server takes at most 25.
    func transcribe(wav: Data, hotwords: [String] = []) async throws -> String {
        let boundary = "murmrflow-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("model", "phonon-2.5-en")
        if !hotwords.isEmpty, let list = try? JSONSerialization.data(withJSONObject: Array(hotwords.prefix(25))) {
            field("hotwords", String(decoding: list, as: UTF8.self))
            // The default bonus (2) rarely changes the output; 8 fixes made-up names without pulling in near-misses.
            field("hotword_lambda", "8")
        }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: baseURL.appendingPathComponent("v1/audio/transcriptions"))
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "ASR", code: 1, userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "server error"])
        }
        struct Result: Decodable { let text: String }
        return try JSONDecoder().decode(Result.self, from: data).text
    }
}
