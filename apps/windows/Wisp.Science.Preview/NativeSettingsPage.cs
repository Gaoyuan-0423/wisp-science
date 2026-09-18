using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Wisp.ProjectBrowser;
using Wisp.ProjectBrowser.Contracts;

namespace Wisp.Science.Preview;

/// <summary>In-window settings page, pinned to the database/project until returning.</summary>
internal sealed class NativeSettingsPage : UserControl, IDisposable
{
    private readonly CancellationTokenSource lifetime = new();
    private readonly StackPanel form = new() { Spacing = 18 };
    private readonly TextBlock status = new() { TextWrapping = TextWrapping.Wrap };
    private readonly StackPanel body = new() { Spacing = 20, Padding = new Thickness(28), MaxWidth = 1000 };
    private readonly Grid shell = new();
    private readonly WispDesign design = new();
    private readonly StackPanel preview = new() { Spacing = 16 };
    private readonly Grid columns = new() { ColumnSpacing = 28, RowSpacing = 24 };
    private readonly ProgressBar progress = new() { IsIndeterminate = true, Height = 3, Visibility = Visibility.Collapsed };
    private readonly Border previewCard = new() { Padding = new Thickness(24), CornerRadius = new CornerRadius(12), BorderThickness = new Thickness(1) };
    private readonly Button save = new() { Content = "保存", IsEnabled = false };
    private readonly Button discard = new() { Content = "取消修改", IsEnabled = false };
    private readonly Button reload = new() { Content = "刷新" };
    private readonly List<ComboBox> choices = [];
    private readonly Action<JsonObject> apply;
    private readonly Action close;
    private bool started;
    private readonly string database;
    private readonly string? projectId;
    private NativeSettingsClient? client;
    private AppearanceSettingsModel? model;
    private bool closed;
    private bool working;
    private bool confirmClose;

    public NativeSettingsPage(string database, string? projectId, Action<JsonObject> apply, Action close)
    {
        this.database = database; this.projectId = projectId; this.apply = apply; this.close = close;
        shell.ColumnDefinitions.Add(new() { Width = new GridLength(210) });
        shell.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        var nav = new StackPanel { Spacing = 4, Padding = new Thickness(16, 24, 16, 24) };
        var backContent = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        backContent.Children.Add(design.Icon("arrow-left"));
        backContent.Children.Add(new TextBlock { Text = "返回" });
        var back = new Button { Content = backContent, Margin = new Thickness(0, 0, 0, 16) };
        back.Click += (_, _) => RequestClose(); nav.Children.Add(back);
        nav.Children.Add(new TextBlock { Text = "设置", FontSize = 22, Margin = new Thickness(12, 0, 0, 24) });
        var navigation = JsonNode.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Assets", "settings-navigation.json")))!.AsObject();
        string? group = null;
        foreach (var entry in navigation)
        {
            var nextGroup = entry.Value!["group"]!.GetValue<string>();
            if (group != nextGroup)
            {
                group = nextGroup;
                nav.Children.Add(new TextBlock { Text = group, FontSize = 11, Opacity = 0.65, Margin = new Thickness(12, 16, 0, 6) });
            }
            var item = new Button { Content = entry.Value["zh"]!.GetValue<string>(),
                HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Left,
                Padding = new Thickness(12, 8, 12, 8), IsEnabled = entry.Key == "appearance" };
            if (entry.Key == "appearance") item.Background = design.Brush("surface-hover");
            else ToolTipService.SetToolTip(item, "此设置页尚未接入 Windows");
            nav.Children.Add(item);
        }
        shell.Children.Add(new ScrollViewer { Content = nav, Background = design.Brush("bg-sunken"), HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled });
        var heading = new Grid();
        heading.Children.Add(new TextBlock { Text = "外观", FontSize = 24 });
        reload.Content = "重新载入"; reload.HorizontalAlignment = HorizontalAlignment.Right;
        heading.Children.Add(reload); body.Children.Add(heading);
        body.Children.Add(new TextBlock { Text = "选择主题、配色和字体大小。保存后与桌面客户端共享。", TextWrapping = TextWrapping.Wrap, Opacity = 0.65 });
        body.Children.Add(progress); body.Children.Add(status);
        columns.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        columns.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        columns.RowDefinitions.Add(new() { Height = GridLength.Auto });
        columns.RowDefinitions.Add(new() { Height = GridLength.Auto });
        columns.Children.Add(form);
        previewCard.Child = preview; Grid.SetColumn(previewCard, 1); columns.Children.Add(previewCard);
        body.Children.Add(columns);
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12, HorizontalAlignment = HorizontalAlignment.Right };
        actions.Children.Add(discard); actions.Children.Add(save); body.Children.Add(actions);
        var scope = new TextBlock { Text = "其他设置分类将逐步接入 Windows。", TextWrapping = TextWrapping.Wrap, Opacity = 0.6, FontSize = 12 };
        ToolTipService.SetToolTip(scope, $"{database}\n{projectId ?? "全局"}"); body.Children.Add(scope);
        var scroll = new ScrollViewer { Content = body, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        Grid.SetColumn(scroll, 1); shell.Children.Add(scroll); shell.Background = design.Brush("bg-app");
        Content = shell;
        shell.SizeChanged += (_, e) =>
        {
            shell.ColumnDefinitions[0].Width = new GridLength(e.NewSize.Width < 760 ? 156 : 210);
            var narrow = e.NewSize.Width < 1000;
            columns.ColumnDefinitions[1].Width = narrow ? new GridLength(0) : new GridLength(1, GridUnitType.Star);
            Grid.SetColumn(previewCard, narrow ? 0 : 1); Grid.SetRow(previewCard, narrow ? 1 : 0);
        };
        RenderForm();
        reload.Click += async (_, _) => await LoadAsync();
        discard.Click += (_, _) => { model?.Discard(); confirmClose = false; RenderForm(); status.Text = "已取消修改。"; };
        save.Click += async (_, _) => await SaveAsync();
        body.Loaded += async (_, _) => { if (!started) { started = true; await LoadAsync(); } };
    }

