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
    private static readonly Color Canvas = Color.FromArgb(24, 26, 36);
    private static readonly Color Card = Color.FromArgb(36, 39, 54);
    private static readonly Color Ink = Color.FromArgb(239, 241, 249);
    private static readonly Color Muted = Color.FromArgb(170, 177, 198);
    private static readonly Color Accent = Color.FromArgb(168, 170, 255);
    private static readonly Font Body = new("Segoe UI", 10);
    private static readonly Font Title = new("Segoe UI Semibold", 20);
    private static readonly Font Section = new("Segoe UI Semibold", 12);
    private static readonly Font Bold = new("Segoe UI", 10, FontStyle.Bold);
    private static readonly Font Mono = new("Consolas", 10);

    private readonly ComboBox engine = new() { DropDownStyle = ComboBoxStyle.DropDownList };
    private readonly ComboBox model = new();
    private readonly ComboBox effort = new() { DropDownStyle = ComboBoxStyle.DropDownList };
    private readonly ComboBox profile = new() { DropDownStyle = ComboBoxStyle.DropDownList };
    private readonly TextBox key = new() { UseSystemPasswordChar = true };
    private readonly TextBox prompt = new() { Multiline = true, ScrollBars = ScrollBars.Vertical };
    private readonly TextBox scope = new() { PlaceholderText = "Файлы, границы и критерий готовности" };
    private readonly RichTextBox result = new() { ReadOnly = true, DetectUrls = false, BorderStyle = BorderStyle.None };
    private readonly Label folder = new() { AutoEllipsis = true };
    private readonly Label state = new() { AutoEllipsis = true, TextAlign = ContentAlignment.MiddleRight };
    private readonly Label metrics = new() { AutoEllipsis = true };
    private readonly CheckBox plan = new() { Text = "Только план" };
    private readonly CheckBox compact = new() { Text = "Короткий контекст", Checked = true, AutoSize = true };
    private readonly CheckBox commands = new() { Text = "Все команды" };
    private readonly CheckBox folders = new() { Text = "Все доступные папки" };
    private readonly CheckBox sandbox = new() { Text = "Команды без песочницы" };
    private readonly NumericUpDown timeout = new() { Minimum = 30, Maximum = 900, Increment = 30, Value = 180 };
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

    public AgentWindow()
    {
        Text = "PoruBot Agent";
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new(1080, 760);
        MinimumSize = new(870, 650);
        Font = Body;
        BackColor = Canvas;
        ForeColor = Ink;
        using (var stream = typeof(AgentWindow).Assembly.GetManifestResourceStream("PoruBot.ico"))
            if (stream is not null) Icon = new Icon(stream);

        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 2, Padding = new(16) };
        layout.ColumnStyles.Add(new(SizeType.Absolute, 309));
        layout.ColumnStyles.Add(new(SizeType.Percent, 100));
        layout.RowStyles.Add(new(SizeType.Absolute, 76));
        layout.RowStyles.Add(new(SizeType.Percent, 100));
        Controls.Add(layout);

        var header = new TableLayoutPanel { Dock = DockStyle.Fill, BackColor = Card, ColumnCount = 3, Padding = new(14, 0, 14, 0), Margin = new(0, 0, 0, 12) };
        header.ColumnStyles.Add(new(SizeType.Absolute, 44));
        header.ColumnStyles.Add(new(SizeType.Percent, 55));
        header.ColumnStyles.Add(new(SizeType.Percent, 45));
        var picture = new PictureBox { Image = Icon?.ToBitmap(), SizeMode = PictureBoxSizeMode.Zoom, Dock = DockStyle.Fill };
        header.Controls.Add(picture, 0, 0);
        header.Controls.Add(new Label { Text = "PoruBot Agent", Dock = DockStyle.Fill, Font = Title, TextAlign = ContentAlignment.MiddleLeft }, 1, 0);
        state.Text = "Готов к запуску";
        state.Dock = DockStyle.Fill;
        state.ForeColor = Muted;
        header.Controls.Add(state, 2, 0);
        layout.Controls.Add(header, 0, 0);
        layout.SetColumnSpan(header, 2);

        sidebar.Dock = DockStyle.Fill;
        sidebar.Margin = new(0, 0, 10, 0);
        layout.Controls.Add(sidebar, 0, 1);
        var chooseFolder = Button("▣  Выбрать папку…");
        var saveKey = Button("Сохранить ключ");
        var connection = CreateSection("Подключение");
        Add(connection, engine, key, saveKey, chooseFolder, folder);
        var launch = CreateSection("Запуск");
        Add(launch, model, catalog, new Label { Text = "Уровень Thinking", ForeColor = Muted }, effort, plan,
            new Label { Text = "Лимит задачи, секунд", ForeColor = Muted }, timeout);
        var permissions = CreateSection("Доступ агента");
        Add(permissions, commands, folders, sandbox, new Label { Text = "Настройки действуют, пока включены.", ForeColor = Muted });
        foreach (var section in new[] { connection, launch, permissions }) sidebar.Controls.Add(section);

        var workspace = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 8, Margin = new(5, 0, 0, 0) };
        foreach (var style in new[] {
            new RowStyle(SizeType.Absolute, 36), new RowStyle(SizeType.Absolute, 28),
            new RowStyle(SizeType.Absolute, 62), new RowStyle(SizeType.Absolute, 33),
            new RowStyle(SizeType.Absolute, 40), new RowStyle(SizeType.Absolute, 28),
            new RowStyle(SizeType.Absolute, 26), new RowStyle(SizeType.Percent, 100) }) workspace.RowStyles.Add(style);
        layout.Controls.Add(workspace, 1, 1);
        profile.Items.AddRange(["Код", "Данные", "Вопрос"]);
        profile.SelectedIndex = 0;
        var options = new FlowLayoutPanel { Dock = DockStyle.Fill };
        options.Controls.AddRange([profile, compact]);
        workspace.Controls.Add(options, 0, 0);
        workspace.Controls.Add(new Label { Text = "Задача", Font = Section, Dock = DockStyle.Fill }, 0, 1);
        StyleInput(prompt);
        prompt.Dock = DockStyle.Fill;
        workspace.Controls.Add(prompt, 0, 2);
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
        StyleInput(scope);
        scope.Dock = DockStyle.Fill;
        workspace.Controls.Add(scope, 0, 3);
        var buttons = new FlowLayoutPanel { FlowDirection = FlowDirection.RightToLeft, Dock = DockStyle.Fill };
        var preview = Button("Промпт");
        buttons.Controls.AddRange([run, stop, preview]);
        stop.Visible = false;
        workspace.Controls.Add(buttons, 0, 4);
        workspace.Controls.Add(new Label { Text = "Результат", Font = Section, Dock = DockStyle.Fill }, 0, 5);
        metrics.ForeColor = Muted;
        metrics.Dock = DockStyle.Fill;
        workspace.Controls.Add(metrics, 0, 6);
        result.Dock = DockStyle.Fill;
        result.BackColor = Card;
        result.ForeColor = Ink;
        result.Text = "Здесь появится ответ агента.";
        workspace.Controls.Add(result, 0, 7);

        commands.Checked = settings.AllCommands;
        folders.Checked = settings.AllFolders;
        sandbox.Checked = settings.OutsideSandbox;
        folder.Text = settings.Folder.Length > 0 ? settings.Folder : "Папка не выбрана";
        folder.Tag = settings.Folder;
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
        FormClosing += (_, _) => job?.Cancel();
    }

    private Engine Selected => (Engine)engine.SelectedItem!;
    private string WorkingFolder => folder.Tag as string ?? "";

    private static Button Button(string text, bool primary = false)
    {
        var button = new Button { Text = text, AutoSize = true, FlatStyle = FlatStyle.Flat,
            BackColor = primary ? Accent : Card, ForeColor = primary ? Canvas : Ink, MinimumSize = new(0, 28) };
        button.FlatAppearance.BorderColor = primary ? Accent : Color.FromArgb(76, 83, 106);
        return button;
    }

    private static FlowLayoutPanel CreateSection(string title)
    {
        var card = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
            WrapContents = false, BackColor = Card, Padding = new(10), Margin = new(0, 0, 0, 9) };
        card.Controls.Add(new Label { Text = title, Font = Section, ForeColor = Accent, Width = 250, Height = 26 });
        return card;
    }

    private static void StyleInput(Control control)
    {
        control.BackColor = Card;
        control.ForeColor = Ink;
    }

    private static void Add(FlowLayoutPanel section, params Control[] controls)
    {
        foreach (var control in controls)
        {
            control.Width = 250;
            control.Margin = new(0, 0, 0, 4);
            StyleInput(control);
            if (control is Label or CheckBox) control.Height = 22;
            section.Controls.Add(control);
        }
    }

    private void ChangeEngine()
    {
        if (previous is not null) keys[previous] = key.Text;
        var selected = Selected;
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
        catalog.Visible = selected.Gemini;
        UpdateAccess();
    }

    private void UpdateAccess()
    {
        commands.Enabled = sandbox.Enabled = Selected.Gemini && !plan.Checked;
        folders.Enabled = !plan.Checked;
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
        settings = new(commands.Checked, folders.Checked, sandbox.Checked, WorkingFolder);
        try { settings.Save(); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        { state.Text = "Не удалось сохранить настройки."; }
    }

    private string TaskPrompt()
    {
        string task = prompt.Text.Trim();
        if (scope.Text.Trim().Length > 0) task += "\n\nГраницы задачи и критерий готовности:\n" + scope.Text.Trim();
        if (!compact.Checked) return task;
        string[] hints = [
            "Читай только нужные файлы. Сделай минимальное изменение и одну целевую проверку. Сокращай логи.",
            "Обрабатывай данные локально. Изучи схему и до пяти строк. Верни агрегаты, выводы и ограничения.",
            "Ответь кратко. Используй файлы и инструменты только при необходимости."
        ];
        return task + "\n\n" + hints[profile.SelectedIndex] + " Не расширяй задачу.";
    }

    private async Task Submit(bool catalogOnly)
    {
        if (job is not null) return;
        var provider = Selected;
        var secret = key.Text.Trim();
        if (secret.Length == 0) { state.Text = "Вставь ключ " + provider.Key + "."; return; }
        if (!catalogOnly && (!Directory.Exists(WorkingFolder) || prompt.Text.Trim().Length == 0))
        { state.Text = "Выбери рабочую папку и введи задачу."; return; }
        var selectedEffort = effort.SelectedIndex <= 0 ? "" : effort.Text;
        var request = new AgentRequest(provider, secret, WorkingFolder, model.Text.Trim(), selectedEffort,
            plan.Checked, settings, TaskPrompt(), catalogOnly, models);
        var current = new CancellationTokenSource(TimeSpan.FromSeconds(catalogOnly ? 90 : (double)timeout.Value));
        job = current;
        sidebar.Enabled = run.Enabled = false;
        stop.Visible = true;
        metrics.Text = "";
        result.Clear();
        try
        {
            var output = await Agent.Run(request, status => state.Text = status, current.Token);
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
                state.Text = answer.Success ? "Завершено" : $"Выполнение прервалось (код {output.Code}).";
                Render(answer.Answer, answer.Diagnostics);
            }
        }
        catch (OperationCanceledException) { state.Text = "Запуск остановлен."; }
        catch (Exception error) { state.Text = "Ошибка запуска."; Render("", error.Message.Replace(secret, "[ключ скрыт]")); }
        finally
        {
            job = null;
            current.Dispose();
            if (!IsDisposed) { sidebar.Enabled = run.Enabled = true; stop.Visible = false; }
        }
    }

    private void Render(string text, string diagnostics)
    {
        result.Clear();
        bool escaped = Regex.IsMatch(text, @"(?m)^\s*(?:\\#|\\[*+-]|\d+\\\.)");
        bool code = false;
        foreach (var original in text.Replace("\r\n", "\n").Split('\n'))
        {
            string line = escaped && !code ? Regex.Replace(original, @"\\([#*_`\[\]().+!-])", "$1") : original;
            if (Regex.IsMatch(line.TrimStart(), @"^(?:```|~~~)")) { code = !code; continue; }
            if (code) { Append(line + "\n", Mono, Ink); continue; }
            var heading = Regex.Match(line, @"^\s*#{1,6}\s+(.+)$");
            if (heading.Success) line = heading.Groups[1].Value;
            line = Regex.Replace(line, @"^(\s*)[-*+]\s+", "$1• ");
            var face = heading.Success ? Section : Body;
            int offset = 0;
            foreach (Match token in Regex.Matches(line, @"\*\*(.+?)\*\*|`([^`]+)`|\[([^\]]+)\]\(([^)]+)\)"))
            {
                Append(line[offset..token.Index], face, Ink);
                if (token.Groups[1].Success) Append(token.Groups[1].Value, Bold, Ink);
                else if (token.Groups[2].Success) Append(token.Groups[2].Value, Mono, Ink);
                else Append(token.Groups[3].Value, face, Accent);
                offset = token.Index + token.Length;
            }
            Append(line[offset..] + "\n", face, Ink);
        }
        if (diagnostics.Length > 0)
        {
            if (text.Length > 0) Append("\nДиагностика CLI\n", Bold, Muted);
            Append(diagnostics, Mono, Muted);
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
