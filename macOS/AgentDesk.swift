import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum Profile: String, CaseIterable {
    case free = "Свободный", code = "Код", data = "Данные", quick = "Вопрос"
    var templateID: String {
        switch self {
        case .free: return "free"
        case .code: return "code"
        case .data: return "data"
        case .quick: return "question"
        }
    }
    var title: String {
        switch self {
        case .free: return tr(rawValue, "Freeform")
        case .code: return tr(rawValue, "Code")
        case .data: return tr(rawValue, "Data")
        case .quick: return tr(rawValue, "Question")
        }
    }
    var guidance: String {
        switch self {
        case .free: return ""
        case .code:
            return tr("Начни с указанных файлов или точечного поиска. Читай только нужные фрагменты, сокращай логи. Сделай минимальное изменение и одну целевую проверку. При повторяющейся ошибке остановись и опиши блокер.", "Start with the specified files or a targeted search. Read only the relevant sections and keep logs short. Make the smallest change and run one focused check. If an error recurs, stop and explain what is blocking progress.")
        case .data:
            return tr("Обрабатывай данные локально скриптом. Для ориентира возьми схему и до 5 строк. Возвращай агрегаты, выводы и ограничения. Сокращай вывод команд и не печатай весь датасет.", "Analyze data locally with a script. Start with the schema and up to five rows. Return aggregates, findings, and limitations. Keep command output short.")
        case .quick:
            return tr("Ответь кратко. Используй файлы и инструменты только если без них нельзя выполнить задачу. Если данных не хватает, назови конкретный пробел.", "Give a brief answer. Use files and tools only when needed. If there is not enough information, say what is missing.")
        }
    }
}

struct Usage: Decodable {
    var input_tokens: Int?
    var output_tokens: Int?
    var thinking_tokens: Int?
    var cache_read_tokens: Int?
    var total_tokens: Int?
    var cached_input_tokens: Int?
    var cache_read_input_tokens: Int?
}

private struct ModelTokenUsage: Decodable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadInputTokens: Int
    let cacheCreationInputTokens: Int
}

private enum RouterPricing {
    struct UsageBreakdown: Decodable {
        let modelUsage: [String: ModelTokenUsage]?
    }

    struct Catalog: Decodable {
        struct Model: Decodable {
            let id: String
            let pricing: [String: String]
        }
        let data: [Model]
    }

    static func estimate(_ usage: [String: ModelTokenUsage]) async -> Double? {
        guard !usage.isEmpty, usage.keys.allSatisfy({ $0.contains("/") && !$0.contains("~") }) else { return nil }
        let url = URL(string: "https://openrouter.ai/api/v1/models")!
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let catalog = try? JSONDecoder().decode(Catalog.self, from: data) else { return nil }
        return total(for: usage, in: catalog)
    }

    static func total(for usage: [String: ModelTokenUsage], in catalog: Catalog) -> Double? {
        var total = 0.0
        for (id, tokens) in usage {
            guard let pricing = catalog.data.first(where: { $0.id == id })?.pricing else { return nil }
            for (category, count) in [("prompt", tokens.inputTokens), ("completion", tokens.outputTokens),
                                      ("input_cache_read", tokens.cacheReadInputTokens),
                                      ("input_cache_write", tokens.cacheCreationInputTokens)] {
                guard count >= 0 else { return nil }
                if count == 0 { continue }
                guard let rate = pricing[category].flatMap(Double.init), rate.isFinite, rate >= 0 else { return nil }
                total += Double(count) * rate
            }
        }
        return total
    }
}

private struct Result: Decodable {
    var is_error: Bool?
    var result: String?
    var total_cost_usd: Double?
    var errors: [String]?
    var status: String?
    var response: String?
    var error: String?
    var conversation_id: String?
    var usage: Usage?
}

struct CodexEvent: Decodable {
    struct Item: Decodable { var type: String; var text: String? }
    struct Failure: Decodable { var message: String? }
    var type: String
    var thread_id: String?
    var item: Item?
    var usage: Usage?
    var error: Failure?
    var message: String?
}

private struct Event: Decodable {
    struct Step: Decodable {
        var tool_name: String?
        var step_type: String?
    }
    var conversation_id: String?
    var step_update: Step?
    var result: Result?
    var event: String?
}

enum AgentActivity {
    static func describe(_ raw: String) -> String? {
        switch raw.lowercased() {
        case "read", "view_file", "view_file_outline", "list_dir", "glob", "grep", "grep_search", "find_by_name":
            return tr("Читаю файлы…", "Reading files…")
        case "edit", "write", "multiedit", "file_change", "write_to_file", "replace_file_content",
             "multi_replace_file_content":
            return tr("Обновляю файлы…", "Updating files…")
        case "bash", "powershell", "run_command", "command_execution", "command_status":
            return tr("Выполняю команду…", "Running a command…")
        case "websearch", "web_search", "search_web", "webfetch", "read_url_content":
            return tr("Ищу информацию…", "Searching…")
        case "mcp_tool_call", "call_mcp_tool", "tool_call":
            return tr("Использую инструмент…", "Using a tool…")
        case "reasoning", "thinking", "planner_response", "user_input":
            return tr("Анализирую задачу…", "Analyzing the task…")
        case "agent_message", "agent_response", "text":
            return tr("Готовлю ответ…", "Preparing the answer…")
        default:
            return nil
        }
    }
}

struct ModelChoice: Hashable {
    let name: String
    let effort: String
    let id: String?
    var label: String { effort.isEmpty ? name : "\(name) · \(effort)" }

    static func catalog(_ output: String) -> [Self] {
        let expression = /(?i)^(.+?)\s+\((low|medium|high|xhigh|max|minimal)\)$/
        var entries: [Self] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let columns = line.split(separator: "\t", maxSplits: 1)
            let id = columns.count == 2 ? String(columns[0]) : nil
            let name = (columns.last ?? line).trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: #"^[-*•]\s+"#, with: "", options: .regularExpression)
            if let match = name.wholeMatch(of: expression) {
                entries.append(Self(name: String(match.1), effort: match.2.lowercased(), id: id))
            } else if name.hasPrefix("Gemini ") || name.hasPrefix("gemini-") {
                entries.append(Self(name: name, effort: "", id: id))
            }
        }
        var seen = Set<Self>()
        return entries.filter { seen.insert($0).inserted }
    }
}

struct SavedSession: Codable, Equatable {
    let id: String
    let engine: String
    let folder: String
    let title: String

    static func workspace(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL.path
    }
}

@MainActor
final class Runner: ObservableObject {
    @Published var working = false
    @Published private(set) var startedAt: Date?
    @Published var status = tr("Готово к запуску", "Ready")
    struct ActivityEntry: Identifiable {
        let id = UUID()
        let elapsed: Int
        let message: String
    }
    @Published private(set) var activity: [ActivityEntry] = []

    private func recordActivity(_ message: String, since start: Date) {
        guard activity.last?.message != message else { return }
        if activity.count >= 100 { activity.removeFirst() }
        activity.append(ActivityEntry(elapsed: max(0, Int(Date().timeIntervalSince(start))), message: message))
    }
    @Published var response = ""
    @Published var diagnostics = ""
    @Published var usage: Usage?
    @Published var reportedCost: Double?
    @Published private(set) var costFromRouter = false
    private var pricingJob: Task<Void, Never>?
    @Published var models: [ModelChoice] = []
    @Published private(set) var finishedSession: SavedSession?
    @Published var generatedImage: URL?
    private var imageJob: Task<Void, Never>?
    private var process: Process?
    private var processGroup: pid_t?
    private var stopMessage: String?

