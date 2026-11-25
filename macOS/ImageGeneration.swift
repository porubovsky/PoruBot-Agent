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
        guard !key.isEmpty else { throw Failure(tr("Вставь API-ключ провайдера.", "Enter the provider's API key.")) }
        let edits = self == .openAI && reference != nil
        let endpoint = self == .google ? "https://generativelanguage.googleapis.com/v1beta/interactions"
            : "https://api.openai.com/v1/images/" + (edits ? "edits" : "generations")
        var request = URLRequest(url: URL(string: endpoint)!, timeoutInterval: TimeInterval(timeout))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let sample = try reference.map { try Self.readReference($0) }
        if self == .google {
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            var input = [["type": "text", "text": prompt]]
            if let sample {
                input.append(["type": "image", "mime_type": sample.mime, "data": sample.bytes.base64EncodedString()])
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "input": input, "store": false])
        } else {
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
            if let sample {
                let boundary = UUID().uuidString
                request.setValue("multipart/form-data; boundary=" + boundary, forHTTPHeaderField: "Content-Type")
                var body = Data()
                for (name, value) in [("model", model), ("prompt", prompt), ("output_format", "png")] {
                    body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
                }
                body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"reference.\(sample.ext)\"\r\nContent-Type: \(sample.mime)\r\n\r\n".utf8))
                body.append(sample.bytes)
                body.append(Data("\r\n--\(boundary)--\r\n".utf8))
                request.httpBody = body
            } else {
                request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "prompt": prompt, "n": 1, "output_format": "png"])
            }
        }
        try Task.checkCancellation()
        let (data, http) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let status = (http as? HTTPURLResponse)?.statusCode else { throw Failure(tr("Нет ответа от API генерации.", "No response from the image API.")) }
        let decoder = JSONDecoder()
        guard (200..<300).contains(status) else {
            let error = try? decoder.decode(ErrorResponse.self, from: data)
            throw Failure(error?.error.message.replacingOccurrences(of: key, with: tr("[ключ скрыт]", "[key redacted]")) ?? "API: HTTP \(status).")
        }
        let image: Data
        let ext: String
        if self == .google {
            let response = try decoder.decode(Response.self, from: data)
            guard let part = response.output_image ?? response.steps?.flatMap({ $0.content ?? [] }).last(where: { $0.type == "image" }),
                  let bytes = part.data, !bytes.isEmpty else { throw Failure(tr("Gemini API вернул ответ без картинки.", "Gemini API returned no image.")) }
            guard let format = ["image/png": "png", "image/jpeg": "jpg", "image/webp": "webp"][part.mime_type ?? ""] else {
                throw Failure(tr("Gemini API вернул неподдерживаемый формат картинки.", "Gemini API returned an unsupported image format."))
            }
            image = bytes
            ext = format
        } else {
            let response = try decoder.decode(OpenAIResponse.self, from: data)
            guard let bytes = response.data.first?.b64_json, !bytes.isEmpty else {
                throw Failure(tr("OpenAI API вернул ответ без картинки.", "OpenAI API returned no image."))
            }
            image = bytes
            ext = "png"
        }
        let file = folder.appendingPathComponent("PoruBot-\(UUID().uuidString.prefix(12)).\(ext)")
        try image.write(to: file, options: .withoutOverwriting)
        return file
    }

    private static func readReference(_ reference: URL) throws -> (bytes: Data, mime: String, ext: String) {
        let ext = reference.pathExtension.lowercased()
        let formats = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "webp": "image/webp"]
        guard let mime = formats[ext] else {
            throw Failure(tr("Выбери образец в формате PNG, JPEG или WebP.", "Choose a PNG, JPEG, or WebP image."))
        }
        let file = try FileHandle(forReadingFrom: reference)
        defer { try? file.close() }
        let limit = 10 * 1024 * 1024
        let bytes = try file.read(upToCount: limit + 1) ?? Data()
        guard !bytes.isEmpty, bytes.count <= limit else {
            throw Failure(tr("Файл образца должен быть непустым и не больше 10 МБ.", "The reference file must be non-empty and at most 10 MB."))
        }
        return (bytes, mime, ext)
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
