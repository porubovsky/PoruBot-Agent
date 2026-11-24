using System.Text.RegularExpressions;

static class Program
{
    [STAThread]
    static void Main()
    {
        ApplicationConfiguration.Initialize();
        Application.Run(new AgentWindow());
    }
}

sealed class AgentWindow : Form
{
    private Palette palette = Palette.Resolve("system");
    private static readonly Font Body = new("Segoe UI Variable Text", 11);
    private static readonly Font Title = new("Segoe UI Semibold", 23);
    private static readonly Font Section = new("Segoe UI Semibold", 13);
    private static readonly Font Bold = new("Segoe UI", 11, FontStyle.Bold);
    private static readonly Font Mono = new("Consolas", 11);

    private readonly ThemeChoice engine = new() { AccessibleName = "Движок" };
    private readonly ThemeChoice model = new(true) { AccessibleName = "Модель" };
    private readonly ThemeChoice effort = new() { AccessibleName = "Уровень Thinking" };
    private readonly ThemeChoice profile = new() { AccessibleName = "Профиль задачи" };
    private readonly ThemeChoice theme = new() { AccessibleName = "Цветовая тема" };
    private readonly TextBox key = new() { UseSystemPasswordChar = true };
    private readonly TextBox prompt = new() { Multiline = true, ScrollBars = ScrollBars.Vertical };
    private readonly TextBox scope = new() { PlaceholderText = "Файлы, границы и критерий готовности" };
    private readonly RichTextBox result = new() { ReadOnly = true, DetectUrls = false, BorderStyle = BorderStyle.None };
    private readonly Label folder = new() { AutoEllipsis = true };
    private readonly Label state = new() { AutoEllipsis = true, TextAlign = ContentAlignment.MiddleRight };
    private readonly Label metrics = new() { AutoEllipsis = true };
    private readonly ModernSwitch plan = new() { Text = "Только план" };
    private readonly ThemeChoice sessions = new() { AccessibleName = "Разговор", Width = 250 };
    private bool updatingSessions;
    private string? selectedSession;
    private readonly Label taskHeading = new() { Text = "Задача", Dock = DockStyle.Fill };
    private string? generatedImagePath;
    private readonly ModernSwitch compact = new() { Text = "Короткий контекст", Checked = true, Width = 205 };
    private readonly ModernSwitch commands = new() { Text = "Все команды" };
    private readonly ModernSwitch folders = new() { Text = "Все доступные папки" };
    private readonly ModernSwitch sandbox = new() { Text = "Команды без песочницы" };
    private readonly ThemeChoice timeout = new(true) { AccessibleName = "Лимит задачи в секундах" };
    private readonly Button run = Button("▶  Запустить", true);
    private readonly Button stop = Button("■  Остановить");
    private readonly Button catalog = Button("Загрузить модели");
    private readonly FlowLayoutPanel sidebar = new() { FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoScroll = true };
    private readonly Dictionary<Engine, string> keys = new();
    private readonly Dictionary<(string, string), string> models = new();
    private Settings settings = Settings.Read();
    private CancellationTokenSource? job;
    private Engine? previous;
    private bool updatingAccess;
    private (string Answer, string Diagnostics)? displayed;
    private bool themeReady;
    private readonly System.Windows.Forms.Timer progressTimer = new() { Interval = 1000 };
    private readonly System.Diagnostics.Stopwatch elapsed = new();
    private string phase = "";
    private string ThemeMode => theme.SelectedIndex switch { 1 => "light", 2 => "dark", _ => "system" };

    public AgentWindow()
    {
        Text = "PoruBot Agent";
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new(1080, 760);
        MinimumSize = new(870, 650);
        AutoScaleMode = AutoScaleMode.Dpi;
        Font = Body.Name == "Segoe UI Variable Text" ? Body : new Font("Segoe UI", 11);
        prompt.AccessibleName = "Задача";
        result.AccessibleName = "Результат";
        using (var stream = typeof(AgentWindow).Assembly.GetManifestResourceStream("PoruBot.ico"))
            if (stream is not null) Icon = new Icon(stream);

        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 2, Padding = new(16) };
        layout.ColumnStyles.Add(new(SizeType.Absolute, 328));
        layout.ColumnStyles.Add(new(SizeType.Percent, 100));
        layout.RowStyles.Add(new(SizeType.Absolute, 81));
        layout.RowStyles.Add(new(SizeType.Percent, 100));
        Controls.Add(layout);