    static let executable = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/bin/agy").path

    func generateImage(using provider: ImageGeneration, prompt: String, key: String, folder: String, timeout: Int, reference: URL?) {
        guard !working else { return }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &directory), directory.boolValue else {
            status = tr("Рабочая папка недоступна.", "The working folder is unavailable.")
            return
        }
        working = true
        let start = Date()
        startedAt = start
        response = ""
        diagnostics = ""
        usage = nil
        pricingJob?.cancel()
        reportedCost = nil
        costFromRouter = false
        generatedImage = nil
        status = tr("\(provider.name) создаёт картинку…", "\(provider.name) is generating an image…")
        activity = []
        recordActivity(status, since: start)
        imageJob = Task {
            defer {
                recordActivity(status, since: start)
                working = false
                startedAt = nil
                imageJob = nil
            }
            do {
                generatedImage = try await provider.generate(prompt: prompt, key: key,
                    folder: URL(fileURLWithPath: folder), timeout: timeout, reference: reference)
                status = tr("Картинка готова", "Image ready")
            } catch {
                status = Task.isCancelled ? tr("Генерация остановлена.", "Image generation stopped.") : tr("Не удалось создать картинку.", "Could not generate the image.")
                if !Task.isCancelled { diagnostics = error.localizedDescription }
            }
        }
    }

    func install(_ engine: Engine, finished: @escaping () -> Void) {
        guard !working else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        task.arguments = ["-c",
            #"set -eu; file="$(/usr/bin/mktemp)"; trap '/bin/rm -f "$file"' EXIT; /usr/bin/curl -fsSL --proto '=https' --proto-redir '=https' "$1" -o "$file"; "$2" "$file""#,
            "porubot-install", engine.installer.url, engine.installer.shell]
        var environment = ["HOME": Engine.home, "PATH": Engine.searchPath, "CODEX_NON_INTERACTIVE": "1"]
        if let temp = Engine.inherited["TMPDIR"] { environment["TMPDIR"] = temp }
        task.environment = environment
        run(task, engine: engine, key: "", prompt: nil, timeout: 300, installerCompletion: finished)
    }

    func start(engine: Engine, path: String, folder: String, key: String, model: String,
               effort: String, mode: String, timeout: Int, prompt: String?, commands: [String] = [], allFolders: Bool = false, outsideSandbox: Bool = false, sessionID: String? = nil, account: Bool = false) {
        guard !working else { return }
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard account || !key.isEmpty else { status = tr("Вставь ключ ", "Enter the key for ") + engine.keyName + "."; return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        if prompt != nil {
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder, isDirectory: &directory), directory.boolValue else {
                status = tr("Рабочая папка недоступна.", "The working folder is unavailable."); return
            }
            task.currentDirectoryURL = URL(fileURLWithPath: folder)
        }
        task.environment = engine.environment(key: key, account: account)
        task.arguments = engine.arguments(model: model, effort: effort, mode: mode, catalog: prompt == nil, commands: commands, allFolders: allFolders, outsideSandbox: outsideSandbox, sessionID: sessionID, account: account)
        run(task, engine: engine, key: key, prompt: prompt, timeout: prompt == nil ? 25 : timeout)
    }

    private func run(_ task: Process, engine: Engine, key: String, prompt: String?, timeout: Int,
                     installerCompletion: (() -> Void)? = nil) {
        let installing = installerCompletion != nil
        let output = Pipe()
        let input = Pipe()
        task.standardOutput = output
        task.standardError = output
        task.standardInput = input
        do {
            try task.run()
        } catch {
            status = error.localizedDescription
            return
        }

        process = task
        let pid = task.processIdentifier
        processGroup = getpgid(pid) == pid ? pid : nil
        working = true
        let start = Date()
        startedAt = start
        stopMessage = nil
        response = ""
        diagnostics = ""
        usage = nil
        pricingJob?.cancel()
        reportedCost = nil
        costFromRouter = false
        generatedImage = nil
        finishedSession = nil
        status = installing ? tr("Устанавливаю \(engine.binary)…", "Installing \(engine.binary)…") : prompt == nil ? tr("Читаю каталог CLI…", "Reading the CLI catalog…") : tr("Запускаю агента…", "Starting the agent…")

        if prompt != nil {
            activity = []
            recordActivity(status, since: start)
        }
        let reader = output.fileHandleForReading
        let writer = input.fileHandleForWriting
        DispatchQueue.global(qos: .userInitiated).async {
            if let prompt, engine != .gemini {
                try? writer.write(contentsOf: Data(prompt.utf8))
            } else if let prompt,
               var payload = try? JSONSerialization.data(withJSONObject: [
                   "event": "user", "message": ["content": prompt]
               ]) {
                payload.append(10)
                try? writer.write(contentsOf: payload)
            }
            try? writer.close()
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var pending = Data()
            var catalog = ""
            var result: Result?
            var notes: [String] = []
            var partialResponse = ""
            var routerUsage: [String: ModelTokenUsage]?
            var codexResponse = ""
            var codexUsage: Usage?
            var codexError: String?
            var sessionID: String?
            var phase: String?

            func report(_ next: String?) {
                guard let next, next != phase else { return }
                phase = next
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.process === task, self.stopMessage == nil else { return }
                    self.status = next
                    if prompt != nil { self.recordActivity(next, since: start) }
                }
            }

            func accept(_ bytes: Data) {
                let raw = String(decoding: bytes, as: UTF8.self)
                let line = key.isEmpty ? raw : raw.replacingOccurrences(of: key, with: tr("[ключ скрыт]", "[key redacted]"))
                if prompt == nil {
                    if catalog.count < 100_000 { catalog += line + "\n" }
                } else if engine == .gemini, let event = try? JSONDecoder().decode(Event.self, from: Data(line.utf8)), event.event != nil {
                    if let final = event.result { result = final }
                    if let id = event.result?.conversation_id ?? event.conversation_id, !id.isEmpty { sessionID = id }
                    if event.event == "init" { report(tr("Сессия запущена…", "Session started…")) }
                    if let step = event.step_update {
                        report(AgentActivity.describe(step.tool_name ?? step.step_type ?? ""))
                    }
                } else if engine == .codex, let event = try? JSONDecoder().decode(CodexEvent.self, from: Data(line.utf8)) {
                    if event.type == "thread.started", let id = event.thread_id { sessionID = id }
                    if event.type == "turn.started" { report(tr("Анализирую задачу…", "Analyzing the task…")) }
                    if event.type == "item.started", let item = event.item { report(AgentActivity.describe(item.type)) }
                    if event.type == "item.completed", event.item?.type == "agent_message" {
                        codexResponse = event.item?.text ?? codexResponse
                    }
                    if event.type == "turn.completed" { codexUsage = event.usage }
                    if event.type == "turn.failed" { codexError = event.error?.message ?? tr("Codex завершил задачу с ошибкой.", "Codex could not complete the task.") }
                    if event.type == "error", let message = event.message, notes.count < 80 {
                        notes.append(String(message.prefix(1200)))
                    }
                } else if let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                          let type = object["type"] as? String, engine == .claude || engine == .router {
                    if type == "result" {
                        let data = Data(line.utf8)
                        result = try? JSONDecoder().decode(Result.self, from: data)
                        if engine == .router {
                            routerUsage = (try? JSONDecoder().decode(RouterPricing.UsageBreakdown.self, from: data))?.modelUsage
                        }
                    }
                    if type == "system", object["subtype"] as? String == "init" { report(tr("Сессия запущена…", "Session started…")) }
                    if type == "assistant", let message = object["message"] as? [String: Any],
                       let blocks = message["content"] as? [[String: Any]] {
                        let tool = blocks.first { $0["type"] as? String == "tool_use" }
                        let activity = tool?["name"] as? String ?? blocks.first?["type"] as? String ?? ""
                        report(AgentActivity.describe(activity))
                        let fragments = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                        if !fragments.isEmpty { partialResponse = fragments.joined(separator: "\n") }
                    }
                } else if !line.isEmpty && notes.count < 80 {
                    notes.append(String(line.prefix(1200)))
                }
            }

            while case let chunk = reader.availableData, !chunk.isEmpty {
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 10) {
                    accept(Data(pending.prefix(upTo: newline)))
                    pending.removeSubrange(...newline)
                }
            }
            if !pending.isEmpty { accept(pending) }
            task.waitUntilExit()
            let code = task.terminationStatus
            let final = result
            let openAIResponse = codexResponse
            let partial = partialResponse
            let pricedUsage = routerUsage
            let openAIUsage = codexUsage
            let openAIError = codexError
            let log = notes.joined(separator: "\n")
            let collected = catalog
            let completedID = sessionID
            DispatchQueue.main.async { [weak self] in
                guard let self, self.process === task else { return }
                self.working = false
                self.startedAt = nil
                self.process = nil
                self.processGroup = nil
                if installing {
                    self.diagnostics = collected
                    if let stopped = self.stopMessage {
                        self.status = stopped
                    } else if code == 0 {
                        self.status = tr("Установка завершена", "Installation complete")
                        installerCompletion?()
                    } else {
                        self.status = tr("Установка завершилась с ошибкой (код \(code)).", "Installation failed (code \(code)).")
                    }
                } else if prompt == nil {
                    let choices = ModelChoice.catalog(collected)
                    if code == 0 { self.models = choices }
                    self.diagnostics = collected
                    if let stopMessage = self.stopMessage {
                        self.status = stopMessage
                    } else {
                        self.status = code == 0 && !choices.isEmpty
                            ? tr("Каталог обновлён · \(choices.count) вариантов", "Catalog updated · \(choices.count) options")
                            : tr("Каталог не получен. Можно ввести модель вручную.", "Could not load the catalog. Enter the model manually.")
                    }
                } else {
                    self.response = engine == .codex ? openAIResponse : (final?.response ?? final?.result ?? partial)
                    self.usage = engine == .codex ? openAIUsage : final?.usage
                    self.reportedCost = engine == .claude ? final?.total_cost_usd : nil
                    self.costFromRouter = engine == .router
                    if engine == .router, let modelUsage = pricedUsage {
                        self.pricingJob = Task { [weak self] in
                            let estimate = await RouterPricing.estimate(modelUsage)
                            if !Task.isCancelled { self?.reportedCost = estimate }
                        }
                    }
                    self.diagnostics = [openAIError, final?.error, final?.errors?.joined(separator: "\n"), log].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
                    if let stopMessage = self.stopMessage {
                        self.status = stopMessage
                    } else {
                        let valid = engine == .codex ? openAIUsage != nil && openAIError == nil
                            : engine == .gemini ? final?.status == "SUCCESS" : final?.is_error == false
                        let diagnostic = self.diagnostics.lowercased()
                        if engine == .gemini && diagnostic.contains("no output produced")
                            && diagnostic.contains("unsandboxed") {
                            self.status = tr("Antigravity запросил команду вне песочницы", "Antigravity requested a command outside the sandbox")
                        } else if engine == .gemini && diagnostic.contains("no output produced")
                            && diagnostic.contains("command") && diagnostic.contains("permission") {
                            self.status = tr("Antigravity отклонил команду", "Antigravity denied the command")
                        } else {
                            if code == 0 && valid, let id = completedID, UUID(uuidString: id) != nil,
                               let directory = task.currentDirectoryURL, let prompt {
                                let firstLine = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? tr("Разговор", "Conversation")
                                let safeTitle = key.isEmpty ? firstLine : firstLine.replacingOccurrences(of: key, with: tr("[ключ скрыт]", "[key redacted]"))
                                self.finishedSession = SavedSession(id: id, engine: engine.rawValue,
                                    folder: SavedSession.workspace(directory.path), title: String(safeTitle.prefix(84)))
                            }
                            self.status = code == 0 && valid ? tr("Завершено", "Done") : tr("CLI завершился без успешного результата (код \(code)).", "CLI exited without a successful result (code \(code)).")
                        }
                    }
                    self.recordActivity(self.status, since: start)
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(timeout)) { [weak self, weak task] in
            guard let self, let task, self.process === task, self.stopMessage == nil else { return }
            self.stop(reason: tr("Запуск остановлен по лимиту времени.", "Stopped at the time limit."))
        }
    }

    func stop(reason: String = tr("Запуск остановлен.", "Run stopped.")) {
        if let imageJob { imageJob.cancel(); return }
        guard let process, stopMessage == nil else { return }
        stopMessage = reason
        status = tr("Останавливаю CLI…", "Stopping CLI…")
        let pid = process.processIdentifier
        let group = processGroup
        if let group { kill(-group, SIGTERM) }
        else if process.isRunning { process.terminate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak process] in
            if let group { kill(-group, SIGKILL) }
            else if process?.isRunning == true { kill(pid, SIGKILL) }
        }
    }
}

