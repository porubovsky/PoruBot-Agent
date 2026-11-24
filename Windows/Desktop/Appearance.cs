using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using Microsoft.Win32;

record Palette(Color Canvas, Color Card, Color Field, Color Ink, Color Muted, Color Border,
    Color Accent, Color AccentText, Color Highlight, bool Dark)
{
    static Color Hex(int rgb) => Color.FromArgb(255, (rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255);

    public static Palette Resolve(string mode)
    {
        bool dark = mode == "dark" || (mode != "light" &&
            Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
                "AppsUseLightTheme", 1) is int value && value == 0);
        return dark
            ? new(Hex(0x171924), Hex(0x222637), Hex(0x1C2030), Hex(0xF0F2FA), Hex(0xBAC2D8),
                Hex(0x626F91), Hex(0xBAC2FF), Hex(0x202343), Hex(0x333D60), true)
            : new(Hex(0xF0F3FA), Hex(0xFFFFFF), Hex(0xF8FAFE), Hex(0x19223A), Hex(0x515D75),
                Hex(0x73829E), Hex(0x3E4DB2), Hex(0xFFFFFF), Hex(0xDDE5FB), false);
    }

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int size);

    public void ApplyCaption(IntPtr window)
    {
        int dark = Dark ? 1 : 0;
        DwmSetWindowAttribute(window, 20, ref dark, sizeof(int));
        int caption = ColorTranslator.ToWin32(Card), border = ColorTranslator.ToWin32(Border);
        DwmSetWindowAttribute(window, 35, ref caption, sizeof(int));
        DwmSetWindowAttribute(window, 34, ref border, sizeof(int));
    }
}

interface IThemed
{
    void Apply(Palette palette);
}

static class Shapes
{
    public static GraphicsPath Round(Rectangle bounds, int radius)
    {
        var path = new GraphicsPath();
        int diameter = Math.Min(radius * 2, Math.Min(bounds.Width, bounds.Height));
        if (diameter <= 0) { path.AddRectangle(bounds); return path; }
        path.AddArc(bounds.Left, bounds.Top, diameter, diameter, 180, 90);
        path.AddArc(bounds.Right - diameter, bounds.Top, diameter, diameter, 270, 90);
        path.AddArc(bounds.Right - diameter, bounds.Bottom - diameter, diameter, diameter, 0, 90);
        path.AddArc(bounds.Left, bounds.Bottom - diameter, diameter, diameter, 90, 90);
        path.CloseFigure();
        return path;
    }

    public static void PaintBackground(PaintEventArgs e, Color color)
    {
        using var brush = new SolidBrush(color);
        e.Graphics.FillRectangle(brush, e.ClipRectangle);
    }

    public static void DrawBox(Graphics graphics, Rectangle rect, Color fill, Color border, int radius = 8)
    {
        if (rect.Width <= 0 || rect.Height <= 0) return;
        graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using var outline = Round(rect, radius);
        using var brush = new SolidBrush(fill);
        using var pen = new Pen(border);
        graphics.FillPath(brush, outline);
        graphics.DrawPath(pen, outline);
    }
}

sealed class ModernButton : Button, IThemed
{
    private Palette palette = Palette.Resolve("system");
    private bool hover;
    private readonly bool primary;

    public ModernButton(string text, bool primary = false)
    {
        this.primary = primary;
        Text = text;
        AutoSize = true;
        MinimumSize = new(0, 33);
        FlatStyle = FlatStyle.Flat;
        FlatAppearance.BorderSize = 0;
        SetStyle(ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer, true);
        GotFocus += (_, _) => Invalidate();
        LostFocus += (_, _) => Invalidate();
        MouseEnter += (_, _) => { hover = true; Invalidate(); };
        MouseLeave += (_, _) => { hover = false; Invalidate(); };
    }

    public void Apply(Palette value) { palette = value; Invalidate(); }

    protected override void OnPaint(PaintEventArgs e)
    {
        Shapes.PaintBackground(e, Parent?.BackColor ?? palette.Canvas);
        Color bg = !Enabled ? palette.Field : primary ? palette.Accent : hover ? palette.Highlight : palette.Field;
        Color fg = !Enabled ? palette.Muted : primary ? palette.AccentText : palette.Ink;
        Shapes.DrawBox(e.Graphics, new(1, 1, Width - 3, Height - 3), bg,
            Focused ? palette.Accent : primary && Enabled ? bg : palette.Border);
        TextRenderer.DrawText(e.Graphics, Text, Font, ClientRectangle, fg,
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis | TextFormatFlags.PreserveGraphicsClipping);
    }
}

sealed class ModernSwitch : CheckBox, IThemed
{
    private Palette palette = Palette.Resolve("system");