        var header = new TableLayoutPanel { Dock = DockStyle.Fill, Name = "card", ColumnCount = 4, Padding = new(14, 0, 14, 0), Margin = new(0, 0, 0, 12) };
        header.ColumnStyles.Add(new(SizeType.Absolute, 44));
        header.ColumnStyles.Add(new(SizeType.Percent, 55));
        header.ColumnStyles.Add(new(SizeType.Percent, 45));
        header.ColumnStyles.Add(new(SizeType.Absolute, 154));
        var picture = new PictureBox { Image = Icon?.ToBitmap(), SizeMode = PictureBoxSizeMode.Zoom, Dock = DockStyle.Fill };
        header.Controls.Add(picture, 0, 0);
        header.Controls.Add(new Label { Text = "PoruBot Agent", Dock = DockStyle.Fill, Font = Title, TextAlign = ContentAlignment.MiddleLeft }, 1, 0);
        state.Text = "Готов к запуску";
        state.Dock = DockStyle.Fill;
        state.Name = "muted";
        header.Controls.Add(state, 2, 0);
        theme.Items.AddRange(["Как в Windows", "Светлая", "Тёмная"]);
        theme.SelectedIndex = settings.Theme switch { "light" => 1, "dark" => 2, _ => 0 };
        theme.Dock = DockStyle.Top;
        theme.Margin = new(12, 15, 0, 0);
        header.Controls.Add(theme, 3, 0);
        layout.Controls.Add(header, 0, 0);
        layout.SetColumnSpan(header, 2);

        sidebar.Dock = DockStyle.Fill;
        sidebar.Margin = new(0, 0, 10, 0);
        layout.Controls.Add(sidebar, 0, 1);
        var chooseFolder = Button("▣  Выбрать папку…");
        var saveKey = Button("Сохранить ключ");
        var connection = CreateSection("Подключение");
        Add(connection, engine, new FieldFrame(key) { Height = 35 }, saveKey, chooseFolder, folder);
        var launch = CreateSection("Запуск");
        timeout.Items.AddRange(["60", "120", "180", "300", "600", "900"]);
        timeout.SelectedIndex = 2;
        Add(launch, model, catalog, new Label { Text = "Уровень Thinking", Name = "muted" }, effort, plan,
            new Label { Text = "Лимит задачи, секунд", Name = "muted" }, timeout);
        var permissions = CreateSection("Доступ агента");
        Add(permissions, commands, folders, sandbox, new Label { Text = "Настройки действуют, пока включены.", Name = "muted" });
        foreach (var section in new[] { connection, launch, permissions }) sidebar.Controls.Add(section);

