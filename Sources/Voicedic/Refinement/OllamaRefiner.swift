import Foundation

/// Cleanup with any model served by a local Ollama instance.
struct OllamaRefiner: Refiner {
    let baseURL: URL
    let model: String

    func prepare(style: RefinementStyle) async {
        guard !model.isEmpty else { return }
        // An empty chat loads the model into memory and keeps it there.
        let body: [String: Any] = ["model": model, "messages": [], "keep_alive": "30m"]
        _ = try? await post("api/chat", body: body, timeout: 120)
    }

    func refine(_ request: RefinementRequest, style: RefinementStyle) async throws -> String {
        guard !model.isEmpty else {
            throw RefinementError.unavailable("Choose an Ollama model in Settings → Cleanup.")
        }
        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": RefinementPrompt.instructions(style: style)],
                ["role": "user", "content": RefinementPrompt.userMessage(for: request)],
            ],
            "stream": false,
            "think": false,
            "keep_alive": "30m",
            "options": ["temperature": 0],
        ]

        var (data, status) = try await post("api/chat", body: body, timeout: 60)
        if status == 400, String(decoding: data, as: UTF8.self).contains("think") {
            // Older Ollama builds reject the `think` flag for non-reasoning models.
            body.removeValue(forKey: "think")
            (data, status) = try await post("api/chat", body: body, timeout: 60)
        }
        guard status == 200 else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw RefinementError.unavailable("Ollama: \(detail ?? "HTTP \(status)")")
        }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let message = object?["message"] as? [String: Any]
        return message?["content"] as? String ?? ""
    }

    static func listModels(baseURL: URL) async throws -> [String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 3
        let (data, _) = try await URLSession.shared.data(for: request)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let models = object?["models"] as? [[String: Any]] ?? []
        return models.compactMap { $0["name"] as? String }.sorted()
    }

    private func post(_ path: String, body: [String: Any], timeout: TimeInterval) async throws -> (Data, Int) {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = timeout
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch let error as URLError where error.code == .cannotConnectToHost {
            throw RefinementError.unavailable("Ollama isn't running. Start it with `ollama serve`.")
        }
    }
}