struct Panel: View {
    @StateObject private var runner = Runner()
    @AppStorage(AppLanguage.preference) private var interfaceLanguage = AppLanguage.current
    @State private var languageChanged = false
    @State private var showActivity = false
    @State private var repeatLast: (() -> Void)?
    @AppStorage("cliPath") private var cliPath = Runner.executable
    @AppStorage("folder") private var folder = ""
    @State private var engine = Engine.gemini
    @State private var keys: [Engine: String] = [:]
    @AppStorage("rememberAPIKeys") private var rememberAPIKeys = false
    @State private var changedKeys: Set<Engine> = []
    @State private var imageMode = false
    @AppStorage("useCLIAccount") private var useCLIAccount = false
    @State private var showAccountHelp = false
    private var accountMode: Bool { useCLIAccount && !imageMode && engine.supportsAccount }
    private var accountCommand: String {
        let preferred = (path.wrappedValue as NSString).expandingTildeInPath
        guard let executable = engine.resolve(preferred) else { return engine.accountCommand }
        let quotedPath = "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return quotedPath + String(engine.accountCommand.dropFirst(engine.binary.count))
    }
    @State private var imageReference: URL?
    @AppStorage("recentAgentSessions") private var recentAgentSessions = Data()
    @State private var selectedSessionID = ""
    @State private var showSessionID = false
    @State private var typedSessionID = ""
    @State private var keySaveDebounce: Task<Void, Never>?
    private var savedSessions: [SavedSession] {
        (try? JSONDecoder().decode([SavedSession].self, from: recentAgentSessions)) ?? []
    }
    private var matchingSessions: [SavedSession] {
        guard !folder.isEmpty else { return [] }
        let workspace = SavedSession.workspace(folder)
        return savedSessions.filter { $0.engine == engine.rawValue && $0.folder == workspace }
    }

