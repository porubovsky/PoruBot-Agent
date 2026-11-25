using static L10n;
using System.Text.RegularExpressions;

static class L10n
{
    public static bool IsEnglish { get; set; }
    public static string T(string russian, string english) => IsEnglish ? english : russian;
}

static class Program
{
    [STAThread]
    static void Main()
    {
        ApplicationConfiguration.Initialize();
        var settings = Settings.Read();
        L10n.IsEnglish = settings.Language == "en";
        Application.Run(new AgentWindow(settings));
    }
}

sealed class AgentWindow : Form
{
    private Palette palette = Palette.Resolve("system");
    private static readonly Font Body = new("Segoe UI", 11);
    private static readonly Font Title = new("Segoe UI Semibold", 23);
    private static readonly Font Section = new("Segoe UI Semibold", 13);
    private static readonly Font Bold = new("Segoe UI", 11, FontStyle.Bold);
    private static readonly Font Mono = new("Consolas", 11);

    private readonly ThemeChoice engine = new() { AccessibleName = T("Движок", "Engine") };
    private readonly ThemeChoice model = new(true) { AccessibleName = T("Модель", "Model") };
    private readonly ThemeChoice effort = new() { AccessibleName = T("Уровень Thinking", "Thinking level") };
    private readonly ThemeChoice modeChoice = new() { AccessibleName = T("Режим", "Mode") };
    private readonly ThemeChoice profile = new() { AccessibleName = T("Режим работы", "Task mode") };
    private readonly Button preview = Button(T("Промпт", "Prompt"));
    private string? editedPrompt;
    private readonly Button template = Button(T("Шаблон…", "Template…"));
    private readonly RowStyle detailsRow = new(SizeType.Absolute, 46);
    private readonly ThemeChoice theme = new() { AccessibleName = T("Цветовая тема", "Color theme") };
    private readonly ThemeChoice signIn = new() { AccessibleName = T("Вход", "Sign-in") };
    private readonly Button accountHelp = Button(T("Как войти…", "How to sign in…"));
    private readonly Button saveKey = Button(T("Сохранить ключ", "Save key"));
    private readonly TextBox key = new() { UseSystemPasswordChar = true };
    private readonly TextBox prompt = new() { Multiline = true, AcceptsReturn = true };
    private string? imageReference;
    private readonly FlowLayoutPanel referenceRow = new() { Dock = DockStyle.Fill, WrapContents = false };
    private readonly ReadableLabel referenceName = new() { AutoEllipsis = true, TextAlign = ContentAlignment.MiddleLeft };
    private readonly Button chooseReference = Button(T("Добавить образец…", "Add reference…"));
    private readonly Button clearReference = Button(T("Убрать", "Remove"));
    private readonly TextBox scope = new() { PlaceholderText = T("Файлы, границы и критерий готовности", "Files, scope, and completion criteria") };
    private readonly RichTextBox result = new() { ReadOnly = true, DetectUrls = false, BorderStyle = BorderStyle.None };
    private readonly ReadableLabel folder = new() { AutoEllipsis = true };
    private readonly ReadableLabel state = new() { AutoEllipsis = true, TextAlign = ContentAlignment.MiddleRight };
    private readonly RichTextBox activityView = new() { ReadOnly = true, TabStop = false, DetectUrls = false };
    private readonly Queue<string> activity = new();
    private string? lastActivity;
    private readonly ReadableLabel metrics = new() { AutoEllipsis = true };
    private readonly ModernSwitch plan = new() { Text = T("Только план", "Plan only") };
    private readonly ThemeChoice sessions = new() { AccessibleName = T("Разговор", "Conversation"), Width = 250 };
    private bool updatingSessions;
    private string? selectedSession;
    private readonly ReadableLabel taskHeading = new() { Text = T("Задача", "Task"), Dock = DockStyle.Fill };
    private string? generatedImagePath;
    private readonly ModernSwitch commands = new() { Text = T("Все команды", "All commands") };
    private readonly ModernSwitch folders = new() { Text = T("Все доступные папки", "All accessible folders") };
    private readonly ModernSwitch sandbox = new() { Text = T("Команды без песочницы", "Commands outside sandbox") };
    private readonly ThemeChoice timeout = new(true) { AccessibleName = T("Лимит задачи в секундах", "Task time limit in seconds") };
    private readonly Button run = Button(T("▶  Запустить", "▶  Run"), true);
    private readonly Button repeat = Button(T("↻  Повторить", "↻  Repeat"));
    private (AgentRequest Request, bool Image, int Seconds, string? Reference)? lastRun;
    private readonly Button stop = Button(T("■  Остановить", "■  Stop"));
    private readonly Button catalog = Button(T("Загрузить модели", "Load models"));
    private readonly FlowLayoutPanel sidebar = new() { FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoScroll = true };
    private readonly Dictionary<Engine, string> keys = new();
    private readonly Dictionary<(string, string), string> models = new();
    private Settings settings;
    private CancellationTokenSource? job;
    private CancellationTokenSource? pricing;
    private Engine? previous;
    private bool updatingAccess;
    private (string Answer, string Diagnostics)? displayed;
    private bool themeReady;
    private readonly System.Windows.Forms.Timer progressTimer = new() { Interval = 1000 };
    private readonly System.Diagnostics.Stopwatch elapsed = new();
    private string phase = "";
    private string ThemeMode => theme.SelectedIndex switch { 1 => "light", 2 => "dark", _ => "system" };

