using System.Net.Http.Json;
using System.Text.Json;

static class ImageGeneration
{
    private const string GoogleModel = "gemini-nano-banana-2.1";
    private const string OpenAIModel = "gpt-image-2.6-flare";
    public static string Name(Engine engine) => engine.Gemini ? "Nano Banana 2.1" : "GPT Image 2.6 Flare";
    private static readonly HttpClient Http = new();

    public static async Task<string> Generate(Engine engine, string prompt, string key, string folder, CancellationToken token, string? reference = null, HttpClient? client = null)
    {
        if (!engine.Gemini && !engine.Codex) throw new InvalidOperationException("Выбери Google или OpenAI.");
        using var request = new HttpRequestMessage(HttpMethod.Post, engine.Gemini
            ? "https://generativelanguage.googleapis.com/v1beta/interactions" : "https://api.openai.com/v1/images/generations");
        if (engine.Gemini)
        {
            request.Headers.Add("x-goog-api-key", key);
            var input = new List<object> { new { type = "text", text = prompt } };
            if (reference is not null)
            {
                var mime = Path.GetExtension(reference).ToLowerInvariant() switch
                {
                    ".png" => "image/png",
                    ".jpg" or ".jpeg" => "image/jpeg",
                    ".webp" => "image/webp",
                    _ => throw new InvalidOperationException("Выбери образец в формате PNG, JPEG или WebP.")
                };
                await using var source = File.OpenRead(reference);
                if (source.Length is <= 0 or > 10 * 1024 * 1024)
                    throw new InvalidOperationException("Файл образца должен быть непустым и не больше 10 МБ.");
                var sample = new byte[source.Length];
                await source.ReadExactlyAsync(sample, token);
                input.Add(new { type = "image", mime_type = mime, data = Convert.ToBase64String(sample) });
            }
            request.Content = JsonContent.Create(new { model = GoogleModel, input, store = false });
        }
        else
        {
            request.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", key);
            request.Content = JsonContent.Create(new { model = OpenAIModel, prompt, n = 1, output_format = "png" });
        }
        using var result = await (client ?? Http).SendAsync(request, token);
        if (!result.IsSuccessStatusCode)
        {
            var reason = $"API: HTTP {(int)result.StatusCode}.";
            try
            {
                using var body = JsonDocument.Parse(await result.Content.ReadAsStringAsync(token));
                if (body.RootElement.TryGetProperty("error", out var error) && error.TryGetProperty("message", out var message))
                    reason = message.GetString()?.Replace(key, "[ключ скрыт]") ?? reason;
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
                throw new InvalidOperationException("OpenAI API вернул ответ без картинки.");
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
                throw new InvalidOperationException("Gemini API вернул ответ без картинки.");
            extension = image.GetProperty("mime_type").GetString() switch
            {
                "image/png" => "png",
                "image/jpeg" => "jpg",
                "image/webp" => "webp",
                _ => throw new InvalidOperationException("Gemini API вернул неподдерживаемый формат картинки.")
            };
            bytes = data.GetBytesFromBase64();
        }
        if (bytes.Length == 0) throw new InvalidOperationException("API вернул пустую картинку.");
        token.ThrowIfCancellationRequested();
        var path = Path.Combine(folder, $"PoruBot-{Guid.NewGuid().ToString("N")[..12]}.{extension}");
        await using var file = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None);
        try { await file.WriteAsync(bytes, token); }
        catch { file.Close(); File.Delete(path); throw; }
        return path;
    }
}
