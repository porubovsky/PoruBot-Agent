import SwiftUI
import AppKit

enum Profile: String, CaseIterable {
    case code = "Код", data = "Данные", quick = "Вопрос"
    var guidance: String {
        switch self {
        case .code:
            return "Начни с указанных файлов или точечного поиска. Читай только нужные фрагменты, сокращай логи. Сделай минимальное изменение и одну целевую проверку. При повторяющейся ошибке остановись и опиши блокер."
        case .data:
            return "Обрабатывай данные локально скриптом. Для ориентира возьми схему и до 5 строк. Возвращай агрегаты, выводы и ограничения. Сокращай вывод команд и не печатай весь датасет."
        case .quick:
            return "Ответь кратко. Используй файлы и инструменты только если без них нельзя выполнить задачу. Если данных не хватает, назови конкретный пробел."
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

struct Result: Decodable {
    var is_error: Bool?
    var result: String?
    var total_cost_usd: Double?
    var errors: [String]?
    var status: String?
    var response: String?
    var error: String?
    var usage: Usage?
}

struct CodexEvent: Decodable {
    struct Item: Decodable { var type: String; var text: String? }
    struct Failure: Decodable { var message: String? }
    var type: String
    var item: Item?
    var usage: Usage?
    var error: Failure?
    var message: String?
}

struct Event: Decodable {
    var result: Result?
    var event: String?
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

@MainActor
final class Runner: ObservableObject {
    @Published var working = false
    @Published var status = "Готово к запуску"
    @Published var response = ""
    @Published var diagnostics = ""
    @Published var usage: Usage?
    @Published var reportedCost: Double?
    @Published var models: [ModelChoice] = []
    private var process: Process?
    private var stopMessage: String?

    static let executable = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/bin/agy").path

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
               effort: String, mode: String, timeout: Int, prompt: String?, commands: [String] = [], allFolders: Bool = false, outsideSandbox: Bool = false) {
        guard !working else { return }
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { status = "Вставь ключ " + engine.keyName + "."; return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        if prompt != nil {
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder, isDirectory: &directory), directory.boolValue else {
                status = "Рабочая папка недоступна."; return
            }
            task.currentDirectoryURL = URL(fileURLWithPath: folder)
        }
        task.environment = engine.environment(key: key)
        task.arguments = engine.arguments(model: model, effort: effort, mode: mode, catalog: prompt == nil, commands: commands, allFolders: allFolders, outsideSandbox: outsideSandbox)
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
        working = true
        stopMessage = nil
        response = ""
        diagnostics = ""
        usage = nil
        reportedCost = nil
        status = installing ? "Устанавливаю \(engine.binary)…" : prompt == nil ? "Читаю каталог CLI…" : "Запускаю агента…"

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
            var codexResponse = ""
            var codexUsage: Usage?
            var codexError: String?

            func accept(_ bytes: Data) {
                let raw = String(decoding: bytes, as: UTF8.self)
                let line = key.isEmpty ? raw : raw.replacingOccurrences(of: key, with: "[ключ скрыт]")
                if prompt == nil {
                    if catalog.count < 100_000 { catalog += line + "\n" }
                } else if engine == .gemini, let event = try? JSONDecoder().decode(Event.self, from: Data(line.utf8)), event.event != nil {
                    if let final = event.result { result = final }
                } else if engine == .codex, let event = try? JSONDecoder().decode(CodexEvent.self, from: Data(line.utf8)) {
                    if event.type == "item.completed", event.item?.type == "agent_message" {
                        codexResponse = event.item?.text ?? codexResponse
                    }
                    if event.type == "turn.completed" { codexUsage = event.usage }
                    if event.type == "turn.failed" { codexError = event.error?.message ?? "Codex завершил задачу с ошибкой." }
                    if event.type == "error", let message = event.message, notes.count < 80 {
                        notes.append(String(message.prefix(1200)))
                    }
                } else if let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                          let type = object["type"] as? String, engine == .claude || engine == .router {
                    if type == "result" { result = try? JSONDecoder().decode(Result.self, from: Data(line.utf8)) }
                } else if !line.isEmpty && notes.count < 80 {
                    notes.append(String(line.prefix(1200)))
                }
            }

            while let chunk = try? reader.read(upToCount: 8192), !chunk.isEmpty {
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
            let openAIUsage = codexUsage
            let openAIError = codexError
            let log = notes.joined(separator: "\n")
            let collected = catalog
            DispatchQueue.main.async { [weak self] in
                guard let self, self.process === task else { return }
                self.working = false
                self.process = nil
                if installing {
                    self.diagnostics = collected
                    if let stopped = self.stopMessage {
                        self.status = stopped
                    } else if code == 0 {
                        self.status = "Установка завершена"
                        installerCompletion?()
                    } else {
                        self.status = "Установка завершилась с ошибкой (код \(code))."
                    }
                } else if prompt == nil {
                    let choices = ModelChoice.catalog(collected)
                    if code == 0 { self.models = choices }
                    self.diagnostics = collected
                    if let stopMessage = self.stopMessage {
                        self.status = stopMessage
                    } else {
                        self.status = code == 0 && !choices.isEmpty
                            ? "Каталог обновлён · \(choices.count) вариантов"
                            : "Каталог не получен. Можно ввести модель вручную."
                    }
                } else {
                    self.response = engine == .codex ? openAIResponse : (final?.response ?? final?.result ?? "")
                    self.usage = engine == .codex ? openAIUsage : final?.usage
                    self.reportedCost = engine == .claude ? final?.total_cost_usd : nil
                    self.diagnostics = [openAIError, final?.error, final?.errors?.joined(separator: "\n"), log].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
                    if let stopMessage = self.stopMessage {
                        self.status = stopMessage
                    } else {
                        let valid = engine == .codex ? openAIUsage != nil && openAIError == nil
                            : engine == .gemini ? final?.status == "SUCCESS" : final?.is_error == false
                        let diagnostic = self.diagnostics.lowercased()
                        if engine == .gemini && diagnostic.contains("no output produced")
                            && diagnostic.contains("unsandboxed") {
                            self.status = "Antigravity запросил команду вне песочницы"
                        } else if engine == .gemini && diagnostic.contains("no output produced")
                            && diagnostic.contains("command") && diagnostic.contains("permission") {
                            self.status = "Antigravity отклонил команду"
                        } else {
                            self.status = code == 0 && valid ? "Завершено" : "CLI завершился без успешного результата (код \(code))."
                        }
                    }
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(timeout)) { [weak self, weak task] in
            guard let self, let task, self.process === task, task.isRunning else { return }
            self.stop(reason: "Запуск остановлен по лимиту времени.")
        }
    }

    func stop(reason: String = "Запуск остановлен.") {
        guard let process, process.isRunning else { return }
        stopMessage = reason
        status = "Останавливаю CLI…"
        process.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak process] in
            guard let process, process.isRunning else { return }
            kill(process.processIdentifier, SIGKILL)
        }
    }
}

struct Panel: View {
    @StateObject private var runner = Runner()
    @AppStorage("cliPath") private var cliPath = Runner.executable
    @AppStorage("folder") private var folder = ""
    @State private var engine = Engine.gemini
    @State private var keys: [Engine: String] = [:]
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
        Binding(get: { keys[engine] ?? Engine.inherited[engine.keyName] ?? "" },
                set: { keys[engine] = $0; keychainMessage.removeValue(forKey: engine) })
    }
    private var path: Binding<String> {
        Binding(get: { engine == .gemini ? cliPath : (paths[engine] ?? engine.resolve("") ?? "") },
                set: { if engine == .gemini { cliPath = $0 } else { paths[engine] = $0 } })
    }
    @State private var model = ""
    @State private var effort = ""
    @State private var profile = Profile.code
    @State private var mode = "accept-edits"
    @State private var timeout = 180
    @State private var request = ""
    @State private var scope = ""
    @State private var optimize = true
    @State private var preview = false
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

    private func linkKeychain(_ entry: KeychainEntry?) {
        var entries = linkedEntries
        entries[engine.keyName] = entry
        guard let encoded = try? JSONEncoder().encode(entries) else { return }
        keychainEntries = encoded
        keys.removeValue(forKey: engine)
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
            keychainMessage[provider] = "Приложение «Пароли» недоступно на этой версии macOS."
            return
        }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard error != nil else { return }
            DispatchQueue.main.async { keychainMessage[provider] = "Не удалось открыть «Пароли»." }
        }
    }