    public AgentWindow(Settings initialSettings)
    {
        settings = initialSettings;
        Text = "PoruBot Agent";
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new(1160, 800);
        MinimumSize = new(870, 650);
        AutoScaleMode = AutoScaleMode.Dpi;
        Font = Body;
        prompt.AccessibleName = T("Задача", "Task");
        result.AccessibleName = T("Результат", "Result");
        using (var stream = typeof(AgentWindow).Assembly.GetManifestResourceStream("PoruBot.ico"))
            if (stream is not null) Icon = new Icon(stream);

        var layout = new BufferedLayout { Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 2, Padding = new(16) };
        layout.ColumnStyles.Add(new(SizeType.Absolute, 350));
        layout.ColumnStyles.Add(new(SizeType.Percent, 100));
        layout.RowStyles.Add(new(SizeType.Absolute, 81));
        layout.RowStyles.Add(new(SizeType.Percent, 100));
        Controls.Add(layout);

        var header = new BufferedLayout { Dock = DockStyle.Fill, Name = "card", ColumnCount = 5, Padding = new(14, 0, 14, 0), Margin = new(0, 0, 0, 12) };
        header.ColumnStyles.Add(new(SizeType.Absolute, 44));
        header.ColumnStyles.Add(new(SizeType.Percent, 55));
        header.ColumnStyles.Add(new(SizeType.Percent, 45));
        header.ColumnStyles.Add(new(SizeType.Absolute, 162));
        header.ColumnStyles.Add(new(SizeType.Absolute, 122));
        var picture = new PictureBox { Image = Icon?.ToBitmap(), SizeMode = PictureBoxSizeMode.Zoom, Dock = DockStyle.Fill };
        header.Controls.Add(picture, 0, 0);
        header.Controls.Add(new ReadableLabel { Text = "PoruBot Agent", Dock = DockStyle.Fill, Font = Title, TextAlign = ContentAlignment.MiddleLeft }, 1, 0);
        state.Text = T("Готов к запуску", "Ready");
        state.Dock = DockStyle.Fill;
        state.Name = "muted";
        header.Controls.Add(state, 2, 0);
        theme.Items.AddRange([T("Как в Windows", "Windows theme"), T("Светлая", "Light"), T("Тёмная", "Dark")]);
        theme.SelectedIndex = settings.Theme switch { "light" => 1, "dark" => 2, _ => 0 };
        theme.Dock = DockStyle.Top;
        theme.Margin = new(8, 15, 0, 0);
        header.Controls.Add(theme, 3, 0);
        var language = new ThemeChoice { AccessibleName = T("Язык", "Language"), Dock = DockStyle.Top,
            Margin = new(8, 15, 0, 0) };
        language.Items.AddRange(["Русский", "English"]);
        language.SelectedIndex = L10n.IsEnglish ? 1 : 0;
        header.Controls.Add(language, 4, 0);
        language.SelectedIndexChanged += (_, _) => ChangeLanguage(language.SelectedIndex == 1 ? "en" : "ru");
        layout.Controls.Add(header, 0, 0);
        layout.SetColumnSpan(header, 2);

        sidebar.Dock = DockStyle.Fill;
        sidebar.Margin = new(0, 0, 10, 0);
        layout.Controls.Add(sidebar, 0, 1);
        var chooseFolder = Button(T("▣  Выбрать папку…", "▣  Choose folder…"));
        signIn.Items.AddRange(["API key", T("Аккаунт CLI", "CLI account")]);
        signIn.SelectedIndex = settings.UseCliAccount ? 1 : 0;
        var connection = CreateSection(T("Подключение", "Connection"));
        Add(connection, engine, signIn, new FieldFrame(key) { Height = 35 }, saveKey, accountHelp, chooseFolder, folder);
        signIn.SelectedIndexChanged += (_, _) =>
        {
            lastRun = null;
            repeat.Enabled = false;
            selectedSession = null;
            models.Clear();
            model.Text = "";
            effort.SelectedIndex = 0;
            UpdateAccess();
            SaveAccess();
        };
        accountHelp.Click += (_, _) => ShowAccountHelp();
        var launch = CreateSection(T("Запуск", "Run settings"));
        timeout.Items.AddRange(["60", "120", "180", "300", "600", "900"]);
        timeout.SelectedIndex = 2;
        Add(launch, model, catalog, new ReadableLabel { Text = T("Уровень Thinking", "Thinking level"), Name = "muted" }, effort, plan,
            new ReadableLabel { Text = T("Лимит задачи, секунд", "Time limit, seconds"), Name = "muted" }, timeout);
        var permissions = CreateSection(T("Доступ агента", "Agent access"));
        Add(permissions, commands, folders, sandbox, new ReadableLabel { Text = T("Настройки действуют, пока включены.", "Settings apply while enabled."), Name = "muted" });
        foreach (var section in new[] { connection, launch, permissions }) sidebar.Controls.Add(section);

        var workspace = new BufferedLayout { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 10, Margin = new(5, 0, 0, 0) };
        foreach (var style in new[] {
            new RowStyle(SizeType.Absolute, 47), new RowStyle(SizeType.Absolute, 44),
            new RowStyle(SizeType.Absolute, 64), detailsRow,
            new RowStyle(SizeType.Absolute, 47), new RowStyle(SizeType.Absolute, 36),
            new RowStyle(SizeType.Absolute, 0), new RowStyle(SizeType.Absolute, 34),
            new RowStyle(SizeType.Absolute, 26), new RowStyle(SizeType.Percent, 100) }) workspace.RowStyles.Add(style);
        layout.Controls.Add(workspace, 1, 1);
        modeChoice.Items.AddRange([T("Агент", "Agent"), T("Картинка", "Image")]);
        modeChoice.SelectedIndex = 0;
        profile.Items.AddRange([T("Свободный", "Freeform"), T("Код", "Code"), T("Данные", "Data"), T("Вопрос", "Question")]);
        profile.SelectedIndex = 0;
        var options = new FlowLayoutPanel { Dock = DockStyle.Fill };
        options.Controls.AddRange([modeChoice, profile, template]);
        workspace.Controls.Add(options, 0, 0);
        taskHeading.Font = Section;
        var taskBar = new BufferedLayout { Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 1 };
        taskBar.ColumnStyles.Add(new(SizeType.Percent, 100));
        taskBar.ColumnStyles.Add(new(SizeType.AutoSize));
        taskHeading.TextAlign = ContentAlignment.MiddleLeft;
        taskHeading.AutoEllipsis = true;
        sessions.Anchor = AnchorStyles.Right;
        taskBar.Controls.Add(taskHeading, 0, 0);
        taskBar.Controls.Add(sessions, 1, 0);
        workspace.Controls.Add(taskBar, 0, 1);
        sessions.SelectedIndexChanged += (_, _) => SelectSession();
        workspace.Controls.Add(new FieldFrame(prompt) { Dock = DockStyle.Fill }, 0, 2);
        void SizePrompt()
        {
            int minHeight = LogicalToDeviceUnits(64);
            int maxHeight = Math.Max(minHeight, Math.Min(LogicalToDeviceUnits(210), workspace.ClientSize.Height / 3));
            var availableWidth = Math.Max(LogicalToDeviceUnits(80), workspace.ClientSize.Width - LogicalToDeviceUnits(26));
            int measured = TextRenderer.MeasureText(prompt.Text + "\n ", prompt.Font, new Size(availableWidth, 4096),
                TextFormatFlags.TextBoxControl | TextFormatFlags.WordBreak | TextFormatFlags.NoPadding).Height;
            float height = Math.Clamp(measured + LogicalToDeviceUnits(22), minHeight, maxHeight);
            if (workspace.RowStyles[2].Height != height) workspace.RowStyles[2].Height = height;
        }
        prompt.TextChanged += (_, _) => SizePrompt();
        workspace.Resize += (_, _) => SizePrompt();
        var scopeFrame = new FieldFrame(scope) { Dock = DockStyle.Fill };
        var taskDetails = new Panel { Dock = DockStyle.Fill };
        referenceName.Size = new(200, 36);
        referenceRow.Controls.AddRange([chooseReference, referenceName, clearReference]);
        taskDetails.Controls.AddRange([scopeFrame, referenceRow]);
        workspace.Controls.Add(taskDetails, 0, 3);
        chooseReference.Click += (_, _) =>
        {
            using var dialog = new OpenFileDialog { Title = T("Выбрать изображение-образец", "Choose a reference image"),
                Filter = T("Изображения PNG, JPEG, WebP|*.png;*.jpg;*.jpeg;*.webp", "PNG, JPEG, WebP images|*.png;*.jpg;*.jpeg;*.webp") };
            if (dialog.ShowDialog(this) == DialogResult.OK) SetImageReference(dialog.FileName);
        };
        clearReference.Click += (_, _) => SetImageReference(null);
        SetImageReference(null);
        referenceRow.Visible = false;
        var buttons = new FlowLayoutPanel { FlowDirection = FlowDirection.RightToLeft, Dock = DockStyle.Fill };
        buttons.Controls.AddRange([run, stop, repeat, preview]);
        stop.Visible = false;
        repeat.Enabled = false;
        workspace.Controls.Add(buttons, 0, 4);
        var activityToggle = new ModernSwitch { Text = T("Ход работы", "Activity"), Width = 160, Anchor = AnchorStyles.Left };
        var activityFrame = new FieldFrame(activityView) { Dock = DockStyle.Fill, Visible = false };
        workspace.Controls.Add(activityToggle, 0, 5);
        workspace.Controls.Add(activityFrame, 0, 6);
        activityToggle.CheckedChanged += (_, _) =>
        {
            workspace.RowStyles[6].Height = activityToggle.Checked ? LogicalToDeviceUnits(126) : 0;
            activityFrame.Visible = activityToggle.Checked;
            if (activityToggle.Checked) ShowActivity();
        };
        workspace.Controls.Add(new ReadableLabel { Text = T("Результат", "Result"), Font = Section, Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleLeft }, 0, 7);
        metrics.Name = "muted";
        metrics.Dock = DockStyle.Fill;
        workspace.Controls.Add(metrics, 0, 8);
        result.Text = T("Здесь появится ответ агента.", "The agent's response will appear here.");
        result.TabStop = false;
        workspace.Controls.Add(new FieldFrame(result, 12) { Dock = DockStyle.Fill }, 0, 9);

        commands.Checked = settings.AllCommands;
        folders.Checked = settings.AllFolders;
        sandbox.Checked = settings.OutsideSandbox;
        folder.Text = settings.Folder.Length > 0 ? settings.Folder : T("Папка не выбрана", "No folder selected");
        folder.Tag = settings.Folder;
        engine.DisplayLabel = item => ImageMode && item is Engine provider
            ? provider.Gemini ? "Google" : "OpenAI"
            : item.ToString() ?? "";
        engine.Items.AddRange(Engine.All);
        engine.SelectedIndexChanged += (_, _) => ChangeEngine();
        engine.SelectedIndex = 0;
        plan.CheckedChanged += (_, _) => UpdateAccess();
        commands.CheckedChanged += (_, _) => SaveAccess();
        folders.CheckedChanged += (_, _) => Confirm(folders, T("Агент сможет работать за пределами выбранной папки на доступных локальных дисках.", "The agent can work outside the selected folder on accessible local drives."));
        sandbox.CheckedChanged += (_, _) => Confirm(sandbox, T("Разрешённые команды Antigravity смогут работать с файлами и сетью вне песочницы.", "Allowed Antigravity commands can access files and the network outside the sandbox."));
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
            if (key.Text.Trim().Length == 0) { state.Text = T("Вставь API-ключ.", "Enter an API key."); return; }
            try { Settings.SaveKey(Selected, key.Text.Trim()); state.Text = T("Ключ сохранён для твоего профиля Windows.", "Key saved for your Windows profile."); }
            catch (Exception e) when (e is IOException or System.Security.Cryptography.CryptographicException or UnauthorizedAccessException)
            { state.Text = T("Не удалось сохранить ключ.", "Could not save the key."); }
        };
        run.Click += async (_, _) => await Submit(false);
        catalog.Click += async (_, _) => await Submit(true);
        stop.Click += (_, _) =>
        {
            phase = T("Останавливаю…", "Stopping…");
            UpdateProgress();
            stop.Enabled = false;
            job?.Cancel();
        };
        repeat.Click += async (_, _) =>
        {
            if (job is not null || lastRun is not { } previous) return;
            var old = previous.Request.Access;
            if ((old.AllCommands && !settings.AllCommands) || (old.AllFolders && !settings.AllFolders) ||
                (old.OutsideSandbox && !settings.OutsideSandbox))
            {
                state.Text = T("Доступ агента изменился. Запусти задачу с текущими настройками.", "Agent access has changed. Run the task with the current settings.");
                return;
            }
            var provider = previous.Request.Engine;
            var secret = previous.Request.Account ? "" : (Selected == provider ? key.Text : keys.GetValueOrDefault(provider) ?? "").Trim();
            if (!previous.Request.Account && secret.Length == 0) { state.Text = T("Вставь ключ ", "Enter the key for ") + provider.Key + "."; return; }
            await Execute(previous.Request with { Key = secret }, previous.Image, previous.Seconds, previous.Reference);
        };
        preview.Click += (_, _) => EditPrompt(false);
        template.Click += (_, _) => EditPrompt(true);
        prompt.TextChanged += (_, _) => SetEditedPrompt(null);
        scope.TextChanged += (_, _) => SetEditedPrompt(null);
        profile.SelectedIndexChanged += (_, _) => { SetEditedPrompt(null); UpdateAccess(); };
        modeChoice.SelectedIndexChanged += (_, _) =>
        {
            SetEditedPrompt(null);
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
    private bool AccountMode => !ImageMode && !Selected.Router && signIn.SelectedIndex == 1;
    private bool ImageMode => modeChoice.SelectedIndex == 1;
    private string WorkingFolder => folder.Tag as string ?? "";

    private static Button Button(string text, bool primary = false) => new ModernButton(text, primary);

    private static FlowLayoutPanel CreateSection(string title)
    {
        var card = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
            WrapContents = false, Name = "card", Padding = new(13), Margin = new(0, 0, 0, 10) };
        card.Controls.Add(new ReadableLabel { Text = title, Font = Section, Name = "accent", Width = 286, Height = 30 });
        return card;
    }

