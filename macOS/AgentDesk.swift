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
               effort: String, mode: String, timeout: Int, prompt: String?) {
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
        task.arguments = engine.arguments(model: model, effort: effort, mode: mode, catalog: prompt == nil)
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
                        self.status = code == 0 && valid ? "Завершено" : "CLI завершился без успешного результата (код \(code))."
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
    private var key: Binding<String> {
        Binding(get: { keys[engine] ?? Engine.inherited[engine.keyName] ?? "" },
                set: { keys[engine] = $0 })
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
        let preferred = (path.wrappedValue as NSString).expandingTildeInPath
        let secret = key.wrappedValue
        let selectedEffort = chosen == .gemini && (exactID != nil || name.isEmpty) ? "" : effort
        let selectedModel = chosen == .gemini ? exactID ?? name : name
        let run: (String) -> Void = { executable in
            runner.start(engine: chosen, path: executable, folder: prompt == nil ? "" : folder,
                         key: secret, model: selectedModel, effort: selectedEffort,
                         mode: mode, timeout: timeout, prompt: prompt)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("PoruBot Agent").font(.largeTitle.weight(.semibold))
                Spacer()
                Label(runner.status, systemImage: runner.working ? "hourglass" : "terminal")
                    .foregroundStyle(.secondary).lineLimit(2)
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    GroupBox("Подключение") {
                        VStack(alignment: .leading, spacing: 9) {
                            Picker("Движок", selection: $engine) {
                                ForEach(Engine.allCases, id: \.self) { Text($0.rawValue) }
                            }
                            SecureField(engine.keyName, text: key)
                            TextField("Путь к " + engine.binary, text: path)
                            if engine.resolve(path.wrappedValue) == nil {
                                Text("CLI установится при запуске.").font(.caption).foregroundStyle(.secondary)
                            }
                            HStack {
                                Button("Выбрать папку…") { chooseFolder() }
                                Text(folder.isEmpty ? "Папка не выбрана" : folder)
                                    .font(.caption).lineLimit(1).truncationMode(.middle).help(folder)
                            }
                        }.padding(5)
                    }
                    GroupBox("Запуск") {
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
                    }
                    Spacer()
                }.frame(width: 295).disabled(runner.working)

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Picker("Задача", selection: $profile) {
                            ForEach(Profile.allCases, id: \.self) { Text($0.rawValue) }
                        }.pickerStyle(.segmented)
                        Toggle("Короткий контекст", isOn: $optimize)
                    }
                    TextEditor(text: $request)
                        .font(.body).frame(minHeight: 80)
                        .border(Color.secondary.opacity(0.25))
                        .accessibilityLabel("Задача")
                    TextField("Файлы, границы и критерий готовности", text: $scope)
                    HStack {
                        Button("Показать промпт") { preview = true }
                        Text("\(text.utf8.count) байт промпта").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if runner.working {
                            Button("Остановить") { runner.stop() }
                        } else {
                            Button("Запустить") { launch(text) }
                                .buttonStyle(.borderedProminent)
                                .disabled([key.wrappedValue, request, folder].contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                        }
                    }
                    Divider()
                    Text("Результат").font(.headline)
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
                            Text(runner.response.isEmpty ? "Здесь появится ответ агента." : runner.response)
                                .textSelection(.enabled)
                            if !runner.diagnostics.isEmpty {
                                DisclosureGroup("Диагностика CLI", isExpanded: $showDiagnostics) {
                                    Text(runner.diagnostics).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(minHeight: 130)
                }
            }
        }.padding(20).frame(minWidth: 820, minHeight: 610)
            .onChange(of: engine) { value in
                model = value.presets.first ?? ""
                effort = value == .codex ? "low" : ""
                mode = "accept-edits"
                runner.models = []
            }
            .onChange(of: runner.status) { status in
                showDiagnostics = status.hasPrefix("CLI завершился") || status.hasPrefix("Каталог не получен") || status.hasPrefix("Установка завершилась")
            }
            .onChange(of: runner.models) { models in
                guard model.isEmpty, let first = models.first(where: {
                    $0.name.localizedCaseInsensitiveContains("flash") && $0.effort == "low"
                }) else { return }
                model = first.name
                effort = first.effort
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