    public ModernSwitch()
    {
        Height = 29;
        SetStyle(ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer, true);
        CheckedChanged += (_, _) => Invalidate();
        GotFocus += (_, _) => Invalidate();
        LostFocus += (_, _) => Invalidate();
    }

    public void Apply(Palette value) { palette = value; Invalidate(); }

    protected override void OnPaint(PaintEventArgs e)
    {
        Shapes.PaintBackground(e, Parent?.BackColor ?? palette.Card);
        int x = Math.Max(0, Width - 38), y = (Height - 20) / 2;
        bool active = Checked && Enabled;
        Shapes.DrawBox(e.Graphics, new(x, y, 36, 19), active ? palette.Accent : palette.Field,
            Focused ? palette.Accent : active ? palette.Accent : palette.Border, 10);
        using var knob = new SolidBrush(active ? palette.AccentText : palette.Muted);
        e.Graphics.FillEllipse(knob, x + (active ? 20 : 3), y + 3, 13, 13);
        TextRenderer.DrawText(e.Graphics, Text, Font, new Rectangle(0, 0, Math.Max(0, x - 6), Height),
            Enabled ? palette.Ink : palette.Muted,
            TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix | TextFormatFlags.PreserveGraphicsClipping);
    }
}

sealed class FieldFrame : Panel, IThemed
{
    private Palette palette = Palette.Resolve("system");

    public FieldFrame(Control input, int inset = 8)
    {
        Padding = new(inset);
        DoubleBuffered = true;
        if (input is TextBoxBase editor) editor.BorderStyle = BorderStyle.None;
        if (input is TextBox { Multiline: false } line) line.AutoSize = false;
        input.Dock = DockStyle.Fill;
        input.Enter += (_, _) => Invalidate();
        input.Leave += (_, _) => Invalidate();
        Controls.Add(input);
    }

    public void Apply(Palette value)
    {
        palette = value;
        BackColor = value.Field;
        Controls[0].BackColor = value.Field;
        Controls[0].ForeColor = value.Ink;
        Invalidate();
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        Shapes.PaintBackground(e, Parent?.BackColor ?? palette.Canvas);
        Shapes.DrawBox(e.Graphics, new(1, 1, Width - 3, Height - 3), palette.Field,
            ContainsFocus ? palette.Accent : palette.Border);
    }

    protected override void OnClick(EventArgs e) { base.OnClick(e); Controls[0].Focus(); }
}

sealed class ThemeChoice : UserControl, IThemed
{
    private readonly TextBox input = new() { BorderStyle = BorderStyle.None, AutoSize = false };
    private readonly bool editable;
    private Palette palette = Palette.Resolve("system");
    private int selected = -1;
    private ToolStripDropDown? dropdown;
    public List<object> Items { get; } = [];
    [System.ComponentModel.DesignerSerializationVisibility(System.ComponentModel.DesignerSerializationVisibility.Hidden)]
    public Func<object, string>? DisplayLabel { get; set; }

    private string LabelFor(object? item) => item is null ? "" : DisplayLabel?.Invoke(item) ?? item.ToString() ?? "";
    public event EventHandler? SelectedIndexChanged;
    public object? SelectedItem => selected >= 0 && selected < Items.Count ? Items[selected] : null;

    public ThemeChoice(bool editable = false)
    {
        this.editable = editable;
        Height = 36;
        Width = 150;
        TabStop = !editable;
        AccessibleRole = AccessibleRole.ComboBox;
        DoubleBuffered = true;
        if (editable)
        {
            Controls.Add(input);
            input.TextChanged += (_, _) => Invalidate();
            input.KeyDown += (_, e) =>
            {
                if (e.KeyCode != Keys.F4 && !(e.Alt && e.KeyCode == Keys.Down)) return;
                e.SuppressKeyPress = true;
                ShowChoices();
            };
            input.Enter += (_, _) => Invalidate();
            input.Leave += (_, _) => Invalidate();
        }
    }