    public void HandleEscape()
    {
        if (choices.LastOrDefault(c => c.IsDropDownOpen) is { } choice) choice.IsDropDownOpen = false;
        else RequestClose();
    }

    private void RequestClose()
    {
        if (model?.HasChanges == true && !confirmClose)
        {
            confirmClose = true;
            status.Text = "有未保存的修改。保存以保留，或再次返回以放弃。";
            return;
        }
        close();
    }

    public void Dispose()
    {
        if (closed) return;
        closed = true; lifetime.Cancel(); client?.Dispose(); lifetime.Dispose();
    }

    private void SetBusy(bool value)
    {
        working = value; progress.Visibility = value ? Visibility.Visible : Visibility.Collapsed;
        foreach (var control in form.Children.OfType<Control>()) control.IsEnabled = !value && model?.Draft is not null;
        save.IsEnabled = discard.IsEnabled = !value && model?.Draft is not null;
        reload.IsEnabled = !value;
    }

    private async Task LoadAsync()
    {
        if (working) return;
        SetBusy(true); status.Text = "正在连接桌面设置…";
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        deadline.CancelAfter(TimeSpan.FromSeconds(15));
        try
        {
            if (client is null)
            {
                string? host = Environment.GetEnvironmentVariable("WISP_SETTINGS_HOST_PATH")
                    ?? Path.Combine(AppContext.BaseDirectory, "settings-host", "wisp-tauri.exe");
                var defaultDatabase = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                    "science.wisp-science", "wisp-science", "wisp.sqlite");
                if (!string.Equals(Path.GetFullPath(database), Path.GetFullPath(defaultDatabase), StringComparison.OrdinalIgnoreCase))
                    host = null; // Never start a default-database host on behalf of an alternate database.
                var connected = await NativeSettingsClient.ConnectAsync(database, host, deadline.Token);
                if (closed) { connected.Dispose(); return; }
                client = connected;
                model = new(client, projectId);
            }
            await model!.LoadAsync(deadline.Token);
            if (closed) return;
            RenderForm(); status.Text = "已读取设置。字体与自定义 CSS 的完整呈现仍由桌面客户端提供。";
        }
        catch (OperationCanceledException) { if (!closed) status.Text = "连接超时，请检查桌面客户端版本后重新载入。可以随时返回。"; }
        catch (Exception ex) { if (!closed) status.Text = "无法读取设置：" + ex.Message; }
        finally { if (!closed) SetBusy(false); }
    }

    private async Task SaveAsync()
    {
        if (working || model is null) return;
        SetBusy(true); status.Text = "正在保存…";
        try
        {
            var saved = await model.SaveAsync(lifetime.Token);
            if (closed || saved is null) return;
            apply(saved); confirmClose = false;
            status.Text = "已保存。主题和配色已应用到预览窗口。";
        }
        catch (Exception ex)
        {
            if (!closed) status.Text = "保存未确认，草稿已保留；未自动重试。可在桌面客户端核实后再决定是否保存。" + ex.Message;
        }
        finally { if (!closed) SetBusy(false); }
    }

    private void RenderForm()
    {
        choices.Clear(); form.Children.Clear();
        var loaded = model?.Draft is not null;
        var prefs = model?.Draft ?? new JsonObject { ["theme"] = "system", ["light_palette"] = "paper", ["dark_palette"] = "charcoal", ["ui_font_size"] = 14, ["code_font_size"] = 12 };
        form.Children.Add(new TextBlock { Text = "主题与配色", FontSize = 16 });
        Choice("主题", "theme", [("system", "跟随系统"), ("light", "浅色"), ("dark", "深色")]);
        Choice("浅色配色", "light_palette", [.. new[] { "paper", "codex", "github", "catppuccin", "everforest" }.Select(s => (s, s))]);
        Choice("深色配色", "dark_palette", [.. new[] { "charcoal", "codex", "github", "catppuccin", "gruvbox" }.Select(s => (s, s))]);
        form.Children.Add(new TextBlock { Text = "字体", FontSize = 16, Margin = new Thickness(0, 12, 0, 0) });
        FontSize("界面字号", "ui_font_size", 12, 20, 14);
        FontSize("代码字号", "code_font_size", 10, 20, 12);

        UpdatePreview(prefs);
        foreach (var control in form.Children.OfType<Control>()) control.IsEnabled = loaded && !working;

        void Choice(string label, string key, (string Value, string Label)[] items)
        {
            var choice = new ComboBox { Header = label, HorizontalAlignment = HorizontalAlignment.Stretch };
            foreach (var item in items) choice.Items.Add(new ComboBoxItem { Content = item.Label, Tag = item.Value });
            choice.SelectedItem = choice.Items.Cast<ComboBoxItem>().FirstOrDefault(i => (string)i.Tag == prefs[key]?.GetValue<string>());
            choice.SelectionChanged += (_, _) => { if (choice.SelectedItem is ComboBoxItem item) { prefs[key] = (string)item.Tag; confirmClose = false; UpdatePreview(prefs); } };
            choices.Add(choice); form.Children.Add(choice);
        }
        void FontSize(string label, string key, int min, int max, int fallback)
        {
            var slider = new Slider { Header = label, Minimum = min, Maximum = max, StepFrequency = 1, Value = prefs[key]?.GetValue<int>() ?? fallback };
            slider.ValueChanged += (_, e) => { prefs[key] = (int)e.NewValue; confirmClose = false; UpdatePreview(prefs); };
            form.Children.Add(slider);
        }
    }
    private void UpdatePreview(JsonObject prefs)
    {
        design.Dark = prefs["theme"]?.GetValue<string>() == "dark" ||
            (prefs["theme"]?.GetValue<string>() == "system" && shell.ActualTheme == ElementTheme.Dark);
        design.LightPalette = prefs["light_palette"]?.GetValue<string>() ?? "paper";
        design.DarkPalette = prefs["dark_palette"]?.GetValue<string>() ?? "charcoal";
        previewCard.Background = design.Brush("bg-elev"); previewCard.BorderBrush = design.Brush("border");
        preview.Children.Clear();
        Add("预览", 12, "text-muted");
        Add("Wisp Science", 18, "text");
        Add("帮我查看这个项目的数据，整理分析思路。", prefs["ui_font_size"]?.GetValue<int>() ?? 14, "text");
        Add("分析计划\n\n1. 查看样本和文件\n2. 确认分析目标\n3. 汇总结果与图表", prefs["ui_font_size"]?.GetValue<int>() ?? 14, "text");
        Add("import pandas as pd\ndata = pd.read_csv(\"samples.csv\")\ndata.head()", prefs["code_font_size"]?.GetValue<int>() ?? 12, "clay", true);
        Add("输入消息…", 14, "text-faint");
        void Add(string text, double size, string token, bool code = false) => preview.Children.Add(new TextBlock {
            Text = text, FontSize = size, Foreground = design.Brush(token), TextWrapping = TextWrapping.Wrap,
            FontFamily = new FontFamily(code ? "Consolas" : "Segoe UI") });
    }

}