    private static void Add(FlowLayoutPanel section, params Control[] controls)
    {
        foreach (var control in controls)
        {
            control.Width = 286;
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
            { key.Clear(); state.Text = T("Не удалось прочитать сохранённый ключ.", "Could not load the saved key."); }
        }
        model.Items.Clear();
        model.Items.AddRange(selected.Models);
        model.SelectedIndex = AccountMode ? -1 : 0;
        effort.Items.Clear();
        effort.Items.AddRange(selected.Codex ? [T("По умолчанию", "Default"), "minimal", "low", "medium", "high", "xhigh"]
            : [T("По умолчанию", "Default"), "low", "medium", "high", "xhigh", "max"]);
        effort.SelectedIndex = selected.Gemini && !AccountMode ? 1 : 0;
        UpdateAccess();
    }

    private void SetImageReference(string? path)
    {
        imageReference = path;
        referenceName.Text = path is null ? T("PNG, JPEG, WebP · до 10 МБ", "PNG, JPEG, WebP · up to 10 MB") : Path.GetFileName(path);
        chooseReference.Text = path is null ? T("Добавить образец…", "Add reference…") : T("Заменить образец…", "Replace reference…");
        clearReference.Visible = path is not null;
    }

    private void UpdateAccess()
    {
        signIn.Visible = !ImageMode && !Selected.Router;
        key.Parent!.Visible = saveKey.Visible = !AccountMode;
        accountHelp.Visible = AccountMode;
        profile.Visible = !ImageMode;
        template.Visible = !ImageMode && profile.SelectedIndex > 0;
        scope.Parent!.Visible = !ImageMode && profile.SelectedIndex > 0;
        referenceRow.Visible = ImageMode;
        detailsRow.Height = ImageMode || profile.SelectedIndex > 0 ? LogicalToDeviceUnits(46) : 0;
        catalog.Visible = Selected.Gemini && !ImageMode;
        model.Enabled = effort.Enabled = plan.Enabled = !ImageMode;
        taskHeading.Text = ImageMode ? T("Описание картинки · ", "Image prompt · ") + ImageGeneration.Name(Selected) : T("Задача", "Task");
        commands.Enabled = sandbox.Enabled = !ImageMode && Selected.Gemini && !plan.Checked;
        folders.Enabled = !ImageMode && !plan.Checked;
        RefreshSessions();
    }

