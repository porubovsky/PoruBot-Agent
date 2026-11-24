using System.Globalization;
using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

record Engine(string Name, string Binary, string Key, string Installer, string[] Models)
{
    public static readonly Engine[] All =
    [
        new("Antigravity", "agy", "GEMINI_API_KEY", "https://antigravity.google/cli/install.cmd",
            ["gemini-3.8-flash", "gemini-3.7-flash", "gemini-3.6-flash"]),
        new("Claude Code", "claude", "ANTHROPIC_API_KEY", "https://claude.ai/install.cmd", ["sonnet", "haiku", "opus"]),
        new("Codex", "codex", "CODEX_API_KEY", "https://chatgpt.com/codex/install.ps1", ["gpt-5.4-mini", "gpt-5.4"]),
        new("OpenRouter", "claude", "OPENROUTER_API_KEY", "https://claude.ai/install.cmd",
            ["~anthropic/claude-sonnet-latest", "~anthropic/claude-haiku-latest", "~anthropic/claude-opus-latest"])
    ];
    public bool Gemini => Binary == "agy";
    public bool Codex => Binary == "codex";
    public bool Router => Name == "OpenRouter";
    public override string ToString() => Name;

    public string? Find()
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var path = (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator);
        IEnumerable<string> roots = [
            Path.Combine(home, ".local", "bin"),
            Path.Combine(home, ".local", "bin", "agy"),
            Path.Combine(appData, "Programs", "OpenAI", "Codex", "bin")
        ];
        return roots.Concat(path).Where(p => !string.IsNullOrWhiteSpace(p))
            .Select(p => Path.Combine(p.Trim('"'), Binary + ".exe")).FirstOrDefault(File.Exists);
    }
}

record SavedSession(string Id, string Engine, string Folder, string Title)
{
    public override string ToString() => Title;
}
record Settings(bool AllCommands = false, bool AllFolders = false, bool OutsideSandbox = false, string Folder = "", string Theme = "system",
    SavedSession[]? Sessions = null)
{
    private static readonly string DirectoryPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "PoruBot Agent");
    private static string Config => Path.Combine(DirectoryPath, "settings.json");
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
    public static Settings Read()
    {
        try { return JsonSerializer.Deserialize<Settings>(File.ReadAllText(Config), JsonOptions) ?? new(); }
        catch (IOException) { return new(); }
        catch (JsonException) { return new(); }
    }
    public void Save()
    {
        Directory.CreateDirectory(DirectoryPath);
        var temporary = Config + "." + Guid.NewGuid().ToString("N");
        try
        {
            File.WriteAllText(temporary, JsonSerializer.Serialize(this, JsonOptions));
            File.Move(temporary, Config, true);
        }
        finally { File.Delete(temporary); }
    }
    public static string? ReadKey(Engine engine)
    {
        var file = Path.Combine(DirectoryPath, engine.Key + ".bin");
        return File.Exists(file) ? Encoding.UTF8.GetString(ProtectedData.Unprotect(
            File.ReadAllBytes(file), null, DataProtectionScope.CurrentUser)) : null;
    }
    public static void SaveKey(Engine engine, string key)
    {
        Directory.CreateDirectory(DirectoryPath);
        File.WriteAllBytes(Path.Combine(DirectoryPath, engine.Key + ".bin"),
            ProtectedData.Protect(Encoding.UTF8.GetBytes(key), null, DataProtectionScope.CurrentUser));
    }
}

record AgentRequest(Engine Engine, string Key, string Folder, string Model, string Effort, bool Plan,
    Settings Access, string Prompt, bool Catalog, IReadOnlyDictionary<(string, string), string> Models, string? SessionId = null);
record AgentResult(string Answer, string Diagnostics, bool Success, string Usage, string? SessionId, double? Cost, JsonElement ModelUsage);
record ProcessOutput(int Code, string Stdout, string Stderr);