    private func rememberSession(_ session: SavedSession) {
        var all = savedSessions
        let existing = all.first { $0.id == session.id && $0.engine == session.engine && $0.folder == session.folder }
        all.removeAll { $0.id == session.id && $0.engine == session.engine && $0.folder == session.folder }
        all.insert(existing ?? session, at: 0)
        if let stored = try? JSONEncoder().encode(Array(all.prefix(200))) { recentAgentSessions = stored }
        if engine.rawValue == session.engine && SavedSession.workspace(folder) == session.folder {
            selectedSessionID = session.id
        }
    }

    private func queueKeySave() {
        keySaveDebounce?.cancel()
        guard rememberAPIKeys, changedKeys.contains(engine) else { return }
        let provider = engine
        keySaveDebounce = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 650_000_000)
            if !Task.isCancelled, engine == provider { saveCurrentKey() }
        }
    }
    private var imageProvider: ImageGeneration? {
        switch engine {
        case .gemini: return .google
        case .codex: return .openAI
        case .claude, .router: return nil
        }
    }
    @State private var paths: [Engine: String] = [:]
    @AppStorage("keychainEntries") private var keychainEntries = Data()
    @State private var showKeychain = false
    @State private var keychainService = ""
    @State private var keychainAccount = ""
    @State private var keychainMessage: [Engine: String] = [:]
    @State private var keychainLoading: Set<Engine> = []
    @State private var keychainSaving: Set<Engine> = []
    private var linkedEntries: [String: KeychainEntry] {
        (try? JSONDecoder().decode([String: KeychainEntry].self, from: keychainEntries)) ?? [:]
    }
    private var key: Binding<String> {
        let provider = engine
        return Binding(
            get: { keys[provider] ?? Engine.inherited[provider.keyName] ?? "" },
            set: { value in
                guard value != (keys[provider] ?? Engine.inherited[provider.keyName] ?? "") else { return }
                keys[provider] = value
                changedKeys.insert(provider)
                keychainMessage.removeValue(forKey: provider)
            }
        )
    }
    private var path: Binding<String> {
        Binding(get: { engine == .gemini ? cliPath : (paths[engine] ?? engine.resolve("") ?? "") },
                set: { if engine == .gemini { cliPath = $0 } else { paths[engine] = $0 } })
    }
    @State private var model = ""
    @State private var effort = ""
    @State private var profile = Profile.free
    @State private var mode = "accept-edits"
    @State private var timeout = 180
    @State private var request = ""
    @State private var requestWidth: CGFloat = 460
    @State private var scope = ""
    @State private var preview = false
    @State private var promptDraft = ""
    @State private var editingTemplate = false
    @AppStorage("taskPromptTemplates") private var savedPromptTemplates = Data()
    @State private var editedPrompt: String?
    @State private var showDiagnostics = false
    @State private var commandText = ""
    @State private var showCommands = false
    @AppStorage("antigravityAllCommands") private var allowAllCommands = false
    @AppStorage("agentAllFolders") private var allFoldersEnabled = false
    @State private var confirmAllFolders = false
    @AppStorage("antigravityOutsideSandbox") private var outsideSandboxEnabled = false
    @State private var confirmOutsideSandbox = false
    private var activeCommands: [String]? { Engine.commandPrefixes(commandText) }

    private func openKeychainSettings() {
        let entry = linkedEntries[engine.keyName]
        keychainService = entry?.service ?? engine.keyName
        keychainAccount = entry?.account ?? ""
        showKeychain = true
    }

    private func autoloadSetting(_ provider: Engine) -> String {
        "skipKeychainAutoload." + provider.keyName
    }

    private func linkKeychain(_ entry: KeychainEntry?) {
        UserDefaults.standard.set(entry == nil, forKey: autoloadSetting(engine))
        var entries = linkedEntries
        entries[engine.keyName] = entry
        guard let encoded = try? JSONEncoder().encode(entries) else { return }
        keychainEntries = encoded
        keys.removeValue(forKey: engine)
        changedKeys.remove(engine)
        keychainMessage.removeValue(forKey: engine)
        showKeychain = false
        if entry != nil { loadKeychain(for: engine) }
    }

    private func openPasswords() {
        let provider = engine
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Passwords")
            ?? [URL(fileURLWithPath: "/System/Applications/Passwords.app")].first(where: {
                FileManager.default.fileExists(atPath: $0.path)
            }) else {
            keychainMessage[provider] = tr("Приложение «Пароли» недоступно на этой версии macOS.", "The Passwords app is unavailable on this version of macOS.")
            return
        }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard error != nil else { return }
            DispatchQueue.main.async { keychainMessage[provider] = tr("Не удалось открыть «Пароли».", "Could not open Passwords.") }
        }
    }

    private func saveCurrentKey() {
        let provider = engine
        let secret = key.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty, keychainSaving.insert(provider).inserted else { return }
        let entry = KeychainEntry.porubot(provider.keyName)
        keychainMessage[provider] = tr("Сохраняю ключ…", "Saving key…")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = entry.save(secret).flatMap {
                entry.read().flatMap { $0 == secret ? .success(()) : .failure(.empty) }
            }
            DispatchQueue.main.async {
                keychainSaving.remove(provider)
                switch result {
                case .success:
                    UserDefaults.standard.removeObject(forKey: autoloadSetting(provider))
                    var entries = linkedEntries
                    entries[provider.keyName] = entry
                    if let encoded = try? JSONEncoder().encode(entries) { keychainEntries = encoded }
                    if keys[provider] == nil { keys[provider] = secret }
                    if keys[provider] == secret { changedKeys.remove(provider) }
                    keychainMessage[provider] = tr("Ключ сохранён в Связке ключей", "Key saved in Keychain")
                case let .failure(error):
                    keychainMessage[provider] = error.message
                }
            }
        }
    }

    private func loadKeychain(for provider: Engine) {
        let linked = linkedEntries[provider.keyName]
        let entry = linked ?? KeychainEntry.porubot(provider.keyName)
        guard !UserDefaults.standard.bool(forKey: autoloadSetting(provider)),
              keys[provider] == nil, keychainLoading.insert(provider).inserted else { return }
        keychainMessage[provider] = tr("Читаю Связку ключей…", "Reading Keychain…")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = entry.read()
            DispatchQueue.main.async {
                keychainLoading.remove(provider)
                guard !UserDefaults.standard.bool(forKey: autoloadSetting(provider)),
                      linkedEntries[provider.keyName] == linked, keys[provider] == nil else {
                    keychainMessage.removeValue(forKey: provider)
                    if linkedEntries[provider.keyName] != linked { loadKeychain(for: provider) }
                    return
                }
                switch result {
                case let .success(secret):
                    keys[provider] = secret
                    keychainMessage[provider] = tr("Ключ из Связки ключей", "Key loaded from Keychain")
                case let .failure(error) where linked == nil && error.isMissing:
                    keychainMessage.removeValue(forKey: provider)
                case let .failure(error):
                    keychainMessage[provider] = error.message
                }
            }
        }
    }

    private var requestHeight: CGFloat {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        let text = NSAttributedString(string: request + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 14), .paragraphStyle: style
        ])
        let size = NSSize(width: max(60, requestWidth - 26), height: 10_000)
        let height = text.boundingRect(with: size, options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        return min(210, max(62, ceil(height) + 18))
    }

    private var text: String { editedPrompt ?? generatedPrompt }

    private var defaultTemplate: String {
        tr("Работай точечно. ", "Keep the work focused. ") + profile.guidance
            + tr(" Не расширяй задачу. В конце кратко укажи результат и проверку.", " Stay within scope. Briefly summarize the result and verification.")
    }

    private var promptTemplates: [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: savedPromptTemplates)) ?? [:]
    }

    private var activeTemplate: String { promptTemplates[profile.templateID] ?? defaultTemplate }

    private var generatedPrompt: String {
        guard !imageMode, profile != .free else { return request }
        let focus = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        let constraints = focus.isEmpty ? "" : tr("Границы задачи и условие готовности:\n", "Scope and completion criteria:\n") + focus
        return [request, constraints, activeTemplate].filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.joined(separator: "\n\n")
    }

    private var hasTask: Bool {
        let input = editedPrompt ?? request
        return !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func saveTemplate() {
        var templates = promptTemplates
        templates[profile.templateID] = promptDraft == defaultTemplate ? nil : promptDraft
        if let encoded = try? JSONEncoder().encode(templates) { savedPromptTemplates = encoded }
        editedPrompt = nil
    }

    private func launch(_ prompt: String?) {
        if prompt != nil, !accountMode, rememberAPIKeys, changedKeys.contains(engine) { saveCurrentKey() }
        if imageMode, prompt != nil {
            guard let provider = imageProvider else { return }
            let imagePrompt = prompt ?? ""
            let imageFolder = folder
            let reference = imageReference
            let limit = timeout
            let chosen = engine
            let run = {
                runner.generateImage(using: provider, prompt: imagePrompt,
                    key: keys[chosen] ?? Engine.inherited[chosen.keyName] ?? "", folder: imageFolder, timeout: limit, reference: reference)
            }
            repeatLast = run
            run()
            return
        }
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let catalogID = runner.models.first {
            $0.name.caseInsensitiveCompare(name) == .orderedSame && $0.effort == effort
        }?.id
        let isExactGeminiID = name.wholeMatch(of: /gemini-[a-z0-9.\-]+-(minimal|low|medium|high|xhigh|max)/) != nil
        let exactID = catalogID ?? (isExactGeminiID ? name : nil)
        let chosen = engine
        let resumedID = !selectedSessionID.isEmpty && chosen.supportsSessions && prompt != nil ? selectedSessionID : nil
        let useCommands = chosen == .gemini && prompt != nil && mode != "plan"
        let allowAll = useCommands && allowAllCommands
        guard !useCommands || allowAll || activeCommands != nil else {
            runner.status = tr("Проверь список команд Antigravity.", "Review the Antigravity command list.")
            showCommands = true
            return
        }
        let commands = allowAll ? ["*"] : (useCommands ? (activeCommands ?? []) : [])
        let allFolders = prompt != nil && mode != "plan" && allFoldersEnabled
        let outsideSandbox = useCommands && mode == "accept-edits" && outsideSandboxEnabled
        let preferred = (path.wrappedValue as NSString).expandingTildeInPath
        let workingFolder = folder
        let selectedMode = mode
        let account = accountMode
        let limit = timeout
        let selectedEffort = chosen == .gemini && (exactID != nil || name.isEmpty) ? "" : effort
        let selectedModel = chosen == .gemini ? exactID ?? name : name
        let run: (String) -> Void = { executable in
            let runTask = {
                guard (!allowAll || allowAllCommands), (!allFolders || allFoldersEnabled),
                      (!outsideSandbox || outsideSandboxEnabled),
                      (!useCommands || allowAll || activeCommands == commands) else {
                    runner.status = tr("Доступ агента изменился. Запусти задачу с текущими настройками.", "Agent access has changed. Run the task with the current settings.")
                    return
                }
                runner.start(engine: chosen, path: executable, folder: prompt == nil ? "" : workingFolder,
                             key: account ? "" : (keys[chosen] ?? Engine.inherited[chosen.keyName] ?? ""),
                             model: selectedModel, effort: selectedEffort, mode: selectedMode, timeout: limit,
                             prompt: prompt, commands: commands, allFolders: allFolders,
                             outsideSandbox: outsideSandbox, sessionID: resumedID, account: account)
            }
            if prompt != nil { repeatLast = runTask }
            runTask()
        }
        if let executable = chosen.resolve(preferred) {
            run(executable)
        } else {
            runner.install(chosen) {
                guard let executable = chosen.resolve(preferred) else {
                    runner.status = tr("CLI не найден после установки. Укажи путь вручную.", "CLI was not found after installation. Enter its path manually.")
                    return
                }
                path.wrappedValue = executable
                run(executable)
            }
        }
    }

    private var accent: Color { Color(nsColor: .systemIndigo) }
    private var surface: Color { Color(nsColor: .controlBackgroundColor) }

    private func section(_ title: String, icon: String) -> some View {
        Label {
            Text(title).font(.custom("AvenirNext-DemiBold", size: 14, relativeTo: .headline))
        } icon: {
            Image(systemName: icon).foregroundStyle(accent)
        }
    }

    private var accessControls: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if mode == "plan" {
                    Label(tr("В режиме «План» расширенный доступ не применяется.", "Extended access is disabled in Plan mode."), systemImage: "lock")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    if engine == .gemini {
                        Toggle(isOn: $allowAllCommands) {
                            Label(tr("Все команды", "All commands"), systemImage: "terminal")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .help(tr("Разрешает любую команду, включая удаление или перезапись, в пределах песочницы.", "Allow any command within the sandbox, including deletion and overwriting."))
                        Button { showCommands = true } label: {
                            Label(tr("Выбрать команды…", "Choose commands…"), systemImage: "list.bullet.rectangle")
                        }
                        .disabled(allowAllCommands)
                        if mode == "accept-edits" {
                            Toggle(isOn: Binding(
                                get: { outsideSandboxEnabled },
                                set: { if $0 { confirmOutsideSandbox = true } else { outsideSandboxEnabled = false } }
                            )) {
                                Label(tr("Команды без песочницы", "Commands outside sandbox"), systemImage: "lock.open")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .alert(tr("Запустить Antigravity без песочницы команд?", "Run Antigravity commands outside the sandbox?"), isPresented: $confirmOutsideSandbox) {
                                Button(tr("Отмена", "Cancel"), role: .cancel) {}
                                Button(tr("Включить", "Enable")) { outsideSandboxEnabled = true }
                            } message: {
                                Text(tr("Разрешённые команды смогут работать с файлами и сетью вне песочницы. Настройка сохранится для следующих задач.", "Allowed commands will be able to access files and the network outside the sandbox. This setting applies to future tasks."))
                            }
                        }
                    } else {
                        Label(tr("Команды: правила движка", "Commands: engine rules"), systemImage: "terminal")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle(isOn: Binding(
                        get: { allFoldersEnabled },
                        set: { if $0 { confirmAllFolders = true } else { allFoldersEnabled = false } }
                    )) {
                        Label(tr("Все доступные папки", "All accessible folders"), systemImage: "folder.badge.plus")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text(tr("Настройки действуют, пока включены.", "Settings apply while enabled."))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.toggleStyle(.switch).padding(5)
        } label: {
            section(tr("Доступ агента", "Agent access"), icon: "lock.shield")
        }
        .confirmationDialog(tr("Открыть агенту доступ ко всем папкам?", "Allow the agent to access all folders?"), isPresented: $confirmAllFolders, titleVisibility: .visible) {
            Button(tr("Включить", "Enable")) { allFoldersEnabled = true }
            Button(tr("Отмена", "Cancel"), role: .cancel) {}
        } message: {
            Text(tr("Агент сможет читать и править файлы за пределами выбранной папки. Доступ останется включённым, пока ты его не отключишь.", "The agent can read and edit files outside the working folder. Access stays enabled until you turn it off."))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().interpolation(.high).frame(width: 48, height: 48)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("PoruBot Agent").font(.custom("AvenirNext-DemiBold", size: 26, relativeTo: .title))
                    Label(imageMode ? (imageProvider?.name ?? tr("Картинка", "Image")) : engine.rawValue, systemImage: engine.symbol)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Group {
                    if let start = runner.startedAt {
                        TimelineView(.periodic(from: start, by: 1)) { context in
                            let seconds = max(0, Int(context.date.timeIntervalSince(start)))
                            Label(runner.status + "  ·  " + String(format: "%d:%02d", seconds / 60, seconds % 60),
                                  systemImage: "hourglass")
                                .monospacedDigit()
                        }
                    } else {
                        Label(runner.status, systemImage: "terminal")
                    }
                }
                    .font(.system(.caption, design: .rounded).weight(.medium))
                    .foregroundStyle(.secondary).lineLimit(2)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.thinMaterial, in: Capsule())
                Picker(tr("Язык", "Language"), selection: $interfaceLanguage) {
                    Text("Русский").tag("ru")
                    Text("English").tag("en")
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel(tr("Язык", "Language"))
                .onChange(of: interfaceLanguage) { languageChanged = $0 != AppLanguage.current }
                .alert(tr("Язык интерфейса", "Interface language"), isPresented: $languageChanged) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(tr("Новый язык включится при следующем запуске PoruBot.", "The new language will take effect the next time you open PoruBot."))
                }
            }
            .padding(12)
            .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
            .padding(.top, 12)
            HStack(alignment: .top, spacing: 16) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 9) {
                            Picker(imageMode ? tr("Генератор", "Generator") : tr("Движок", "Engine"), selection: $engine) {
                                if imageMode {
                                    Text("Google").tag(Engine.gemini)
                                    Text("OpenAI").tag(Engine.codex)
                                } else {
                                    ForEach(Engine.allCases, id: \.self) { Text($0.rawValue) }
                                }
                            }
                            if !imageMode && engine.supportsAccount {
                                Picker(tr("Вход", "Sign-in"), selection: $useCLIAccount) {
                                    Text("API key").tag(false)
                                    Text(tr("Аккаунт CLI", "CLI account")).tag(true)
                                }
                                .disabled(runner.working)
                            }
                            if accountMode {
                                Button(tr("Как войти…", "How to sign in…")) { showAccountHelp = true }
                            } else {
                                SecureField(engine.keyName, text: key)
                                    .onSubmit { if rememberAPIKeys { saveCurrentKey() } }
                                Toggle(tr("Запоминать ключ", "Remember key"), isOn: $rememberAPIKeys)
                                    .font(.caption)
                                Menu {
                                    Button(tr("Открыть «Пароли»", "Open Passwords")) { openPasswords() }
                                    Button(tr("Привязать существующую запись…", "Link an existing entry…")) { openKeychainSettings() }
                                } label: { Label(tr("Пароли и ключи", "Passwords and keys"), systemImage: "key") }
                                HStack {
                                    if key.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        Button(tr("Загрузить ключ", "Load key")) {
                                            UserDefaults.standard.removeObject(forKey: autoloadSetting(engine))
                                            keys.removeValue(forKey: engine)
                                            changedKeys.remove(engine)
                                            loadKeychain(for: engine)
                                        }.disabled(keychainLoading.contains(engine))
                                    } else {
                                        Button(tr("Сохранить ключ", "Save key")) { saveCurrentKey() }
                                            .disabled(keychainSaving.contains(engine))
                                    }
                                }
                                if let message = keychainMessage[engine] {
                                    Text(message).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            TextField(tr("Путь к ", "Path to ") + engine.binary, text: path)
                            if engine.resolve(path.wrappedValue) == nil {
                                Text(tr("CLI установится при запуске.", "The CLI will install when you run a task.")).font(.caption).foregroundStyle(.secondary)
                            }
                            HStack {
                                Button { chooseFolder() } label: { Label(tr("Папка…", "Folder…"), systemImage: "folder") }
                                Text(folder.isEmpty ? tr("Папка не выбрана", "No folder selected") : folder)
                                    .font(.caption).lineLimit(1).truncationMode(.middle).help(folder)
                            }
                        }.padding(5)
                    } label: { section(tr("Подключение", "Connection"), icon: "key") }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 9) {
                            HStack {
                                if engine == .gemini {
                                    Button(tr("Загрузить модели", "Load models")) { launch(nil) }
                                        .disabled(!accountMode && key.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                }
                                if engine != .gemini {
                                    Menu(tr("Модели", "Models")) {
                                        ForEach(engine.presets, id: \.self) { item in
                                            Button(item) { model = item }
                                        }
                                    }
                                } else if !runner.models.isEmpty {
                                    Menu(tr("Выбрать", "Choose")) {
                                        ForEach(runner.models, id: \.self) { option in
                                            Button(option.label) { model = option.name; effort = option.effort }
                                        }
                                    }
                                }
                            }
                            TextField(tr("Имя или ID модели", "Model name or ID"), text: $model)
                            Picker("Thinking level", selection: $effort) {
                                Text(tr("По умолчанию", "Default")).tag("")
                                ForEach(engine.efforts, id: \.self) {
                                    Text($0).tag($0)
                                }
                            }
                            Picker(tr("Режим CLI", "CLI mode"), selection: $mode) {
                                if engine == .gemini { Text(tr("Авто в песочнице", "Automatic in sandbox")).tag("auto") }
                                Text(tr("Правки файлов", "Edit files")).tag("accept-edits")
                                Text(tr("План", "Plan")).tag("plan")
                            }
                            Stepper(tr("Время: \(timeout) с", "Time: \(timeout)s"), value: $timeout, in: 30...900, step: 30)
                        }.padding(5)
                    } label: { section(tr("Запуск", "Run settings"), icon: "slider.horizontal.3") }
                    .disabled(imageMode)
                    .opacity(imageMode ? 0.65 : 1)
                    if !imageMode { accessControls }
                    }
                    .padding(.trailing, 8)
                    .padding(.bottom, 8)
                    .disabled(runner.working)
                }.frame(width: 320)

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Picker(tr("Режим", "Mode"), selection: $imageMode) {
                            Text(tr("Агент", "Agent")).tag(false)
                            Text(tr("Картинка", "Image")).tag(true)
                        }.pickerStyle(.segmented).labelsHidden()
                        if !imageMode {
                            Picker(tr("Режим работы", "Task mode"), selection: $profile) {
                                ForEach(Profile.allCases, id: \.self) { Text($0.title).tag($0) }
                            }.pickerStyle(.menu)
                            if profile != .free {
                                Button(tr("Шаблон…", "Template…")) {
                                    editingTemplate = true
                                    promptDraft = activeTemplate
                                    preview = true
                                }
                                .disabled(runner.working)
                            }
                        }
                    }
                    if !imageMode && engine.supportsSessions {
                        Menu {
                            Button(tr("Новый разговор", "New conversation")) { selectedSessionID = "" }
                            ForEach(matchingSessions, id: \.id) { session in
                                Button(session.title) { selectedSessionID = session.id }
                            }
                            Button(tr("Открыть по ID…", "Open by ID…")) { typedSessionID = ""; showSessionID = true }
                        } label: {
                            Label(selectedSessionID.isEmpty ? tr("Новый разговор", "New conversation") :
                                matchingSessions.first { $0.id == selectedSessionID }?.title ?? tr("Разговор по ID", "Conversation by ID"),
                                systemImage: "bubble.left.and.bubble.right")
                                .lineLimit(1)
                        }.disabled(runner.working || folder.isEmpty)
                    }
                    section(imageMode ? tr("Описание картинки", "Image prompt") : tr("Задача", "Task"), icon: imageMode ? "photo" : "square.and.pencil")
                    TextEditor(text: $request)
                        .font(.system(size: 14)).lineSpacing(4)
                        .scrollContentBackground(.hidden)
                        .padding(8).frame(height: requestHeight)
                        .background {
                            GeometryReader { geometry in
                                Color.clear
                                    .onAppear { requestWidth = geometry.size.width }
                                    .onChange(of: geometry.size.width) { requestWidth = $0 }
                            }
                        }
                        .background(surface, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.secondary.opacity(0.20)))
                        .accessibilityLabel(tr("Задача", "Task"))
                    if !imageMode && profile != .free {
                        TextField(tr("Файлы, границы и критерий готовности", "Files, scope, and completion criteria"), text: $scope)
                    } else if imageMode && imageProvider != nil {
                        HStack {
                            Button { chooseImageReference() } label: {
                                Label(imageReference == nil ? tr("Добавить образец…", "Add reference…") : tr("Заменить образец…", "Replace reference…"), systemImage: "photo.badge.plus")
                            }
                            if let imageReference {
                                Text(imageReference.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                    .help(imageReference.lastPathComponent)
                                Button(tr("Убрать", "Remove")) { self.imageReference = nil }
                            } else {
                                Text(tr("PNG, JPEG или WebP · до 10 МБ", "PNG, JPEG or WebP · up to 10 MB")).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .disabled(runner.working)
                    }
                    HStack {
                        Button { editingTemplate = false; promptDraft = text; preview = true } label: {
                            Label(tr("Промпт", "Prompt"), systemImage: "pencil")
                        }.disabled(runner.working)
                        Text(editedPrompt == nil
                             ? tr("\(text.utf8.count) байт промпта", "\(text.utf8.count) prompt bytes")
                             : tr("Промпт изменён", "Prompt edited"))
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if runner.working {
                            Button { runner.stop() } label: { Label(tr("Остановить", "Stop"), systemImage: "stop.fill") }
                        } else {
                            Button { repeatLast?() } label: { Label(tr("Повторить", "Repeat"), systemImage: "arrow.clockwise") }
                                .disabled(repeatLast == nil)
                                .help(tr("Повторно отправить последний запрос с прежними настройками. Действия агента могут повториться.", "Send the last request again with the same settings. Agent actions may be repeated."))
                            Button { launch(text) } label: { Label(tr("Запустить", "Run"), systemImage: "play.fill") }
                                .buttonStyle(.borderedProminent)
                                .disabled((imageMode && imageProvider == nil) || (!accountMode && key.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || !hasTask || folder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    Divider()
                    DisclosureGroup(tr("Ход работы", "Activity"), isExpanded: $showActivity) {
                        if runner.activity.isEmpty {
                            Text(tr("Здесь появятся этапы обработки запроса.", "Progress will appear here when you run a task."))
                                .font(.caption).foregroundStyle(.secondary).padding(.vertical, 6)
                        } else {
                            ScrollViewReader { proxy in
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 6) {
                                        ForEach(runner.activity) { entry in
                                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                                Text(String(format: "%d:%02d", entry.elapsed / 60, entry.elapsed % 60))
                                                    .monospacedDigit().foregroundStyle(.secondary)
                                                Text(entry.message)
                                            }.id(entry.id)
                                        }
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                                }.frame(height: 112)
                                    .onAppear {
                                        if let id = runner.activity.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                                    }
                                    .onChange(of: runner.activity.last?.id) { id in
                                        if let id { proxy.scrollTo(id, anchor: .bottom) }
                                    }
                            }.font(.caption)
                        }
                    }
                    section(tr("Результат", "Result"), icon: "text.alignleft")
                    if let usage = runner.usage {
                        HStack(spacing: 10) {
                            metric(tr("Вход", "Input"), usage.input_tokens)
                            metric(tr("Выход", "Output"), usage.output_tokens)
                            metric("Thinking", usage.thinking_tokens)
                            metric(tr("Кэш", "Cache"), usage.cache_read_tokens ?? usage.cached_input_tokens ?? usage.cache_read_input_tokens)
                            metric(tr("Всего", "Total"), usage.total_tokens)
                        }
                    }
                    if let cost = runner.reportedCost {
                        Text((runner.costFromRouter ? tr("По тарифам OpenRouter: ≈", "OpenRouter estimate: ≈") : tr("Оценка CLI: ≈", "CLI estimate: ≈"))
                             + cost.formatted(.currency(code: "USD").precision(.fractionLength(2...6))))
                            .font(.caption)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            if let url = runner.generatedImage {
                                if let image = NSImage(contentsOf: url) {
                                    Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 420)
                                }
                                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                                    Label(url.lastPathComponent, systemImage: "folder")
                                }
                            } else if runner.response.isEmpty {
                                Text(tr("Здесь появится ответ агента.", "The agent's response will appear here.")).foregroundStyle(.secondary)
                            } else {
                                AgentResponseView(response: runner.response)
                            }
                            if !runner.diagnostics.isEmpty {
                                DisclosureGroup(tr("Диагностика CLI", "CLI diagnostics"), isExpanded: $showDiagnostics) {
                                    Text(runner.diagnostics).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }.frame(minHeight: 220, maxHeight: .infinity)
                        .background(surface, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.secondary.opacity(0.20)))
                }
            }
        }.padding(18).frame(minWidth: 860, minHeight: 690)
            .tint(accent)
            .task(id: engine) { @MainActor in
                await Task.yield()
                guard !Task.isCancelled, !accountMode else { return }
                loadKeychain(for: engine)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                if !accountMode && keychainMessage[engine] == nil { loadKeychain(for: engine) }
            }
            .onChange(of: key.wrappedValue) { _ in queueKeySave() }
            .onChange(of: rememberAPIKeys) { if $0 { saveCurrentKey() } else { keySaveDebounce?.cancel() } }
            .onChange(of: folder) { _ in selectedSessionID = "" }
            .onChange(of: runner.finishedSession) { if let session = $0 { rememberSession(session) } }
            .sheet(isPresented: $showSessionID) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(tr("Продолжить разговор по ID", "Resume conversation by ID")).font(.headline)
                    TextField(tr("UUID сессии из CLI", "Session UUID from CLI"), text: $typedSessionID)
                    HStack {
                        Button(tr("Отмена", "Cancel")) { showSessionID = false }.keyboardShortcut(.cancelAction)
                        Spacer()
                        Button(tr("Выбрать", "Choose")) {
                            selectedSessionID = typedSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
                            showSessionID = false
                        }.keyboardShortcut(.defaultAction)
                        .disabled(UUID(uuidString: typedSessionID.trimmingCharacters(in: .whitespacesAndNewlines)) == nil)
                    }
                }.padding(20).frame(width: 440)
            }
            .onChange(of: useCLIAccount) { _ in
                repeatLast = nil
                selectedSessionID = ""
                runner.models = []
                model = ""
                effort = ""
                if !accountMode { loadKeychain(for: engine) }
            }
            .alert(tr("Вход в CLI", "Sign in to the CLI"), isPresented: $showAccountHelp) {
                Button(tr("Скопировать команду", "Copy command")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(accountCommand, forType: .string)
                }
                Button(tr("Закрыть", "Close"), role: .cancel) {}
            } message: {
                Text(tr("Выполни в Терминале: ", "Run in Terminal: ") + accountCommand
                     + tr("\nЗаверши вход у провайдера и вернись в PoruBot.", "\nComplete sign-in with the provider, then return to PoruBot.")
                     + (engine == .gemini ? tr("\nЕсли в настройках agy задан modelProvider: gemini, убери его для входа в Терминале.",
                                                "\nIf modelProvider: gemini is set in agy settings, remove it for terminal sign-in.") : ""))
            }
            .onChange(of: imageMode) { isImage in
                if isImage && imageProvider == nil { engine = .gemini }
                if isImage { loadKeychain(for: engine) }
            }
            .onChange(of: engine) { value in
                selectedSessionID = ""
                model = accountMode ? "" : (value.presets.first ?? "")
                effort = value == .codex ? "low" : ""
                mode = "accept-edits"
                runner.models = []
            }
            .onChange(of: runner.status) { status in
                showDiagnostics = status.hasPrefix(tr("Не удалось создать картинку", "Could not generate the image")) || status.hasPrefix("Antigravity ") || status.hasPrefix(tr("CLI завершился", "CLI exited")) || status.hasPrefix(tr("Каталог не получен", "Could not load the catalog")) || status.hasPrefix(tr("Установка завершилась", "Installation failed"))
            }
            .onChange(of: runner.models) { models in
                guard model.isEmpty, let first = models.first(where: {
                    $0.name.localizedCaseInsensitiveContains("flash") && $0.effort == "low"
                }) else { return }
                model = first.name
                effort = first.effort
            }
            .sheet(isPresented: $showKeychain) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(tr("Связка ключей · ", "Keychain · ") + engine.rawValue).font(.headline)
                    Text(tr("Укажи имя службы и учётную запись существующей записи типа «Пароль приложения». При выборе движка PoruBot будет читать ключ из этой записи.", "Enter the service and account of an existing application password. PoruBot will load the key from this entry when you select the engine."))
                    TextField(tr("Имя службы", "Service name"), text: $keychainService)
                    TextField(tr("Учётная запись", "Account"), text: $keychainAccount)
                    HStack {
                        if linkedEntries[engine.keyName] != nil {
                            Button(tr("Отвязать", "Unlink")) { linkKeychain(nil) }
                        }
                        Spacer()
                        Button(tr("Отмена", "Cancel")) { showKeychain = false }.keyboardShortcut(.cancelAction)
                        Button(tr("Подключить", "Link")) {
                            linkKeychain(KeychainEntry(
                                service: keychainService.trimmingCharacters(in: .whitespacesAndNewlines),
                                account: keychainAccount.trimmingCharacters(in: .whitespacesAndNewlines)
                            ))
                        }.keyboardShortcut(.defaultAction)
                            .disabled(keychainService.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                      keychainAccount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }.padding(20).frame(width: 485)
            }
            .sheet(isPresented: $showCommands) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(tr("Команды Antigravity", "Antigravity commands")).font(.headline)
                    Text(tr("Один префикс на строку, например npm run test или python3 analysis.py. Правило разрешает и дополнительные аргументы после префикса.", "Enter one prefix per line, such as npm run test or python3 analysis.py. The rule also allows arguments after the prefix."))
                    TextEditor(text: $commandText)
                        .font(.system(.body, design: .monospaced))
                        .accessibilityLabel(tr("Разрешённые команды", "Allowed commands"))
                        .border(Color.secondary.opacity(0.25))
                    if activeCommands == nil {
                        Text(tr("До 20 строк. В каждой укажи команду с аргументом, без кавычек, шаблонов и операторов оболочки.", "Up to 20 lines. Include a command and an argument on each line. Omit quotes, patterns, and shell operators."))
                            .foregroundStyle(.red)
                    }
                    Button(tr("Готово", "Done")) { showCommands = false }
                        .keyboardShortcut(.defaultAction)
                        .disabled(activeCommands == nil)
                }.padding(20).frame(width: 500, height: 270)
            }
            .onChange(of: generatedPrompt) { _ in editedPrompt = nil }
            .onChange(of: profile) { _ in editedPrompt = nil }
            .onChange(of: imageMode) { _ in editedPrompt = nil }
            .sheet(isPresented: $preview) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(editingTemplate ? tr("Шаблон режима", "Mode template") : tr("Текст для отправки", "Text to send")).font(.headline)
                    TextEditor(text: $promptDraft)
                        .font(.body)
                        .accessibilityLabel(tr("Текст промпта", "Prompt text"))
                        .border(Color.secondary.opacity(0.25))
                    HStack {
                        Button(tr("Восстановить исходный текст", "Restore original text")) { promptDraft = editingTemplate ? defaultTemplate : generatedPrompt }
                        Spacer()
                        Button(tr("Отмена", "Cancel")) { preview = false }.keyboardShortcut(.cancelAction)
                        Button(tr("Применить", "Apply")) {
                            if editingTemplate { saveTemplate() }
                            else { editedPrompt = promptDraft == generatedPrompt ? nil : promptDraft }
                            preview = false
                        }.keyboardShortcut(.defaultAction)
                    }
                }.padding(20).frame(minWidth: 580, minHeight: 360)
            }
    }

    private func metric(_ label: String, _ value: Int?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).foregroundStyle(.secondary)
            Text(value.map { $0.formatted() } ?? "—").monospacedDigit()
        }.font(.caption)
    }

    private func chooseImageReference() {
        let dialog = NSOpenPanel()
        dialog.allowedContentTypes = [.png, .jpeg, .webP]
        dialog.allowsMultipleSelection = false
        dialog.prompt = tr("Выбрать", "Choose")
        if dialog.runModal() == .OK { imageReference = dialog.url }
    }

    private func chooseFolder() {
        let dialog = NSOpenPanel()
        dialog.canChooseFiles = false
        dialog.canChooseDirectories = true
        dialog.allowsMultipleSelection = false
        if dialog.runModal() == .OK, let url = dialog.url { folder = url.path }
    }
}

@main
struct AgentDesk: App {
    var body: some Scene {
        WindowGroup("PoruBot Agent") { Panel() }
    }
}