        var workspace = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 8, Margin = new(5, 0, 0, 0) };
        foreach (var style in new[] {
            new RowStyle(SizeType.Absolute, 43), new RowStyle(SizeType.Absolute, 28),
            new RowStyle(SizeType.Absolute, 62), new RowStyle(SizeType.Absolute, 41),
            new RowStyle(SizeType.Absolute, 43), new RowStyle(SizeType.Absolute, 28),
            new RowStyle(SizeType.Absolute, 26), new RowStyle(SizeType.Percent, 100) }) workspace.RowStyles.Add(style);
        layout.Controls.Add(workspace, 1, 1);
        profile.Items.AddRange(["Код", "Данные", "Вопрос", "Картинка"]);
        profile.SelectedIndex = 0;
        var options = new FlowLayoutPanel { Dock = DockStyle.Fill };
        options.Controls.AddRange([profile, compact]);
        workspace.Controls.Add(options, 0, 0);
        taskHeading.Font = Section;
        var taskBar = new FlowLayoutPanel { Dock = DockStyle.Fill, WrapContents = false };
        taskHeading.Width = 180;
        taskHeading.Height = 32;
        taskHeading.Dock = DockStyle.None;
        taskBar.Controls.AddRange([taskHeading, sessions]);
        workspace.Controls.Add(taskBar, 0, 1);
        workspace.RowStyles[1].Height = 40;
        sessions.SelectedIndexChanged += (_, _) => SelectSession();
        workspace.Controls.Add(new FieldFrame(prompt) { Dock = DockStyle.Fill }, 0, 2);
        void SizePrompt()
        {
            var availableWidth = Math.Max(80, workspace.ClientSize.Width - SystemInformation.VerticalScrollBarWidth - 14);
            int measured = TextRenderer.MeasureText(prompt.Text + "\n ", prompt.Font, new Size(availableWidth, 4096),
                TextFormatFlags.TextBoxControl | TextFormatFlags.WordBreak | TextFormatFlags.NoPadding).Height;
            float height = Math.Clamp(measured + 12, 62, Math.Max(62, Math.Min(210, workspace.ClientSize.Height / 3)));
            if (workspace.RowStyles[2].Height != height) workspace.RowStyles[2].Height = height;
        }
        prompt.TextChanged += (_, _) => SizePrompt();
        workspace.Resize += (_, _) => SizePrompt();
        workspace.Controls.Add(new FieldFrame(scope) { Dock = DockStyle.Fill }, 0, 3);
        var buttons = new FlowLayoutPanel { FlowDirection = FlowDirection.RightToLeft, Dock = DockStyle.Fill };
        var preview = Button("Промпт");
        buttons.Controls.AddRange([run, stop, preview]);
        stop.Visible = false;
        workspace.Controls.Add(buttons, 0, 4);
        workspace.Controls.Add(new Label { Text = "Результат", Font = Section, Dock = DockStyle.Fill }, 0, 5);
        metrics.Name = "muted";
        metrics.Dock = DockStyle.Fill;
        workspace.Controls.Add(metrics, 0, 6);
        result.Text = "Здесь появится ответ агента.";
        workspace.Controls.Add(new FieldFrame(result, 12) { Dock = DockStyle.Fill }, 0, 7);

        commands.Checked = settings.AllCommands;
        folders.Checked = settings.AllFolders;
        sandbox.Checked = settings.OutsideSandbox;
        folder.Text = settings.Folder.Length > 0 ? settings.Folder : "Папка не выбрана";
        folder.Tag = settings.Folder;
        engine.DisplayLabel = item => ImageMode && item is Engine provider
            ? provider.Gemini ? "Google" : "OpenAI"
            : item.ToString() ?? "";
        engine.Items.AddRange(Engine.All);
        engine.SelectedIndexChanged += (_, _) => ChangeEngine();
        engine.SelectedIndex = 0;
        plan.CheckedChanged += (_, _) => UpdateAccess();
        commands.CheckedChanged += (_, _) => SaveAccess();
        folders.CheckedChanged += (_, _) => Confirm(folders, "Агент сможет работать за пределами выбранной папки на доступных локальных дисках.");
        sandbox.CheckedChanged += (_, _) => Confirm(sandbox, "Разрешённые команды Antigravity смогут работать с файлами и сетью вне песочницы.");
        chooseFolder.Click += (_, _) =>
        {
            using var dialog = new FolderBrowserDialog { SelectedPath = WorkingFolder };
            if (dialog.ShowDialog(this) != DialogResult.OK) return;
            folder.Text = dialog.SelectedPath;
            folder.Tag = dialog.SelectedPath;
            selectedSession = null;
            RefreshSessions();
            SaveAccess();
        };
        saveKey.Click += (_, _) =>
        {
            if (key.Text.Trim().Length == 0) { state.Text = "Вставь API-ключ."; return; }
            try { Settings.SaveKey(Selected, key.Text.Trim()); state.Text = "Ключ сохранён для твоего профиля Windows."; }
            catch (Exception e) when (e is IOException or System.Security.Cryptography.CryptographicException or UnauthorizedAccessException)
            { state.Text = "Не удалось сохранить ключ."; }
        };
        run.Click += async (_, _) => await Submit(false);
        catalog.Click += async (_, _) => await Submit(true);
        stop.Click += (_, _) => job?.Cancel();
        preview.Click += (_, _) => MessageBox.Show(this, TaskPrompt(), "Промпт");
        profile.SelectedIndexChanged += (_, _) =>
        {
            compact.Enabled = !ImageMode;
            scope.Enabled = !ImageMode;
            var previousEngine = Selected;
            engine.Items.Clear();
            engine.Items.AddRange(ImageMode ? Engine.All.Where(item => item.Gemini || item.Codex) : Engine.All);
            var index = engine.Items.IndexOf(previousEngine);
            engine.SelectedIndex = Math.Max(0, index);
            UpdateAccess();
        };
        result.DoubleClick += (_, _) =>
        {
            if (generatedImagePath is { } path && File.Exists(path))
            {
                var start = new System.Diagnostics.ProcessStartInfo("explorer.exe") { UseShellExecute = false };
                start.ArgumentList.Add("/select," + path);
                System.Diagnostics.Process.Start(start)?.Dispose();
            }
        };
        progressTimer.Tick += (_, _) => UpdateProgress();
        FormClosing += (_, _) => job?.Cancel();
        FormClosed += (_, _) => progressTimer.Dispose();
        theme.SelectedIndexChanged += (_, _) => { SaveAccess(); ApplyTheme(); };
        themeReady = true;
        ApplyTheme();
        Shown += (_, _) => palette.ApplyCaption(Handle);
    }

    private Engine Selected => (Engine)engine.SelectedItem!;
    private bool ImageMode => profile.SelectedIndex == 3;
    private string WorkingFolder => folder.Tag as string ?? "";

    private static Button Button(string text, bool primary = false) => new ModernButton(text, primary);

    private static FlowLayoutPanel CreateSection(string title)
    {
        var card = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
            WrapContents = false, Name = "card", Padding = new(13), Margin = new(0, 0, 0, 10) };
        card.Controls.Add(new Label { Text = title, Font = Section, Name = "accent", Width = 260, Height = 30 });
        return card;
    }

    private static void Add(FlowLayoutPanel section, params Control[] controls)
    {
        foreach (var control in controls)
        {
            control.Width = 260;
            control.Margin = new(0, 0, 0, 6);
            if (control is Label) control.Height = control.Text.Length > 34 ? 39 : 24;
            if (control is ModernSwitch) control.Height = 30;
            section.Controls.Add(control);
        }
    }

    protected override void WndProc(ref Message message)
    {
        base.WndProc(ref message);
        if (message.Msg == 0x001A && themeReady && ThemeMode == "system") ApplyTheme();
    }

    private void ApplyTheme()
    {
        palette = Palette.Resolve(ThemeMode);
        BackColor = palette.Canvas;
        ForeColor = palette.Ink;
        void Style(Control parent)
        {
            foreach (Control child in parent.Controls)
            {
                if (child is IThemed themed) themed.Apply(palette);
                else
                {
                    child.BackColor = child.Name == "card" ? palette.Card : parent.BackColor;
                    child.ForeColor = child.Name switch { "muted" => palette.Muted, "accent" => palette.Accent, _ => palette.Ink };
                    Style(child);
                }
                child.Invalidate();
            }
        }
        Style(this);
        if (IsHandleCreated) palette.ApplyCaption(Handle);
        if (displayed is { } value) Render(value.Answer, value.Diagnostics);
    }

    private void ChangeEngine()
    {
        if (previous is not null) keys[previous] = key.Text;
        var selected = Selected;
        if (previous != selected) selectedSession = null;
        previous = selected;
        key.PlaceholderText = selected.Key;
        if (keys.TryGetValue(selected, out var value)) key.Text = value;
        else
        {
            try { key.Text = Settings.ReadKey(selected) ?? Environment.GetEnvironmentVariable(selected.Key) ?? ""; }
            catch (Exception e) when (e is IOException or System.Security.Cryptography.CryptographicException or UnauthorizedAccessException)
            { key.Clear(); state.Text = "Не удалось прочитать сохранённый ключ."; }
        }
        model.Items.Clear();
        model.Items.AddRange(selected.Models);
        model.SelectedIndex = 0;
        effort.Items.Clear();
        effort.Items.AddRange(selected.Codex ? ["По умолчанию", "minimal", "low", "medium", "high", "xhigh"]
            : ["По умолчанию", "low", "medium", "high", "xhigh", "max"]);
        effort.SelectedIndex = selected.Gemini ? 1 : 0;
        UpdateAccess();
    }

    private void UpdateAccess()
    {
        catalog.Visible = Selected.Gemini && !ImageMode;
        model.Enabled = effort.Enabled = plan.Enabled = !ImageMode;
        taskHeading.Text = ImageMode ? "Описание картинки · " + ImageGeneration.Name(Selected) : "Задача";
        commands.Enabled = sandbox.Enabled = !ImageMode && Selected.Gemini && !plan.Checked;
        folders.Enabled = !ImageMode && !plan.Checked;
        RefreshSessions();
    }

    private void RefreshSessions()
    {
        sessions.Visible = !ImageMode && (Selected.Gemini || Selected.Codex);
        sessions.Enabled = job is null && Directory.Exists(WorkingFolder);
        if (!sessions.Visible) return;
        updatingSessions = true;
        try
        {
            sessions.Items.Clear();
            sessions.Items.Add("Новый разговор");
            sessions.Items.AddRange((settings.Sessions ?? []).Where(item => item.Engine == Selected.Name &&
                string.Equals(item.Folder, WorkingFolder, StringComparison.OrdinalIgnoreCase)));
            var index = sessions.Items.FindIndex(item => item is SavedSession session && session.Id == selectedSession);
            if (selectedSession is not null && index < 0)
            {
                index = sessions.Items.Count;
                sessions.Items.Add(new SavedSession(selectedSession, Selected.Name, WorkingFolder, "Разговор по ID"));
            }
            sessions.Items.Add("Открыть по ID…");
            sessions.SelectedIndex = Math.Max(0, index);
        }
        finally { updatingSessions = false; }
    }

    private void SelectSession()
    {
        if (updatingSessions) return;
        if (sessions.SelectedItem is SavedSession item) { selectedSession = item.Id; return; }
        if (sessions.SelectedIndex == 0) { selectedSession = null; return; }
        using var dialog = new Form { Text = "Продолжить разговор по ID", ClientSize = new(390, 94),
            FormBorderStyle = FormBorderStyle.FixedDialog, StartPosition = FormStartPosition.CenterParent,
            MinimizeBox = false, MaximizeBox = false, Font = Font };
        var field = new TextBox { PlaceholderText = "UUID сессии из CLI", Bounds = new(12, 14, 365, 31) };
        var confirm = new Button { Text = "Выбрать", DialogResult = DialogResult.OK, Enabled = false,
            Bounds = new(264, 49, 113, 32) };
        field.TextChanged += (_, _) => confirm.Enabled = Guid.TryParse(field.Text.Trim(), out _);
        dialog.Controls.AddRange([field, confirm]);
        dialog.AcceptButton = confirm;
        if (dialog.ShowDialog(this) == DialogResult.OK) selectedSession = field.Text.Trim();
        RefreshSessions();
    }

    private void RememberSession(Engine provider, string directory, string id, string prompt, string key)
    {
        var all = (settings.Sessions ?? []).ToList();
        var existing = all.FirstOrDefault(item => item.Id == id && item.Engine == provider.Name && item.Folder == directory);
        if (existing is not null) all.Remove(existing);
        var title = prompt.Split('\n', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? "Разговор";
        title = title.Replace(key, "[ключ скрыт]");
        all.Insert(0, existing ?? new SavedSession(id, provider.Name, directory, title[..Math.Min(84, title.Length)]));
        settings = settings with { Sessions = all.Take(200).ToArray() };
        selectedSession = id;
        SaveAccess();
    }

    private void Confirm(CheckBox option, string message)
    {
        if (updatingAccess) return;
        if (option.Checked && MessageBox.Show(this, message + "\n\nНастройка сохранится для следующих задач.",
                "Доступ агента", MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2) != DialogResult.Yes)
        {
            updatingAccess = true;
            option.Checked = false;
            updatingAccess = false;
        }
        SaveAccess();
    }

    private void SaveAccess()
    {
        settings = new(commands.Checked, folders.Checked, sandbox.Checked, WorkingFolder, ThemeMode, settings.Sessions);
        try { settings.Save(); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        { state.Text = "Не удалось сохранить настройки."; }
    }

    private string TaskPrompt()
    {
        string task = prompt.Text.Trim();
        if (ImageMode) return task;
        if (scope.Text.Trim().Length > 0) task += "\n\nГраницы задачи и критерий готовности:\n" + scope.Text.Trim();
        if (!compact.Checked) return task;
        string[] hints = [
            "Читай только нужные файлы. Сделай минимальное изменение и одну целевую проверку. Сокращай логи.",
            "Обрабатывай данные локально. Изучи схему и до пяти строк. Верни агрегаты, выводы и ограничения.",
            "Ответь кратко. Используй файлы и инструменты только при необходимости."
        ];
        return task + "\n\n" + hints[profile.SelectedIndex] + " Не расширяй задачу.";
    }

    private void UpdateProgress()
    {
        if (IsDisposed || job is null) return;
        state.Text = phase + "  ·  " + elapsed.Elapsed.ToString(@"m\:ss");
    }

    private async Task Submit(bool catalogOnly)
    {
        if (job is not null) return;
        var provider = Selected;
        bool imageRequest = ImageMode && !catalogOnly;
        if (imageRequest && !provider.Gemini && !provider.Codex)
        {
            state.Text = "Для картинок выбери Google или OpenAI.";
            return;
        }
        var secret = key.Text.Trim();
        if (secret.Length == 0) { state.Text = "Вставь ключ " + provider.Key + "."; return; }
        if (!catalogOnly && (!Directory.Exists(WorkingFolder) || prompt.Text.Trim().Length == 0))
        { state.Text = "Выбери рабочую папку и введи задачу."; return; }
        var selectedEffort = effort.SelectedIndex <= 0 ? "" : effort.Text;
        var request = new AgentRequest(provider, secret, WorkingFolder, model.Text.Trim(), selectedEffort,
            plan.Checked, settings, TaskPrompt(), catalogOnly, models, selectedSession);
        if (!int.TryParse(timeout.Text, out int seconds) || seconds is < 30 or > 900)
        {
            if (!catalogOnly) { state.Text = "Укажи лимит от 30 до 900 секунд."; return; }
            seconds = 90;
        }
        var current = new CancellationTokenSource(TimeSpan.FromSeconds(catalogOnly ? 90 : seconds));
        job = current;
        phase = "Запускаю CLI…";
        elapsed.Restart();
        progressTimer.Start();
        UpdateProgress();
        generatedImagePath = null;
        IProgress<string> progress = new Progress<string>(value =>
        {
            if (!ReferenceEquals(job, current) || IsDisposed) return;
            phase = value;
            UpdateProgress();
        });
        sidebar.Enabled = run.Enabled = sessions.Enabled = profile.Enabled = false;
        stop.Visible = true;
        metrics.Text = "";
        result.Clear();
        displayed = null;
        try
        {
            if (imageRequest)
            {
                phase = ImageGeneration.Name(provider) + " создаёт картинку…";
                UpdateProgress();
                var image = await ImageGeneration.Generate(provider, request.Prompt, secret, WorkingFolder, current.Token);
                generatedImagePath = image;
                state.Text = "Картинка готова";
                Render($"## Картинка готова\n{image}\n\nДвойной щелчок по результату откроет папку с файлом.", "");
                return;
            }
            var output = await Agent.Run(request, progress.Report, current.Token);
            progressTimer.Stop();
            if (catalogOnly)
            {
                if (output.Code != 0) { Render("", output.Stderr.Replace(secret, "[ключ скрыт]")); state.Text = "Каталог не загружен."; return; }
                models.Clear();
                foreach (var line in output.Stdout.Split('\n'))
                {
                    var match = Regex.Match(line.Trim(), @"^([^\t]+)\t(.+?)(?: \((Low|Medium|High|XHigh|Max|Minimal)\))?$", RegexOptions.IgnoreCase);
                    if (match.Success) models[(match.Groups[2].Value, match.Groups[3].Value.ToLowerInvariant())] = match.Groups[1].Value;
                }
                if (models.Count > 0)
                {
                    model.Items.Clear();
                    model.Items.AddRange(models.Keys.Select(k => k.Item1).Distinct().ToArray());
                    model.Text = models.Keys.Any(k => k.Item1 == "Gemini 3.8 Flash") ? "Gemini 3.8 Flash" : models.Keys.First().Item1;
                }
                state.Text = models.Count > 0 ? "Каталог обновлён." : "Каталог пуст. Можно ввести ID вручную.";
            }
            else
            {
                var answer = Agent.Parse(provider, output, secret);
                metrics.Text = answer.Usage;
                if (answer.Success && answer.SessionId is { } id) RememberSession(provider, request.Folder, id, request.Prompt, secret);
                state.Text = answer.Success ? "Завершено" : $"Выполнение прервалось (код {output.Code}).";
                Render(answer.Answer, answer.Diagnostics);
            }
        }
        catch (OperationCanceledException) { state.Text = "Запуск остановлен."; }
        catch (Exception error) { state.Text = "Ошибка запуска."; Render("", error.Message.Replace(secret, "[ключ скрыт]")); }
        finally
        {
            job = null;
            if (!IsDisposed) progressTimer.Stop();
            elapsed.Stop();
            current.Dispose();
            if (!IsDisposed) { sidebar.Enabled = run.Enabled = profile.Enabled = true; stop.Visible = false; RefreshSessions(); }
        }
    }

    private void Render(string text, string diagnostics)
    {
        displayed = (text, diagnostics);
        result.Clear();
        bool escaped = Regex.IsMatch(text, @"(?m)^\s*(?:\\#|\\[*+-]|\d+\\\.)");
        bool code = false;
        foreach (var original in text.Replace("\r\n", "\n").Split('\n'))
        {
            string line = escaped && !code ? Regex.Replace(original, @"\\([#*_`\[\]().+!-])", "$1") : original;
            if (Regex.IsMatch(line.TrimStart(), @"^(?:```|~~~)")) { code = !code; continue; }
            if (code) { Append(line + "\n", Mono, palette.Ink); continue; }
            var heading = Regex.Match(line, @"^\s*#{1,6}\s+(.+)$");
            if (heading.Success) line = heading.Groups[1].Value;
            line = Regex.Replace(line, @"^(\s*)[-*+]\s+", "$1• ");
            var face = heading.Success ? Section : Body;
            int offset = 0;
            foreach (Match token in Regex.Matches(line, @"\*\*(.+?)\*\*|`([^`]+)`|\[([^\]]+)\]\(([^)]+)\)"))
            {
                Append(line[offset..token.Index], face, palette.Ink);
                if (token.Groups[1].Success) Append(token.Groups[1].Value, Bold, palette.Ink);
                else if (token.Groups[2].Success) Append(token.Groups[2].Value, Mono, palette.Ink);
                else Append(token.Groups[3].Value, face, palette.Accent);
                offset = token.Index + token.Length;
            }
            Append(line[offset..] + "\n", face, palette.Ink);
        }
        if (diagnostics.Length > 0)
        {
            if (text.Length > 0) Append("\nДиагностика CLI\n", Bold, palette.Muted);
            Append(diagnostics, Mono, palette.Muted);
        }
        result.Select(0, 0);
        result.ScrollToCaret();
    }

    private void Append(string value, Font font, Color color)
    {
        result.SelectionStart = result.TextLength;
        result.SelectionFont = font;
        result.SelectionColor = color;
        result.AppendText(value);
    }
}