static class Agent
{
    private static readonly string[] RemovedEnvironment =
    [
        "GEMINI_API_KEY", "GOOGLE_API_KEY", "OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN",
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "OPENROUTER_API_KEY",
        "ANTHROPIC_BASE_URL", "OPENAI_BASE_URL", "GOOGLE_GEMINI_BASE_URL", "CLAUDE_CODE_USE_BEDROCK",
        "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"
    ];

    public static async Task<ProcessOutput> Run(AgentRequest r, Action<string> status, CancellationToken token)
    {
        string executable = r.Engine.Find() ?? await Install(r.Engine, status, token);
        var environment = new Dictionary<string, string> { [r.Engine.Key] = r.Key };
        if (r.Engine.Router)
        {
            environment.Clear();
            environment["ANTHROPIC_BASE_URL"] = "https://openrouter.ai/api";
            environment["ANTHROPIC_AUTH_TOKEN"] = r.Key;
            environment["ANTHROPIC_API_KEY"] = "";
        }

        List<string> args = [];
        var payload = r.Catalog ? "" : r.Prompt;
        List<string> folders = [];
        if (r.Access.AllFolders && !r.Plan && !r.Catalog)
        {
            foreach (var drive in DriveInfo.GetDrives().Where(d => d.IsReady && d.DriveType is DriveType.Fixed or DriveType.Removable))
                folders.AddRange(["--add-dir", drive.RootDirectory.FullName]);
        }
        string model = r.Model;
        string effort = r.Effort;
        if (r.Engine.Gemini)
        {
            var options = new Dictionary<string, object> { ["modelProvider"] = "gemini" };
            bool sandbox = r.Catalog || r.Plan || !r.Access.OutsideSandbox;
            if (!sandbox) options["enableTerminalSandbox"] = false;
            if (r.Access.AllCommands && !r.Catalog && !r.Plan)
                options["permissions"] = new { allow = new[] { "command(*)" } };
            args.AddRange(["--settings", JsonSerializer.Serialize(options)]);
            if (r.Catalog)
            {
                status("Читаю каталог моделей…");
                args.Add("models");
                return await Child(executable, args, Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "", environment, token);
            }
            if (r.SessionId is { } conversation) args.AddRange(["--conversation", conversation]);
            args.AddRange(["--input-format", "stream-json", "--output-format", "stream-json", "--disable-slash-commands",
                sandbox ? "--sandbox" : "--sandbox=false", "--mode", r.Plan ? "plan" : "accept-edits"]);
            if (r.Models.TryGetValue((model, effort), out var id)) { model = id; effort = ""; }
            else if (System.Text.RegularExpressions.Regex.IsMatch(model, @"^gemini-.*-(minimal|low|medium|high|xhigh|max)$"))
                effort = "";
            else if (effort.Length > 0 && r.Engine.Models.Contains(model)) { model += "-" + effort; effort = ""; }
            if (model.Length == 0) effort = "";
            payload = JsonSerializer.Serialize(new { @event = "user", message = new { content = payload } }) + "\n";
        }
        else if (r.Engine.Codex)
        {
            args.AddRange(["exec", "--json", "--skip-git-repo-check", "--sandbox",
                r.Plan ? "read-only" : "workspace-write", "-c", """model_provider="openai" """.TrimEnd(),
                "-c", """shell_environment_policy.exclude=["CODEX_API_KEY","OPENAI_API_KEY"]"""]);
        }
        else
        {
            args.AddRange(["-p", "--verbose", "--output-format", "stream-json", "--no-session-persistence",
                "--permission-mode", r.Plan ? "plan" : "acceptEdits", "--disallowedTools", "Bash,PowerShell,Monitor"]);
        }

        args.AddRange(folders);
        if (model.Length > 0) args.AddRange(["--model", model]);
        if (effort.Length > 0)
            args.AddRange(r.Engine.Codex ? ["-c", $"model_reasoning_effort=\"{effort}\""] : ["--effort", effort]);
        if (r.Engine.Codex)
        {
            if (r.SessionId is { } thread) args.AddRange(["resume", thread]);
            args.Add("-");
        }
        status($"Работает {r.Engine.Name}…");
        string? previous = null;
        return await Child(executable, args, r.Folder, payload, environment, token, line =>
        {
            if (DescribeProgress(r.Engine, line) is not { } phase || phase == previous) return;
            previous = phase;
            status(phase);
        });
    }

