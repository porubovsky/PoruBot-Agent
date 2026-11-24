import Foundation

enum GeminiImage {
    static let model = "gemini-nano-banana-2.1"

    struct Response: Decodable {
        struct Part: Decodable {
            let type: String?
            let data: Data?
            let mime_type: String?
        }
        struct Step: Decodable { let content: [Part]? }
        let steps: [Step]?
        let output_image: Part?
        let error: APIError?
        struct APIError: Decodable { let message: String }
    }

    static func generate(prompt: String, key: String, folder: URL, timeout: Int, session: URLSession = .shared) async throws -> URL {
        let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!
        var request = URLRequest(url: endpoint, timeoutInterval: TimeInterval(timeout))
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "input": [["type": "text", "text": prompt]], "store": false
        ])
        let (data, http) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let status = (http as? HTTPURLResponse)?.statusCode else { throw Failure("Нет ответа от Gemini API.") }
        let response = try? JSONDecoder().decode(Response.self, from: data)
        guard (200..<300).contains(status) else {
            throw Failure(response?.error?.message.replacingOccurrences(of: key, with: "[ключ скрыт]") ?? "Gemini API: HTTP \(status).")
        }
        guard let part = response?.output_image ?? response?.steps?.flatMap({ $0.content ?? [] }).last(where: { $0.type == "image" }),
              let image = part.data, !image.isEmpty else { throw Failure("Gemini API вернул ответ без картинки.") }
        let ext = ["image/png": "png", "image/jpeg": "jpg", "image/webp": "webp"][part.mime_type ?? ""]
        guard let ext else { throw Failure("Gemini API вернул неподдерживаемый формат картинки.") }
        let file = folder.appendingPathComponent("PoruBot-\(UUID().uuidString.prefix(12)).\(ext)")
        try image.write(to: file, options: .withoutOverwriting)
        return file
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