    private func saveCurrentKey() {
        let provider = engine
        let secret = key.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty, keychainSaving.insert(provider).inserted else { return }
        let entry = KeychainEntry.porubot(provider.keyName)
        keychainMessage[provider] = "Сохраняю ключ…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = entry.save(secret)
            DispatchQueue.main.async {
                keychainSaving.remove(provider)
                switch result {
                case .success:
                    var entries = linkedEntries
                    entries[provider.keyName] = entry
                    if let encoded = try? JSONEncoder().encode(entries) { keychainEntries = encoded }
                    if keys[provider] == nil { keys[provider] = secret }
                    keychainMessage[provider] = "Ключ сохранён в Связке ключей"
                case let .failure(error):
                    keychainMessage[provider] = error.message
                }
            }
        }
    }

    private func loadKeychain(for provider: Engine) {
        guard keys[provider] == nil, let entry = linkedEntries[provider.keyName],
              keychainLoading.insert(provider).inserted else { return }
        keychainMessage[provider] = "Читаю Связку ключей…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = entry.read()
            DispatchQueue.main.async {
                keychainLoading.remove(provider)
                guard linkedEntries[provider.keyName] == entry, keys[provider] == nil else {
                    keychainMessage.removeValue(forKey: provider)
                    if linkedEntries[provider.keyName] != entry { loadKeychain(for: provider) }
                    return
                }
                switch result {
                case let .success(secret):
                    keys[provider] = secret
                    keychainMessage[provider] = "Ключ из Связки ключей"
                case let .failure(error):
                    keychainMessage[provider] = error.message
                }
            }
        }
    }

    private var text: String {
        let task = request.trimmingCharacters(in: .whitespacesAndNewlines)
        let focus = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        let scoped = focus.isEmpty ? task : task + "\n\nГраницы задачи и условие готовности:\n" + focus
        guard optimize else { return scoped }
        return scoped + "\n\nРаботай точечно. " + profile.guidance
            + " Не расширяй задачу. В конце кратко укажи результат и проверку."
    }

    private func launch(_ prompt: String?) {
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let catalogID = runner.models.first {
            $0.name.caseInsensitiveCompare(name) == .orderedSame && $0.effort == effort
        }?.id
        let isExactGeminiID = name.wholeMatch(of: /gemini-[a-z0-9.\-]+-(minimal|low|medium|high|xhigh|max)/) != nil
        let exactID = catalogID ?? (isExactGeminiID ? name : nil)
        let chosen = engine
        let useCommands = chosen == .gemini && prompt != nil && mode != "plan"
        let allowAll = useCommands && allowAllCommands
        guard !useCommands || allowAll || activeCommands != nil else {
            runner.status = "Проверь список команд Antigravity."
            showCommands = true
            return
        }
        let commands = allowAll ? ["*"] : (useCommands ? (activeCommands ?? []) : [])
        let allFolders = prompt != nil && mode != "plan" && allFoldersEnabled
        let outsideSandbox = useCommands && mode == "accept-edits" && outsideSandboxEnabled
        let preferred = (path.wrappedValue as NSString).expandingTildeInPath
        let secret = key.wrappedValue
        let selectedEffort = chosen == .gemini && (exactID != nil || name.isEmpty) ? "" : effort
        let selectedModel = chosen == .gemini ? exactID ?? name : name
        let run: (String) -> Void = { executable in
            runner.start(engine: chosen, path: executable, folder: prompt == nil ? "" : folder,
                         key: secret, model: selectedModel, effort: selectedEffort,
                         mode: mode, timeout: timeout, prompt: prompt, commands: commands, allFolders: allFolders, outsideSandbox: outsideSandbox)
        }
        if let executable = chosen.resolve(preferred) {
            run(executable)
        } else {
            runner.install(chosen) {
                guard let executable = chosen.resolve(preferred) else {
                    runner.status = "CLI не найден после установки. Укажи путь вручную."
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
                    Label("В режиме «План» расширенный доступ не применяется.", systemImage: "lock")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    if engine == .gemini {
                        Toggle(isOn: $allowAllCommands) {
                            Label("Все команды", systemImage: "terminal")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .help("Разрешает любую команду, включая удаление или перезапись, в пределах песочницы.")
                        Button { showCommands = true } label: {
                            Label("Выбрать команды…", systemImage: "list.bullet.rectangle")
                        }
                        .disabled(allowAllCommands)
                        if mode == "accept-edits" {
                            Toggle(isOn: Binding(
                                get: { outsideSandboxEnabled },
                                set: { if $0 { confirmOutsideSandbox = true } else { outsideSandboxEnabled = false } }
                            )) {
                                Label("Команды без песочницы", systemImage: "lock.open")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .alert("Запустить Antigravity без песочницы команд?", isPresented: $confirmOutsideSandbox) {
                                Button("Отмена", role: .cancel) {}
                                Button("Включить") { outsideSandboxEnabled = true }
                            } message: {
                                Text("Разрешённые команды смогут работать с файлами и сетью вне песочницы. Настройка сохранится для следующих задач.")
                            }
                        }
                    } else {
                        Label("Команды: правила движка", systemImage: "terminal")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle(isOn: Binding(
                        get: { allFoldersEnabled },
                        set: { if $0 { confirmAllFolders = true } else { allFoldersEnabled = false } }
                    )) {
                        Label("Все доступные папки", systemImage: "folder.badge.plus")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text("Настройки действуют, пока включены.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.toggleStyle(.switch).padding(5)
        } label: {
            section("Доступ агента", icon: "lock.shield")
        }
        .confirmationDialog("Открыть агенту доступ ко всем папкам?", isPresented: $confirmAllFolders, titleVisibility: .visible) {
            Button("Включить") { allFoldersEnabled = true }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Агент сможет читать и править файлы за пределами выбранной папки. Доступ останется включённым, пока ты его не отключишь.")
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
                    Label(engine.rawValue, systemImage: engine.symbol)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Label(runner.status, systemImage: runner.working ? "hourglass" : "terminal")
                    .font(.system(.caption, design: .rounded).weight(.medium))
                    .foregroundStyle(.secondary).lineLimit(2)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.thinMaterial, in: Capsule())
            }
            .padding(12)
            .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
            .padding(.top, 12)
            HStack(alignment: .top, spacing: 16) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 9) {
                            Picker("Движок", selection: $engine) {
                                ForEach(Engine.allCases, id: \.self) { Text($0.rawValue) }
                            }
                            SecureField(engine.keyName, text: key)
                            Menu {
                                Button("Открыть «Пароли»") { openPasswords() }
                                Button("Сохранить текущий ключ в Связке ключей") { saveCurrentKey() }
                                    .disabled(key.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                              keychainSaving.contains(engine))
                                Button("Привязать существующую запись…") { openKeychainSettings() }
                            } label: { Label("Пароли и ключи", systemImage: "key") }
                            if let message = keychainMessage[engine] {
                                Text(message).font(.caption).foregroundStyle(.secondary)
                            }
                            TextField("Путь к " + engine.binary, text: path)
                            if engine.resolve(path.wrappedValue) == nil {
                                Text("CLI установится при запуске.").font(.caption).foregroundStyle(.secondary)
                            }
                            HStack {
                                Button { chooseFolder() } label: { Label("Папка…", systemImage: "folder") }
                                Text(folder.isEmpty ? "Папка не выбрана" : folder)
                                    .font(.caption).lineLimit(1).truncationMode(.middle).help(folder)
                            }
                        }.padding(5)
                    } label: { section("Подключение", icon: "key") }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 9) {
                            HStack {
                                if engine == .gemini {
                                    Button("Загрузить модели") { launch(nil) }
                                        .disabled(key.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                }
                                if engine != .gemini {
                                    Menu("Модели") {
                                        ForEach(engine.presets, id: \.self) { item in
                                            Button(item) { model = item }
                                        }
                                    }
                                } else if !runner.models.isEmpty {
                                    Menu("Выбрать") {
                                        ForEach(runner.models, id: \.self) { option in
                                            Button(option.label) { model = option.name; effort = option.effort }
                                        }
                                    }
                                }
                            }
                            TextField("Имя или ID модели", text: $model)
                            Picker("Thinking level", selection: $effort) {
                                Text("По умолчанию").tag("")
                                ForEach(engine.efforts, id: \.self) {
                                    Text($0).tag($0)
                                }
                            }
                            Picker("Режим CLI", selection: $mode) {
                                if engine == .gemini { Text("Авто в песочнице").tag("auto") }
                                Text("Правки файлов").tag("accept-edits")
                                Text("План").tag("plan")
                            }
                            Stepper("Время: \(timeout) с", value: $timeout, in: 30...900, step: 30)
                        }.padding(5)
                    } label: { section("Запуск", icon: "slider.horizontal.3") }
                    accessControls
                    }
                    .padding(.trailing, 8)
                    .padding(.bottom, 8)
                    .disabled(runner.working)
                }.frame(width: 320)

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Picker("Профиль задачи", selection: $profile) {
                            ForEach(Profile.allCases, id: \.self) { Text($0.rawValue) }
                        }.pickerStyle(.segmented).labelsHidden()
                        Toggle("Короткий контекст", isOn: $optimize)
                    }
                    section("Задача", icon: "square.and.pencil")
                    TextEditor(text: $request)
                        .font(.system(size: 14)).lineSpacing(4)
                        .scrollContentBackground(.hidden)
                        .padding(8).frame(minHeight: 90)
                        .background(surface, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.secondary.opacity(0.20)))
                        .accessibilityLabel("Задача")
                    TextField("Файлы, границы и критерий готовности", text: $scope)
                    HStack {
                        Button { preview = true } label: { Label("Промпт", systemImage: "eye") }
                        Text("\(text.utf8.count) байт промпта").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if runner.working {
                            Button { runner.stop() } label: { Label("Остановить", systemImage: "stop.fill") }
                        } else {
                            Button { launch(text) } label: { Label("Запустить", systemImage: "play.fill") }
                                .buttonStyle(.borderedProminent)
                                .disabled([key.wrappedValue, request, folder].contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                        }
                    }
                    Divider()
                    section("Результат", icon: "text.alignleft")
                    if let usage = runner.usage {
                        HStack(spacing: 10) {
                            metric("Вход", usage.input_tokens)
                            metric("Выход", usage.output_tokens)
                            metric("Thinking", usage.thinking_tokens)
                            metric("Кэш", usage.cache_read_tokens ?? usage.cached_input_tokens ?? usage.cache_read_input_tokens)
                            metric("Всего", usage.total_tokens)
                        }
                    }
                    if let cost = runner.reportedCost {
                        Text("Оценка CLI: " + cost.formatted(.currency(code: "USD"))).font(.caption)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            if runner.response.isEmpty {
                                Text("Здесь появится ответ агента.").foregroundStyle(.secondary)
                            } else {
                                AgentResponseView(response: runner.response)
                            }
                            if !runner.diagnostics.isEmpty {
                                DisclosureGroup("Диагностика CLI", isExpanded: $showDiagnostics) {
                                    Text(runner.diagnostics).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }.frame(minHeight: 130)
                        .background(surface, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.secondary.opacity(0.20)))
                }
            }
        }.padding(18).frame(minWidth: 860, minHeight: 690)
            .tint(accent)
            .onAppear { loadKeychain(for: engine) }
            .onChange(of: engine) { value in
                loadKeychain(for: value)
                model = value.presets.first ?? ""
                effort = value == .codex ? "low" : ""
                mode = "accept-edits"
                runner.models = []
            }
            .onChange(of: runner.status) { status in
                showDiagnostics = status.hasPrefix("Antigravity ") || status.hasPrefix("CLI завершился") || status.hasPrefix("Каталог не получен") || status.hasPrefix("Установка завершилась")
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
                    Text("Связка ключей · " + engine.rawValue).font(.headline)
                    Text("Укажи имя службы и учётную запись существующей записи типа «Пароль приложения». При выборе движка PoruBot будет читать ключ из этой записи.")
                    TextField("Имя службы", text: $keychainService)
                    TextField("Учётная запись", text: $keychainAccount)
                    HStack {
                        if linkedEntries[engine.keyName] != nil {
                            Button("Отвязать") { linkKeychain(nil) }
                        }
                        Spacer()
                        Button("Отмена") { showKeychain = false }.keyboardShortcut(.cancelAction)
                        Button("Подключить") {
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
                    Text("Команды Antigravity").font(.headline)
                    Text("Один префикс на строку, например npm run test или python3 analysis.py. Правило разрешает и дополнительные аргументы после префикса.")
                    TextEditor(text: $commandText)
                        .font(.system(.body, design: .monospaced))
                        .accessibilityLabel("Разрешённые команды")
                        .border(Color.secondary.opacity(0.25))
                    if activeCommands == nil {
                        Text("До 20 строк. В каждой укажи команду с аргументом, без кавычек, шаблонов и операторов оболочки.")
                            .foregroundStyle(.red)
                    }
                    Button("Готово") { showCommands = false }
                        .keyboardShortcut(.defaultAction)
                        .disabled(activeCommands == nil)
                }.padding(20).frame(width: 500, height: 270)
            }
            .sheet(isPresented: $preview) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Промпт для CLI").font(.headline)
                    ScrollView { Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    Button("Закрыть") { preview = false }.keyboardShortcut(.cancelAction)
                }.padding(20).frame(width: 570, height: 320)
            }
    }

    private func metric(_ label: String, _ value: Int?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).foregroundStyle(.secondary)
            Text(value.map { $0.formatted() } ?? "—").monospacedDigit()
        }.font(.caption)
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
