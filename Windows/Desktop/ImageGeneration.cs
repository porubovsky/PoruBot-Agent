using static L10n;
using System.Net.Http.Json;
using System.Text.Json;

static class ImageGeneration
{
    private const string GoogleModel = "gemini-nano-banana-2.1";
    private const string OpenAIModel = "gpt-image-2.6-flare";
    public static string Name(Engine engine) => engine.Gemini ? "Nano Banana 2.1" : "GPT Image 2.6 Flare";
    private static readonly HttpClient Http = new();

    private sealed record ReferenceImage(byte[] Bytes, string Mime, string Extension);

    private static async Task<ReferenceImage> ReadReference(string path, CancellationToken token)
    {
        var extension = Path.GetExtension(path).ToLowerInvariant();
        var mime = extension switch
        {
            ".png" => "image/png",
            ".jpg" or ".jpeg" => "image/jpeg",
            ".webp" => "image/webp",
            _ => throw new InvalidOperationException(T("Выбери образец в формате PNG, JPEG или WebP.", "Choose a PNG, JPEG, or WebP image."))
        };
        await using var source = File.OpenRead(path);
        if (source.Length is <= 0 or > 10 * 1024 * 1024)
            throw new InvalidOperationException(T("Файл образца должен быть непустым и не больше 10 МБ.", "The reference file must be non-empty and at most 10 MB."));
        var bytes = new byte[source.Length];
        await source.ReadExactlyAsync(bytes, token);
        return new(bytes, mime, extension);
    }

    public static async Task<string> Generate(Engine engine, string prompt, string key, string folder, CancellationToken token, string? reference = null, HttpClient? client = null)
    {
        if (!engine.Gemini && !engine.Codex) throw new InvalidOperationException(T("Выбери Google или OpenAI.", "Choose Google or OpenAI."));
        var edits = engine.Codex && reference is not null;
        using var request = new HttpRequestMessage(HttpMethod.Post, engine.Gemini
            ? "https://generativelanguage.googleapis.com/v1beta/interactions"
            : "https://api.openai.com/v1/images/" + (edits ? "edits" : "generations"));
        var sample = reference is null ? null : await ReadReference(reference, token);
        if (engine.Gemini)
        {
            request.Headers.Add("x-goog-api-key", key);
            var input = new List<object> { new { type = "text", text = prompt } };
            if (sample is { } image)
                input.Add(new { type = "image", mime_type = image.Mime, data = Convert.ToBase64String(image.Bytes) });
            request.Content = JsonContent.Create(new { model = GoogleModel, input, store = false });
        }
        else
        {
            request.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", key);
            if (sample is { } image)
            {
                var form = new MultipartFormDataContent();
                request.Content = form;
                form.Add(new StringContent(OpenAIModel), "model");
                form.Add(new StringContent(prompt), "prompt");
                form.Add(new StringContent("png"), "output_format");
                var imagePart = new ByteArrayContent(image.Bytes);
                imagePart.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue(image.Mime);
                form.Add(imagePart, "image", "reference" + image.Extension);
            }
            else request.Content = JsonContent.Create(new { model = OpenAIModel, prompt, n = 1, output_format = "png" });
        }
        using var result = await (client ?? Http).SendAsync(request, token);
        if (!result.IsSuccessStatusCode)
        {
            var reason = $"API: HTTP {(int)result.StatusCode}.";
            try
            {
                using var body = JsonDocument.Parse(await result.Content.ReadAsStringAsync(token));
                if (body.RootElement.TryGetProperty("error", out var error) && error.TryGetProperty("message", out var message))
                    reason = message.GetString()?.Replace(key, T("[ключ скрыт]", "[key redacted]")) ?? reason;
            }
            catch (JsonException) { }
            throw new InvalidOperationException(reason);
        }
        using var document = JsonDocument.Parse(await result.Content.ReadAsStringAsync(token));
        var root = document.RootElement;
        string extension;
        byte[] bytes;
        if (engine.Codex)
        {
            if (!root.TryGetProperty("data", out var images) || images.ValueKind != JsonValueKind.Array ||
                images.GetArrayLength() == 0 || !images[0].TryGetProperty("b64_json", out var encoded))
                throw new InvalidOperationException(T("OpenAI API вернул ответ без картинки.", "OpenAI API returned no image."));
            bytes = encoded.GetBytesFromBase64();
            extension = "png";
        }
        else
        {
            var image = root.TryGetProperty("output_image", out var direct) && direct.ValueKind == JsonValueKind.Object
                ? direct : default;
            if (image.ValueKind == JsonValueKind.Undefined && root.TryGetProperty("steps", out var steps))
            {
                foreach (var step in steps.EnumerateArray())
                    if (step.TryGetProperty("content", out var content))
                        foreach (var part in content.EnumerateArray())
                            if (part.TryGetProperty("type", out var type) && type.GetString() == "image") image = part;
            }
            if (image.ValueKind == JsonValueKind.Undefined || !image.TryGetProperty("data", out var data))
                throw new InvalidOperationException(T("Gemini API вернул ответ без картинки.", "Gemini API returned no image."));
            extension = image.GetProperty("mime_type").GetString() switch
            {
                "image/png" => "png",
                "image/jpeg" => "jpg",
                "image/webp" => "webp",
                _ => throw new InvalidOperationException(T("Gemini API вернул неподдерживаемый формат картинки.", "Gemini API returned an unsupported image format."))
            };
            bytes = data.GetBytesFromBase64();
        }
        if (bytes.Length == 0) throw new InvalidOperationException(T("API вернул пустую картинку.", "The API returned an empty image."));
        token.ThrowIfCancellationRequested();
        var path = Path.Combine(folder, $"PoruBot-{Guid.NewGuid().ToString("N")[..12]}.{extension}");
        await using var file = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None);
        try { await file.WriteAsync(bytes, token); }
        catch { file.Close(); File.Delete(path); throw; }
        return path;
    }
}