    [System.ComponentModel.DesignerSerializationVisibility(System.ComponentModel.DesignerSerializationVisibility.Hidden)]
    public int SelectedIndex
    {
        get => selected;
        set
        {
            int index = value >= 0 && value < Items.Count ? value : -1;
            bool changed = index != selected || Text != (index >= 0 ? LabelFor(Items[index]) : "");
            selected = index;
            Text = LabelFor(SelectedItem);
            if (changed) SelectedIndexChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    [System.Diagnostics.CodeAnalysis.AllowNull]
    public override string Text
    {
        get => editable ? input.Text : base.Text;
        set { if (editable) input.Text = value; else base.Text = value; Invalidate(); }
    }

    public void Apply(Palette value)
    {
        palette = value;
        input.BackColor = value.Field;
        input.ForeColor = value.Ink;
        Invalidate();
    }

    protected override void OnLayout(LayoutEventArgs e)
    {
        base.OnLayout(e);
        if (!editable) return;
        int inset = LogicalToDeviceUnits(10);
        int height = input.PreferredHeight;
        input.SetBounds(inset, Math.Max(0, (Height - height) / 2),
            Math.Max(1, Width - inset - LogicalToDeviceUnits(28)), height);
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        base.OnMouseDown(e);
        if (e.Button == MouseButtons.Left) { Focus(); ShowChoices(); }
    }

    protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
    {
        if (keyData == Keys.F4 || keyData == (Keys.Alt | Keys.Down) ||
            (!editable && keyData is Keys.Space or Keys.Enter or Keys.Down))
        { ShowChoices(); return true; }
        return base.ProcessCmdKey(ref msg, keyData);
    }

    protected override void OnGotFocus(EventArgs e) { base.OnGotFocus(e); Invalidate(); }
    protected override void OnLostFocus(EventArgs e) { base.OnLostFocus(e); Invalidate(); }

    protected override void OnPaint(PaintEventArgs e)
    {
        Shapes.PaintBackground(e, Parent?.BackColor ?? palette.Canvas);
        Shapes.DrawBox(e.Graphics, new(1, 1, Width - 3, Height - 3), palette.Field,
            ContainsFocus ? palette.Accent : palette.Border);
        if (!editable)
            TextRenderer.DrawText(e.Graphics, Text, Font, new Rectangle(LogicalToDeviceUnits(10), 0, Math.Max(1, Width - LogicalToDeviceUnits(39)), Height),
                Enabled ? palette.Ink : palette.Muted,
                TextFormatFlags.VerticalCenter | TextFormatFlags.Left | TextFormatFlags.EndEllipsis | TextFormatFlags.PreserveGraphicsClipping);
        using var pen = new Pen(palette.Muted, 1.8f) { StartCap = LineCap.Round, EndCap = LineCap.Round };
        e.Graphics.DrawLines(pen, new PointF[]
        {
            new(Width - 22, Height / 2f - 2), new(Width - 17, Height / 2f + 3), new(Width - 12, Height / 2f - 2)
        });
    }

    private void ShowChoices()
    {
        if (Items.Count == 0 || dropdown is not null) return;
        var list = new ListBox { BorderStyle = BorderStyle.None, IntegralHeight = false,
            DrawMode = DrawMode.OwnerDrawFixed, ItemHeight = Math.Max(29, Font.Height + 12),
            Font = Font, BackColor = palette.Field, ForeColor = palette.Ink };
        list.Items.AddRange(Items.ToArray());
        if (selected >= 0 && selected < list.Items.Count) list.SelectedIndex = selected;
        list.DrawItem += (_, e) =>
        {
            if (e.Index < 0 || e.Graphics is null) return;
            bool active = (e.State & DrawItemState.Selected) != 0;
            using var brush = new SolidBrush(active ? palette.Highlight : palette.Field);
            e.Graphics.FillRectangle(brush, e.Bounds);
            var rect = Rectangle.Inflate(e.Bounds, -10, 0);
            TextRenderer.DrawText(e.Graphics, LabelFor(list.Items[e.Index]), Font, rect, palette.Ink,
                TextFormatFlags.VerticalCenter | TextFormatFlags.Left | TextFormatFlags.EndEllipsis | TextFormatFlags.PreserveGraphicsClipping);
        };
        int popupWidth = Math.Max(Width, 170);
        var host = new ToolStripControlHost(list)
        {
            AutoSize = false, Size = new(popupWidth, Math.Min(8, Items.Count) * list.ItemHeight),
            Margin = Padding.Empty, Padding = Padding.Empty
        };
        var popup = new ToolStripDropDown { Padding = new(1), BackColor = palette.Border, DropShadowEnabled = true };
        dropdown = popup;
        popup.Items.Add(host);
        void Choose() { if (list.SelectedIndex >= 0) { SelectedIndex = list.SelectedIndex; popup.Close(); } }
        list.MouseClick += (_, e) => { if (list.IndexFromPoint(e.Location) >= 0) Choose(); };
        list.KeyDown += (_, e) =>
        {
            if (e.KeyCode == Keys.Enter) { e.SuppressKeyPress = true; Choose(); }
            else if (e.KeyCode == Keys.Escape) { e.SuppressKeyPress = true; popup.Close(); }
        };
        popup.Closed += (_, _) => { dropdown = null; popup.Dispose(); };
        popup.Show(this, new Point(0, Height + 2));
        list.Focus();
    }
}
