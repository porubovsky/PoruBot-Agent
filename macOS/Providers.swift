import Foundation

enum AppLanguage {
    static let preference = "interfaceLanguage"
    static let current = UserDefaults.standard.string(forKey: preference) == "en" ? "en" : "ru"
}

func tr(_ russian: String, _ english: String) -> String {
    AppLanguage.current == "en" ? english : russian
}

enum Engine: String, CaseIterable {
    case gemini = "Antigravity", claude = "Claude Code", codex = "Codex", router = "OpenRouter"

    var supportsSessions: Bool { self == .gemini || self == .codex }

    var symbol: String {
        switch self {
        case .gemini: return "sparkles"
        case .claude: return "asterisk"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .router: return "arrow.triangle.branch"
        }
    }

    var binary: String {
        switch self {
        case .gemini: return "agy"
        case .codex: return "codex"
        case .claude, .router: return "claude"
        }
    }
    var keyName: String {
        switch self {
        case .gemini: return "GEMINI_API_KEY"
        case .claude: return "ANTHROPIC_API_KEY"
        case .codex: return "CODEX_API_KEY"
        case .router: return "OPENROUTER_API_KEY"
        }
    }
    var presets: [String] {
        switch self {
        case .gemini: return []
        case .claude: return ["sonnet", "haiku", "opus"]
        case .codex: return ["gpt-5.4-mini", "gpt-5.4"]
        case .router: return ["~anthropic/claude-sonnet-latest", "~anthropic/claude-haiku-latest", "~anthropic/claude-opus-latest"]
        }
    }
    var efforts: [String] {
        switch self {
        case .gemini: return ["minimal", "low", "medium", "high", "xhigh", "max"]
        case .codex: return ["minimal", "low", "medium", "high", "xhigh"]
        case .claude, .router: return ["low", "medium", "high", "xhigh", "max"]
        }
    }
    var installer: (url: String, shell: String) {
        switch self {
        case .gemini: return ("https://antigravity.google/cli/install.sh", "/bin/bash")
        case .codex: return ("https://chatgpt.com/codex/install.sh", "/bin/sh")
        case .claude, .router: return ("https://claude.ai/install.sh", "/bin/bash")
        }
    }
    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    static let inherited = ProcessInfo.processInfo.environment
    static let searchPath = [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
                             inherited["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")

    func resolve(_ preferred: String) -> String? {
        let search = Self.searchPath.split(separator: ":").map { String($0) + "/" + binary }
        let bundled = self == .codex ? ["/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"] : []
        return ([preferred] + search + bundled).first {
            $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    func environment(key: String) -> [String: String] {
        var env = Self.inherited
        for name in ["GEMINI_API_KEY", "GOOGLE_API_KEY", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN",
                     "CLAUDE_CODE_OAUTH_TOKEN", "OPENAI_API_KEY", "CODEX_API_KEY", "OPENROUTER_API_KEY",
                     "CODEX_ACCESS_TOKEN", "GOOGLE_GEMINI_BASE_URL", "OPENAI_BASE_URL", "ANTHROPIC_BASE_URL",
                     "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"] {
            env.removeValue(forKey: name)
        }
        env["PATH"] = Self.searchPath
        if self == .router {
            env["ANTHROPIC_AUTH_TOKEN"] = key
            env["ANTHROPIC_BASE_URL"] = "https://openrouter.ai/api"
            env["ANTHROPIC_API_KEY"] = ""
        } else {
            env[keyName] = key
        }
        if self == .claude || self == .router {
            env["CLAUDE_CODE_SUBPROCESS_ENV_SCRUB"] = "1"
        }
        return env
    }

    static func commandPrefixes(_ text: String) -> [String]? {
        let entries = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " _./-"))
        guard entries.count <= 20, entries.allSatisfy({ entry in
            entry.count <= 240 && entry.unicodeScalars.allSatisfy(allowed.contains)
                && entry.split(separator: " ").count >= 2
        }) else { return nil }
        return entries
    }

    private static func geminiSettings(commands: [String], sandbox: Bool) -> String {
        var settings: [String: Any] = ["modelProvider": "gemini"]
        if !sandbox { settings["enableTerminalSandbox"] = false }
        if !commands.isEmpty {
            settings["permissions"] = ["allow": commands.map { "command(\($0))" }]
        }
        let data = try! JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    func arguments(model: String, effort: String, mode: String, catalog: Bool, commands: [String] = [], allFolders: Bool = false, outsideSandbox: Bool = false, sessionID: String? = nil) -> [String] {
        let selection = model.isEmpty ? [] : ["--model", model]
        let thinking = effort.isEmpty ? [] : ["--effort", effort]
        let folders = allFolders && !catalog && mode != "plan" ? ["--add-dir", "/"] : []
        switch self {
        case .gemini:
            let sandbox = catalog || mode != "accept-edits" || !outsideSandbox
            let setting = ["--settings", Self.geminiSettings(commands: catalog || mode == "plan" ? [] : commands, sandbox: sandbox)]
            return catalog ? setting + ["models"] : setting + [
                "--input-format", "stream-json", "--output-format", "stream-json", "--disable-slash-commands",
                sandbox ? "--sandbox" : "--sandbox=false", "--mode", mode
            ] + folders + selection + thinking + (sessionID.map { ["--conversation", $0] } ?? [])
        case .codex:
            let reasoning = effort.isEmpty ? [] : ["-c", "model_reasoning_effort=\"\(effort)\""]
            let sandbox = mode == "plan" ? "read-only" : "workspace-write"
            return ["exec", "--json", "--skip-git-repo-check", "--sandbox", sandbox,
                    "-c", #"model_provider="openai""#,
                    "-c", #"shell_environment_policy.exclude=["CODEX_API_KEY","OPENAI_API_KEY"]"#]
                + folders + selection + reasoning + (sessionID.map { ["resume", $0, "-"] } ?? ["-"])
        case .claude, .router:
            let commandSettings = #"{"sandbox":{"enabled":true,"failIfUnavailable":true,"autoAllowBashIfSandboxed":true,"allowUnsandboxedCommands":false}}"#
            return ["-p", "--verbose", "--output-format", "stream-json", "--no-session-persistence",
                    "--permission-mode", mode == "plan" ? "plan" : "acceptEdits",
                    "--settings", commandSettings] + folders + selection + thinking
        }
    }
}