    private void RefreshSessions()
    {
        bool supportsSessions = !ImageMode && (Selected.Gemini || Selected.Codex);
        sessions.Visible = supportsSessions;
        sessions.Enabled = job is null && Directory.Exists(WorkingFolder);
        if (!supportsSessions) return;
        updatingSessions = true;
        try
        {
            sessions.Items.Clear();
            sessions.Items.Add(T("Новый разговор", "New conversation"));
            sessions.Items.AddRange((settings.Sessions ?? []).Where(item => item.Engine == Selected.Name &&
                string.Equals(item.Folder, WorkingFolder, StringComparison.OrdinalIgnoreCase)));
            var index = sessions.Items.FindIndex(item => item is SavedSession session && session.Id == selectedSession);
            if (selectedSession is not null && index < 0)
            {
                index = sessions.Items.Count;
                sessions.Items.Add(new SavedSession(selectedSession, Selected.Name, WorkingFolder, T("Разговор по ID", "Conversation by ID")));
            }
            sessions.Items.Add(T("Открыть по ID…", "Open by ID…"));
            sessions.SelectedIndex = Math.Max(0, index);
        }
        finally { updatingSessions = false; }
    }

    private void SelectSession()
    {
        if (updatingSessions) return;
        if (sessions.SelectedItem is SavedSession item) { selectedSession = item.Id; return; }
        if (sessions.SelectedIndex == 0) { selectedSession = null; return; }
        using var dialog = new Form { Text = T("Продолжить разговор по ID", "Resume conversation by ID"), ClientSize = new(390, 94),
            FormBorderStyle = FormBorderStyle.FixedDialog, StartPosition = FormStartPosition.CenterParent,
            MinimizeBox = false, MaximizeBox = false, Font = Font };
        var field = new TextBox { PlaceholderText = T("UUID сессии из CLI", "Session UUID from CLI"), Bounds = new(12, 14, 365, 31) };
        var confirm = new Button { Text = T("Выбрать", "Choose"), DialogResult = DialogResult.OK, Enabled = false,
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
        var title = prompt.Split('\n', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? T("Разговор", "Conversation");
        if (key.Length > 0) title = title.Replace(key, T("[ключ скрыт]", "[key redacted]"));
        all.Insert(0, existing ?? new SavedSession(id, provider.Name, directory, title[..Math.Min(84, title.Length)]));
        settings = settings with { Sessions = all.Take(200).ToArray() };
        selectedSession = id;
        SaveAccess();
    }

    private void Confirm(CheckBox option, string message)
    {
        if (updatingAccess) return;
        if (option.Checked && MessageBox.Show(this, message + T("\n\nНастройка сохранится для следующих задач.", "\n\nThis setting applies to future tasks."),
                T("Доступ агента", "Agent access"), MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2) != DialogResult.Yes)
        {
            updatingAccess = true;
            option.Checked = false;
            updatingAccess = false;
        }
        SaveAccess();
    }

    private void ShowAccountHelp()
    {
        var command = Selected.AccountCommand;
        var message = T("Выполни в терминале: ", "Run in a terminal: ") + command
            + T("\nЗаверши вход у провайдера и вернись в PoruBot.\n\nСкопировать команду?",
                "\nComplete sign-in with the provider, then return to PoruBot.\n\nCopy the command?");
        if (Selected.Gemini)
            message += T("\nДля agy убери modelProvider: gemini из настроек CLI, если он задан.",
                "\nFor agy, remove modelProvider: gemini from CLI settings if set.");
        if (MessageBox.Show(this, message, T("Вход в CLI", "Sign in to the CLI"),
            MessageBoxButtons.YesNo, MessageBoxIcon.Information) == DialogResult.Yes)
        {
            try { Clipboard.SetText(command); }
            catch (System.Runtime.InteropServices.ExternalException)
            { state.Text = T("Не удалось скопировать команду.", "Could not copy the command."); }
        }
    }

    private void ChangeLanguage(string language)
    {
        var updated = settings with { Language = language };
        try
        {
            updated.Save();
            settings = updated;
            if ((language == "en") != L10n.IsEnglish)
                MessageBox.Show(this, T("Новый язык включится при следующем запуске PoruBot.", "The new language will take effect the next time you open PoruBot."),
                    T("Язык интерфейса", "Interface language"));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        { state.Text = T("Не удалось сохранить настройки.", "Could not save settings."); }
    }

    private void SaveAccess()
    {
        settings = new(commands.Checked, folders.Checked, sandbox.Checked, WorkingFolder, ThemeMode, settings.Sessions, settings.Language, signIn.SelectedIndex == 1, settings.PromptTemplates);
        try { settings.Save(); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        { state.Text = T("Не удалось сохранить настройки.", "Could not save settings."); }
    }

    private string TaskPrompt() => editedPrompt ?? GeneratedPrompt();

    private string TemplateID => profile.SelectedIndex switch
    {
        1 => "code",
        2 => "data",
        3 => "question",
        _ => "free"
    };

    private string DefaultTemplate()
    {
        var guidance = profile.SelectedIndex switch
        {
            1 => T("Читай только нужные файлы. Сделай минимальное изменение и одну целевую проверку. Сокращай логи.", "Read only the files you need. Make the smallest change and run one focused check. Keep logs short."),
            2 => T("Обрабатывай данные локально. Изучи схему и до пяти строк. Верни агрегаты, выводы и ограничения.", "Analyze data locally. Inspect the schema and up to five rows. Return aggregates, findings, and limitations."),
            3 => T("Ответь кратко. Используй файлы и инструменты только при необходимости.", "Give a brief answer. Use files and tools only when needed."),
            _ => ""
        };
        return guidance + T(" Не расширяй задачу.", " Stay within scope.");
    }

    private string ActiveTemplate() => settings.PromptTemplates?.GetValueOrDefault(TemplateID) ?? DefaultTemplate();

    private string GeneratedPrompt()
    {
        if (ImageMode || profile.SelectedIndex <= 0) return prompt.Text;
        var focus = scope.Text.Trim();
        var constraints = focus.Length == 0 ? "" : T("Границы задачи и критерий готовности:\n", "Scope and completion criteria:\n") + focus;
        return string.Join("\n\n", new[] { prompt.Text, constraints, ActiveTemplate() }.Where(value => !string.IsNullOrWhiteSpace(value)));
    }

    private void SaveTemplate(string templateText)
    {
        var templates = new Dictionary<string, string>(settings.PromptTemplates ?? []);
        if (templateText == DefaultTemplate()) templates.Remove(TemplateID);
        else templates[TemplateID] = templateText;
        var updated = settings with { PromptTemplates = templates };
        try
        {
            updated.Save();
            settings = updated;
            SetEditedPrompt(null);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        { state.Text = T("Не удалось сохранить настройки.", "Could not save settings."); }
    }

    private void SetEditedPrompt(string? text)
    {
        editedPrompt = text;
        preview.Text = text is null ? T("Промпт", "Prompt") : T("Промпт изменён", "Prompt edited");
    }

    private void EditPrompt(bool editTemplate)
    {
        using var dialog = new Form
        {
            Text = editTemplate ? T("Шаблон режима", "Mode template") : T("Текст для отправки", "Text to send"), Font = Body, ClientSize = new(680, 420),
            MinimumSize = new(480, 300), StartPosition = FormStartPosition.CenterParent,
            BackColor = palette.Canvas, ForeColor = palette.Ink, ShowInTaskbar = false
        };
        var editor = new TextBox
        {
            Multiline = true, AcceptsReturn = true, AcceptsTab = true, ScrollBars = ScrollBars.Vertical,
            Text = editTemplate ? ActiveTemplate() : TaskPrompt(), AccessibleName = T("Текст промпта", "Prompt text")
        };
        var frame = new FieldFrame(editor) { Dock = DockStyle.Fill };
        frame.Apply(palette);
        var actions = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 48, FlowDirection = FlowDirection.RightToLeft };
        var apply = Button(T("Применить", "Apply"), true);
        var cancel = Button(T("Отмена", "Cancel"));
        var reset = Button(T("Восстановить исходный текст", "Restore original text"));
        apply.DialogResult = DialogResult.OK;
        cancel.DialogResult = DialogResult.Cancel;
        reset.Click += (_, _) => editor.Text = editTemplate ? DefaultTemplate() : GeneratedPrompt();
        foreach (var button in new[] { apply, cancel, reset })
        {
            ((IThemed)button).Apply(palette);
            actions.Controls.Add(button);
        }
        dialog.Controls.Add(frame);
        dialog.Controls.Add(actions);
        dialog.CancelButton = cancel;
        dialog.Shown += (_, _) => palette.ApplyCaption(dialog.Handle);
        if (dialog.ShowDialog(this) != DialogResult.OK) return;
        if (editTemplate) SaveTemplate(editor.Text);
        else SetEditedPrompt(editor.Text == GeneratedPrompt() ? null : editor.Text);
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
            state.Text = T("Для картинок выбери Google или OpenAI.", "Choose Google or OpenAI for images.");
            return;
        }
        bool account = AccountMode;
        var secret = account ? "" : key.Text.Trim();
        if (!account && secret.Length == 0) { state.Text = T("Вставь ключ ", "Enter the key for ") + provider.Key + "."; return; }
        var outgoing = TaskPrompt();
        if (!catalogOnly && (!Directory.Exists(WorkingFolder) || string.IsNullOrWhiteSpace(editedPrompt ?? prompt.Text)))
        { state.Text = T("Выбери рабочую папку и введи задачу.", "Choose a working folder and enter a task."); return; }
        var selectedEffort = effort.SelectedIndex <= 0 ? "" : effort.Text;
        var request = new AgentRequest(provider, secret, WorkingFolder, model.Text.Trim(), selectedEffort,
            plan.Checked, settings, outgoing, catalogOnly, models, selectedSession, account);
        if (!int.TryParse(timeout.Text, out int seconds) || seconds is < 30 or > 900)
        {
            if (!catalogOnly) { state.Text = T("Укажи лимит от 30 до 900 секунд.", "Enter a time limit between 30 and 900 seconds."); return; }
            seconds = 90;
        }
        var reference = imageRequest ? imageReference : null;
        if (!catalogOnly)
            lastRun = (request with { Key = "", Models = new Dictionary<(string, string), string>(models) }, imageRequest, seconds, reference);
        await Execute(request, imageRequest, seconds, reference);
    }

    private void RecordActivity(string message)
    {
        if (message == lastActivity) return;
        lastActivity = message;
        if (activity.Count >= 100) activity.Dequeue();
        activity.Enqueue(elapsed.Elapsed.ToString(@"m\:ss") + "  ·  " + message);
        if (activityView.Visible) ShowActivity();
    }

    private void ShowActivity()
    {
        activityView.Text = activity.Count == 0
            ? T("Здесь появятся этапы обработки запроса.", "Progress will appear here when you run a task.")
            : string.Join(Environment.NewLine, activity);
        activityView.SelectionStart = activityView.TextLength;
        activityView.ScrollToCaret();
    }

    private async Task Execute(AgentRequest request, bool imageRequest, int seconds, string? reference)
    {
        var provider = request.Engine;
        var secret = request.Key;
        string Redact(string value) => secret.Length == 0 ? value : value.Replace(secret, T("[ключ скрыт]", "[key redacted]"));
        bool catalogOnly = request.Catalog;
        var current = new CancellationTokenSource(TimeSpan.FromSeconds(catalogOnly ? 90 : seconds));
        job = current;
        pricing?.Cancel();
        phase = T("Запускаю CLI…", "Starting CLI…");
        elapsed.Restart();
        if (!catalogOnly)
        {
            activity.Clear();
            lastActivity = null;
            RecordActivity(imageRequest ? T("Запускаю генерацию…", "Starting image generation…") : phase);
        }
        progressTimer.Start();
        UpdateProgress();
        generatedImagePath = null;
        IProgress<string> progress = new Progress<string>(value =>
        {
            if (!ReferenceEquals(job, current) || IsDisposed || current.IsCancellationRequested) return;
            phase = value;
            if (!catalogOnly) RecordActivity(value);
            UpdateProgress();
        });
        sidebar.Enabled = run.Visible = sessions.Enabled = profile.Enabled = modeChoice.Enabled = preview.Enabled = template.Enabled = false;
        stop.Visible = stop.Enabled = true;
        repeat.Enabled = referenceRow.Enabled = false;
        metrics.Text = "";
        result.Clear();
        result.Text = T("Выполняю запрос…", "Working on the request…");
        displayed = null;
        try
        {
            if (imageRequest)
            {
                phase = ImageGeneration.Name(provider) + T(" создаёт картинку…", " is generating an image…");
                RecordActivity(phase);
                UpdateProgress();
                var image = await ImageGeneration.Generate(provider, request.Prompt, secret, request.Folder, current.Token, reference);
                generatedImagePath = image;
                state.Text = T("Картинка готова", "Image ready");
                Render(T($"## Картинка готова\n{image}\n\nДвойной щелчок по результату откроет папку с файлом.", $"## Image ready\n{image}\n\nDouble-click the result to open the file's folder."), "");
                return;
            }
            var output = await Agent.Run(request, progress.Report, current.Token);
            progressTimer.Stop();
            if (catalogOnly)
            {
                current.Token.ThrowIfCancellationRequested();
                if (output.Code != 0) { Render("", Redact(output.Stderr)); state.Text = T("Каталог не загружен.", "Could not load the catalog."); return; }
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
                state.Text = models.Count > 0 ? T("Каталог обновлён.", "Catalog updated.") : T("Каталог пуст. Можно ввести ID вручную.", "The catalog is empty. Enter the model ID manually.");
            }
            else
            {
                var answer = Agent.Parse(provider, output, secret);
                metrics.Text = answer.Usage;
                if (answer.Cost is { } cost) ShowCost(T("Оценка CLI", "CLI estimate"), cost);
                if (provider.Router && answer.ModelUsage.ValueKind == System.Text.Json.JsonValueKind.Object)
                    _ = RefreshRouterCost(answer.ModelUsage);
                if (answer.Success && answer.SessionId is { } id) RememberSession(provider, request.Folder, id, request.Prompt, secret);
                state.Text = current.IsCancellationRequested ? T("Запуск остановлен.", "Run stopped.") :
                    answer.Success ? T("Завершено", "Done") : T($"Выполнение прервалось (код {output.Code}).", $"Run ended early (code {output.Code}).");
                Render(answer.Answer, answer.Diagnostics);
            }
        }
        catch (OperationCanceledException)
        {
            state.Text = T("Запуск остановлен.", "Run stopped.");
            Render("", "");
        }
        catch (Exception error) { state.Text = T("Ошибка запуска.", "Could not start the run."); Render("", Redact(error.Message)); }
        finally
        {
            job = null;
            if (!IsDisposed)
            {
                progressTimer.Stop();
                if (!catalogOnly) RecordActivity(state.Text);
            }
            elapsed.Stop();
            current.Dispose();
            if (!IsDisposed) { sidebar.Enabled = run.Visible = profile.Enabled = modeChoice.Enabled = preview.Enabled = template.Enabled = referenceRow.Enabled = true; stop.Visible = false; repeat.Enabled = lastRun is not null; RefreshSessions(); }
        }
    }

    private async Task RefreshRouterCost(System.Text.Json.JsonElement usage)
    {
        using var lookup = new CancellationTokenSource();
        pricing = lookup;
        try
        {
            var cost = await Agent.EstimateRouter(usage, lookup.Token);
            if (!IsDisposed && !lookup.IsCancellationRequested && cost is { } amount)
                ShowCost(T("По тарифам OpenRouter", "OpenRouter estimate"), amount);
        }
        finally { if (ReferenceEquals(pricing, lookup)) pricing = null; }
    }

    private void ShowCost(string source, double amount) =>
        metrics.Text += $"    {source} ≈ ${amount:0.00####}";

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
            if (text.Length > 0) Append(T("\nДиагностика CLI\n", "\nCLI diagnostics\n"), Bold, palette.Muted);
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