    private static async Task<string> Install(Engine engine, Action<string> status, CancellationToken token)
    {
        var system = Environment.GetFolderPath(Environment.SpecialFolder.System);
        var extension = engine.Codex ? ".ps1" : ".cmd";
        var temporary = Directory.CreateTempSubdirectory("porubot-");
        var filename = "install" + extension;
        try
        {
            status($"Загружаю официальный установщик {engine.Binary}…");
            var download = await Child(Path.Combine(system, "curl.exe"),
                ["-fsSL", "--proto", "=https", "--proto-redir", "=https", engine.Installer, "-o", filename],
                temporary.FullName, "", [], token);
            token.ThrowIfCancellationRequested();
            if (download.Code != 0) throw new InvalidOperationException(download.Stderr);
            status($"Устанавливаю {engine.Binary}…");
            var install = engine.Codex
                ? await Child(Path.Combine(system, "WindowsPowerShell", "v1.0", "powershell.exe"),
                    ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", filename],
                    temporary.FullName, "", new() { ["CODEX_NON_INTERACTIVE"] = "1" }, token)
                : await Child(Path.Combine(system, "cmd.exe"), ["/d", "/c", filename],
                    temporary.FullName, "", [], token);
            token.ThrowIfCancellationRequested();
            if (install.Code != 0) throw new InvalidOperationException(install.Stderr + "\n" + install.Stdout);
            return engine.Find() ?? throw new InvalidOperationException("CLI не найден после установки.");
        }
        finally { try { temporary.Delete(true); } catch (IOException) { } }
    }

    private static async Task<ProcessOutput> Child(string executable, IEnumerable<string> args, string folder,
        string input, Dictionary<string, string> environment, CancellationToken token, Action<string>? onLine = null)
    {
        var start = new ProcessStartInfo(executable)
        {
            WorkingDirectory = folder, UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
            StandardInputEncoding = new UTF8Encoding(false), StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8
        };
        foreach (var arg in args) start.ArgumentList.Add(arg);
        foreach (var name in RemovedEnvironment) start.Environment.Remove(name);
        foreach (var item in environment) start.Environment[item.Key] = item.Value;
        token.ThrowIfCancellationRequested();
        using var process = Process.Start(start) ?? throw new InvalidOperationException("Не удалось запустить CLI.");
        using var stop = token.Register(() =>
        {
            try { if (!process.HasExited) process.Kill(entireProcessTree: true); }
            catch (InvalidOperationException) { }
            catch (System.ComponentModel.Win32Exception) { }
        });
        var stdout = onLine is null ? process.StandardOutput.ReadToEndAsync() : Task.Run(async () =>
        {
            var output = new StringBuilder();
            while (await process.StandardOutput.ReadLineAsync() is { } line)
            {
                output.AppendLine(line);
                onLine(line);
            }
            return output.ToString();
        });
        var stderr = process.StandardError.ReadToEndAsync();
        try { if (input.Length > 0) await process.StandardInput.WriteAsync(input.AsMemory(), token); }
        catch (IOException) { }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        finally { try { process.StandardInput.Close(); } catch (IOException) { } }
        await process.WaitForExitAsync();
        return new(process.ExitCode, await stdout, await stderr);
    }

    static string Text(JsonElement element, string name) =>
        element.ValueKind == JsonValueKind.Object && element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
        ? value.GetString() ?? "" : "";

