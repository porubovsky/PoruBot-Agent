import Foundation

enum ImageGeneration: Equatable {
    case google, openAI

    var model: String {
        self == .google ? "gemini-nano-banana-2.1" : "gpt-image-2.6-flare"
    }

    var name: String { self == .google ? "Nano Banana 2.1" : "GPT Image 2.6 Flare" }

    struct OpenAIResponse: Decodable {
        struct Item: Decodable { let b64_json: Data? }
        let data: [Item]
    }

    struct ErrorResponse: Decodable {
        struct Detail: Decodable { let message: String }
        let error: Detail
    }

    struct Response: Decodable {
        struct Part: Decodable {
            let type: String?
            let data: Data?
            let mime_type: String?
        }
        struct Step: Decodable { let content: [Part]? }
        let steps: [Step]?
        let output_image: Part?
    }

    func generate(prompt: String, key: String, folder: URL, timeout: Int, reference: URL? = nil, session: URLSession = .shared) async throws -> URL {
        guard !key.isEmpty else { throw Failure("Вставь API-ключ провайдера.") }
        let endpoint = self == .google ? "https://generativelanguage.googleapis.com/v1beta/interactions"
                                      : "https://api.openai.com/v1/images/generations"
        var request = URLRequest(url: URL(string: endpoint)!, timeoutInterval: TimeInterval(timeout))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any]
        if self == .google {
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            var input = [["type": "text", "text": prompt]]
            if let reference {
                let formats = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "webp": "image/webp"]
                guard let mime = formats[reference.pathExtension.lowercased()] else {
                    throw Failure("Выбери образец в формате PNG, JPEG или WebP.")
                }
                let file = try FileHandle(forReadingFrom: reference)
                defer { try? file.close() }
                let limit = 10 * 1024 * 1024
                let bytes = try file.read(upToCount: limit + 1) ?? Data()
                guard !bytes.isEmpty, bytes.count <= limit else {
                    throw Failure("Файл образца должен быть непустым и не больше 10 МБ.")
                }
                input.append(["type": "image", "mime_type": mime, "data": bytes.base64EncodedString()])
            }
            payload = ["model": model, "input": input, "store": false]
        } else {
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
            payload = ["model": model, "prompt": prompt, "n": 1, "output_format": "png"]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        try Task.checkCancellation()
        let (data, http) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let status = (http as? HTTPURLResponse)?.statusCode else { throw Failure("Нет ответа от API генерации.") }
        let decoder = JSONDecoder()
        guard (200..<300).contains(status) else {
            let error = try? decoder.decode(ErrorResponse.self, from: data)
            throw Failure(error?.error.message.replacingOccurrences(of: key, with: "[ключ скрыт]") ?? "API: HTTP \(status).")
        }
        let image: Data
        let ext: String
        if self == .google {
            let response = try decoder.decode(Response.self, from: data)
            guard let part = response.output_image ?? response.steps?.flatMap({ $0.content ?? [] }).last(where: { $0.type == "image" }),
                  let bytes = part.data, !bytes.isEmpty else { throw Failure("Gemini API вернул ответ без картинки.") }
            guard let format = ["image/png": "png", "image/jpeg": "jpg", "image/webp": "webp"][part.mime_type ?? ""] else {
                throw Failure("Gemini API вернул неподдерживаемый формат картинки.")
            }
            image = bytes
            ext = format
        } else {
            let response = try decoder.decode(OpenAIResponse.self, from: data)
            guard let bytes = response.data.first?.b64_json, !bytes.isEmpty else {
                throw Failure("OpenAI API вернул ответ без картинки.")
            }
            image = bytes
            ext = "png"
        }
        let file = folder.appendingPathComponent("PoruBot-\(UUID().uuidString.prefix(12)).\(ext)")
        try image.write(to: file, options: .withoutOverwriting)
        return file
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
