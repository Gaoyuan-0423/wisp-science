using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Wisp.ProjectBrowser;
using Wisp.ProjectBrowser.Contracts;

namespace Wisp.Science.Preview;

internal sealed class NativeWorkspacePanel : UserControl, IDisposable
{
    private readonly WorkspacePanelModel model;
    private readonly WispDesign design;
    private readonly ConversationItem[] transcript;
    private readonly Action close;
    private readonly TextBox filter = new() { PlaceholderText = "筛选名称" };
    private readonly StackPanel body = new() { Spacing = 8 };
    private readonly CancellationTokenSource lifetime = new();
    private bool disposed;

    public NativeWorkspacePanel(WorkspacePanelModel model, ConversationItem[] transcript, WispDesign design, Action close)
    {
        this.model = model; this.transcript = transcript; this.design = design; this.close = close;
        var root = new Grid { Width = 320, Padding = new Thickness(12), Background = design.Brush("bg-sunken") };
        root.RowDefinitions.Add(new() { Height = GridLength.Auto });
        root.RowDefinitions.Add(new() { Height = GridLength.Auto });
        root.RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) });
        var header = new Grid();
        header.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        var tabs = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        foreach (var id in model.Tabs.Available)
        {
            var captured = id;
            var tab = new Button { Content = Label(id), Padding = new Thickness(8, 4, 8, 4),
                Background = id == model.Tabs.Selected ? design.Brush("surface-hover") : new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Transparent) };
            tab.Click += async (_, _) => { await model.RefreshAsync(captured, cancellationToken: lifetime.Token); Render(); };
            tabs.Children.Add(tab);
        }
        header.Children.Add(tabs);
        var dismiss = new Button { Content = design.Icon("close", 14), Padding = new Thickness(6) };
        dismiss.Click += (_, _) => close();
        ToolTipService.SetToolTip(dismiss, "关闭面板");
        Grid.SetColumn(dismiss, 1); header.Children.Add(dismiss);
        root.Children.Add(header);
        filter.TextChanged += (_, _) => Render();
        Grid.SetRow(filter, 1); root.Children.Add(filter);
        var scroll = new ScrollViewer { Content = body, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        Grid.SetRow(scroll, 2); root.Children.Add(scroll);
        Content = root;
        _ = StartAsync();
    }

    private async Task StartAsync()
    {
        try { await model.RefreshAsync(model.Tabs.Selected, cancellationToken: lifetime.Token); Render(); }
        catch (OperationCanceledException) { }
    }

    private void Render()
    {
        if (disposed) return;
        body.Children.Clear();
        if (model.Loading) body.Children.Add(new ProgressBar { IsIndeterminate = true, Height = 3 });
        if (model.Error is { } error) body.Children.Add(new TextBlock { Text = error, TextWrapping = TextWrapping.Wrap, Foreground = design.Brush("clay-strong"), FontSize = 12 });
        var query = filter.Text.Trim();
        if (model.Tabs.Selected == "artifacts")
        {
            foreach (var artifact in model.Artifacts.Where(item => query.Length == 0 || item.Name.Contains(query, StringComparison.CurrentCultureIgnoreCase)))
            {
                var captured = artifact;
                var button = Row(captured.Name, captured.Kind + " · " + (captured.LogicalPath ?? captured.Path), "doc");
                button.Click += async (_, _) => { await model.ReadArtifactAsync(captured.Id, lifetime.Token); Render(); };
                body.Children.Add(button);
            }
            if (model.Artifacts.Length == 0 && !model.Loading) body.Children.Add(Mute("这个会话暂无产物"));
        }
        else if (model.Tabs.Selected == "files")
        {
            var up = new Button { Content = "上级", IsEnabled = model.Path != "." };
            up.Click += async (_, _) => { await model.RefreshAsync("files", model.Parent, lifetime.Token); Render(); };
            body.Children.Add(up);
            body.Children.Add(Mute(model.Path));
            foreach (var file in model.Files.Where(item => query.Length == 0 || item.Name.Contains(query, StringComparison.CurrentCultureIgnoreCase)))
            {
                var captured = file;
                var button = Row(captured.Name, captured.IsDir ? "文件夹" : $"{captured.Size} bytes", captured.IsDir ? "folder" : "doc");
                button.Click += async (_, _) =>
                {
                    if (captured.IsDir) await model.RefreshAsync("files", WorkspacePanelModel.Child(model.Path, captured.Name), lifetime.Token);
                    else await model.ReadFileAsync(WorkspacePanelModel.Child(model.Path, captured.Name), lifetime.Token);
                    Render();
                };
                body.Children.Add(button);
            }
        }
        else if (model.Tabs.Selected == "hosts")
        {
            foreach (var context in model.Contexts?.Attached ?? [])
                body.Children.Add(Row(context.Label, context.Kind, "terminal"));
            if (model.Contexts?.Attached.Length == 0) body.Children.Add(Mute("没有已连接的运行环境"));
        }
        else if (model.Tabs.Selected == "agents")
        {
            foreach (var agent in model.Agents)
                body.Children.Add(Row(agent.Workflow.Name, agent.Workflow.Status, "sparkles"));
            if (model.Agents.Length == 0) body.Children.Add(Mute("这个会话暂无工作流"));
        }
        else if (model.Tabs.Selected == "notebook")
        {
            foreach (var cell in NativeNotebookCell.Collect(transcript).Where(cell => query.Length == 0 || cell.Source.Contains(query, StringComparison.CurrentCultureIgnoreCase)))
                body.Children.Add(Row(cell.Language, cell.Source, "book"));
        }
        else if (model.Tabs.Selected == "highlights")
        {
            foreach (var row in model.Highlights.Where(item => query.Length == 0 || item.Code.Contains(query, StringComparison.CurrentCultureIgnoreCase)))
                body.Children.Add(Row(row.Title, row.Code, "book"));
        }
        else if (model.Tabs.Selected == "provenance")
        {
            foreach (var row in NativeProvenanceRow.Collect(transcript).Where(item => item.Matches(query)))
                body.Children.Add(Row(row.Name, row.Output.Length == 0 ? row.Input : row.Output, "list"));
        }
        if (model.Preview?.Text is { } text)
        {
            body.Children.Add(new TextBlock { Text = model.Preview.Path, FontSize = 12, Foreground = design.Brush("text-muted") });
            body.Children.Add(new TextBox { Text = text, IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 120 });
        }
    }

    private Button Row(string title, string detail, string icon)
    {
        var content = new StackPanel { Spacing = 2 };
        var heading = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        heading.Children.Add(design.Icon(icon, 14));
        heading.Children.Add(new TextBlock { Text = title, TextWrapping = TextWrapping.Wrap });
        content.Children.Add(heading);
        content.Children.Add(new TextBlock { Text = detail, FontSize = 11, Foreground = design.Brush("text-muted"), TextWrapping = TextWrapping.Wrap });
        return new Button { Content = content, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Left, Padding = new Thickness(8) };
    }
    private TextBlock Mute(string text) => new() { Text = text, Foreground = design.Brush("text-muted"), FontSize = 12, TextWrapping = TextWrapping.Wrap };
    private static string Label(string id) => id switch
    {
        "artifacts" => "产物", "files" => "文件", "hosts" => "环境", "agents" => "工作流",
        "notebook" => "笔记本", "highlights" => "摘录", "provenance" => "溯源", _ => id
    };
    public void Dispose()
    {
        if (disposed) return;
        disposed = true; lifetime.Cancel(); model.Close(); lifetime.Dispose();
    }
}
