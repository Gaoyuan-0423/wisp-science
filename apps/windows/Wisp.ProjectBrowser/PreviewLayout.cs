namespace Wisp.ProjectBrowser;

/// <summary>Breakpoints are WinUI device-independent pixels, not physical screen pixels.</summary>
public readonly record struct PreviewLayout(bool StackHomeColumns, bool StackHeader, bool CompactWorkspace, bool ShortWindow)
{
    public static IReadOnlyList<(string Label, string Icon)> WorkspaceActions { get; } =
    [ ("会话大纲", "list"), ("分享", "share"), ("运行轨迹", "timeline"), ("研究归档", "archive"), ("待查看", "bell"), ("终端", "terminal"), ("切换侧面板", "panel") ];
    public static PreviewLayout ForSize(double width, double height) => new(width < 680, width < 1080, width < 1000, height < 580);
}