    internal static string? DescribeProgress(Engine engine, string line)
    {
        if (!line.TrimStart().StartsWith('{')) return null;
        try
        {
            using var document = JsonDocument.Parse(line);
            var root = document.RootElement;
            if (engine.Gemini)
            {
                if (Text(root, "event") == "init") return "Сессия запущена…";
                if (Text(root, "event") != "step_update" || !root.TryGetProperty("step_update", out var step)) return null;
                var tool = Text(step, "tool_name");
                var type = Text(step, "step_type");
                return Activity(tool.Length > 0 ? tool : type);
            }
            if (engine.Codex)
            {
                var type = Text(root, "type");
                if (type == "turn.started") return "Изучаю задачу…";
                if (type == "item.started" && root.TryGetProperty("item", out var item))
                    return Activity(Text(item, "type"));
                return null;
            }
            if (Text(root, "type") == "system" && Text(root, "subtype") == "init") return "Сессия запущена…";
            if (Text(root, "type") != "assistant" || !root.TryGetProperty("message", out var message)
                || !message.TryGetProperty("content", out var content) || content.ValueKind != JsonValueKind.Array) return null;
            foreach (var block in content.EnumerateArray())
            {
                var type = Text(block, "type");
                if (type == "tool_use" && Activity(Text(block, "name")) is { } phase) return phase;
                if (type is "thinking" or "text") return Activity(type);
            }
        }
        catch (JsonException) { }
        return null;
    }

    private static string? Activity(string value) => value.ToLowerInvariant() switch
    {
        "read" or "view_file" or "view_file_outline" or "list_dir" or "glob" or "grep" or "grep_search" or "find_by_name"
            => "Читаю файлы…",
        "edit" or "write" or "multiedit" or "file_change" or "write_to_file" or "replace_file_content" or
            "multi_replace_file_content" => "Обновляю файлы…",
        "bash" or "powershell" or "run_command" or "command_execution" or "command_status" => "Выполняю команду…",
        "websearch" or "web_search" or "search_web" or "webfetch" or "read_url_content" => "Ищу информацию…",
        "mcp_tool_call" or "call_mcp_tool" or "tool_call" => "Использую инструмент…",
        "reasoning" or "thinking" or "planner_response" => "Анализирую задачу…",
        "agent_message" or "agent_response" or "text" => "Готовлю ответ…",
        _ => null
    };

    private static readonly HttpClient PricingClient = new() { Timeout = TimeSpan.FromSeconds(5) };

    public static async Task<double?> EstimateRouter(JsonElement usage, CancellationToken token)
    {
        if (usage.ValueKind != JsonValueKind.Object) return null;
        var models = usage.EnumerateObject().ToArray();
        if (models.Length == 0 || models.Any(model => !model.Name.Contains('/') || model.Name.Contains('~'))) return null;
        try
        {
            using var response = await PricingClient.GetAsync("https://openrouter.ai/api/v1/models", token);
            response.EnsureSuccessStatusCode();
            using var catalog = JsonDocument.Parse(await response.Content.ReadAsStringAsync(token));
            var entries = catalog.RootElement.GetProperty("data").EnumerateArray().ToArray();
            double total = 0;
            foreach (var model in models)
            {
                var entry = entries.FirstOrDefault(entry => Text(entry, "id") == model.Name);
                if (entry.ValueKind == JsonValueKind.Undefined || !entry.TryGetProperty("pricing", out var pricing)) return null;
                foreach (var (field, category) in new[] { ("inputTokens", "prompt"), ("outputTokens", "completion"),
                    ("cacheReadInputTokens", "input_cache_read"), ("cacheCreationInputTokens", "input_cache_write") })
                {
                    if (!model.Value.TryGetProperty(field, out var value) || !value.TryGetInt64(out var count) || count < 0) return null;
                    if (count == 0) continue;
                    if (!double.TryParse(Text(pricing, category), NumberStyles.Float, CultureInfo.InvariantCulture, out var rate)
                        || !double.IsFinite(rate) || rate < 0) return null;
                    total += count * rate;
                }
            }
            return total;
        }
        catch (Exception error) when (error is HttpRequestException or OperationCanceledException or JsonException
            or InvalidOperationException or KeyNotFoundException) { return null; }
    }

