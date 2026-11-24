using System.Net.Http.Json;
using System.Text.Json;

static class GeminiImage
{
    public const string Model = "gemini-3.1-flash-image";
    private static readonly HttpClient Http = new();

    public static async Task<string> Generate(string prompt, string key, string folder, CancellationToken token)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post,
            "https://generativelanguage.googleapis.com/v1beta/interactions");
        request.Headers.Add("x-goog-api-key", key);
        request.Content = JsonContent.Create(new { model = Model, input = new[] { new { type = "text", text = prompt } }, store = false });
        using var result = await Http.SendAsync(request, token);
        if (!result.IsSuccessStatusCode)
        {
            var reason = $"Gemini API: HTTP {(int)result.StatusCode}.";
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
        var extension = image.GetProperty("mime_type").GetString() switch
        {
            "image/png" => "png",
            "image/jpeg" => "jpg",
            "image/webp" => "webp",
            _ => throw new InvalidOperationException("Gemini API вернул неподдерживаемый формат картинки.")
        };
        var bytes = data.GetBytesFromBase64();
        token.ThrowIfCancellationRequested();
        var path = Path.Combine(folder, $"PoruBot-{Guid.NewGuid().ToString("N")[..12]}.{extension}");
        await using var file = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None);
        try { await file.WriteAsync(bytes, token); }
        catch { file.Close(); File.Delete(path); throw; }
        return path;
    }
}