    public static AgentResult Parse(Engine engine, ProcessOutput output, string key)
    {
        var answer = "";
        var notes = new List<string>();
        var usage = "";
        var success = false;
        string? session = null;
        double? cost = null;
        JsonElement modelUsage = default;
        string Redact(string value) => key.Length == 0 ? value : value.Replace(key, "[ключ скрыт]");
        var stderr = Redact(output.Stderr).Trim();
        if (stderr.Length > 0) notes.Add(stderr);
        foreach (var line in Redact(output.Stdout).Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            if (!line.TrimStart().StartsWith('{')) { notes.Add(line.Trim()); continue; }
            try
            {
                using var document = JsonDocument.Parse(line);
                var row = document.RootElement;
                var type = Text(row, "type");
                var result = row;
                if (engine.Gemini)
                {
                    if (Text(row, "conversation_id") is { Length: > 0 } eventId) session = eventId;
                    if (Text(row, "event") != "result" || !row.TryGetProperty("result", out result)) continue;
                    if (Text(result, "conversation_id") is { Length: > 0 } resultId) session = resultId;
                    answer = Text(result, "response");
                    success = Text(result, "status") == "SUCCESS";
                }
                else if (engine.Codex)
                {
                    if (type == "thread.started" && Text(row, "thread_id") is { Length: > 0 } threadId) session = threadId;
                    if (type == "item.completed" && row.TryGetProperty("item", out var item) &&
                        Text(item, "type") == "agent_message") answer = Text(item, "text");
                    if (type == "turn.completed") success = true;
                    else if (type is "turn.failed" or "error")
                    {
                        var error = row.TryGetProperty("error", out var failure) ? Text(failure, "message") : Text(row, "message");
                        if (error.Length > 0) notes.Add(error);
                        if (type == "turn.failed") success = false;
                    }
                }
                else
                {
                    if (type == "assistant" && row.TryGetProperty("message", out var chat) &&
                        chat.TryGetProperty("content", out var content) && content.ValueKind == JsonValueKind.Array)
                    {
                        var partial = string.Join("\n", content.EnumerateArray()
                            .Where(block => Text(block, "type") == "text").Select(block => Text(block, "text")));
                        if (partial.Length > 0) answer = partial;
                    }
                    if (type != "result") continue;
                    var final = Text(row, "result");
                    if (final.Length > 0) answer = final;
                    success = row.TryGetProperty("is_error", out var isError) && isError.ValueKind == JsonValueKind.False;
                    if (engine.Router && row.TryGetProperty("modelUsage", out var breakdown)) modelUsage = breakdown.Clone();
                    if (!engine.Router && row.TryGetProperty("total_cost_usd", out var amount)
                        && amount.ValueKind == JsonValueKind.Number && amount.TryGetDouble(out double reported)) cost = reported;
                    if (row.TryGetProperty("errors", out var errors) && errors.ValueKind == JsonValueKind.Array)
                        notes.AddRange(errors.EnumerateArray().Select(value => value.ToString()));
                }
                var message = Text(result, "error");
                if (message.Length > 0) notes.Add(message);
                if (!result.TryGetProperty("usage", out var counts) || counts.ValueKind != JsonValueKind.Object) continue;
                string Count(params string[] names)
                {
                    foreach (var name in names)
                        if (counts.TryGetProperty(name, out var value) && value.TryGetInt64(out long number)) return number.ToString("N0");
                    return "—";
                }
                usage = $"Вход {Count("input_tokens")}    Выход {Count("output_tokens")}    Thinking {Count("thinking_tokens")}    Кэш {Count("cache_read_tokens", "cached_input_tokens", "cache_read_input_tokens")}";
            }
            catch (JsonException) { notes.Add(line.Trim()); }
        }
        return new(answer, string.Join("\n\n", notes.Distinct()), success && output.Code == 0, usage, Guid.TryParse(session, out _) ? session : null, cost, modelUsage);
    }
}
