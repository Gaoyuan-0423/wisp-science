using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Wisp.ProjectBrowser.Contracts;

namespace Wisp.ProjectBrowser;

public sealed record TranscriptSection(string Text, string? ToolName = null, bool IsResult = false);

public static partial class TranscriptPresentation
{
    // v1 appends each saved assistant tool call as a name line and a JSON arguments line.
    // Only recognize that exact shape; leave ordinary prose and malformed data intact.
    public static IReadOnlyList<TranscriptSection> Sections(BrowserMessage message)
    {
        if (message.Role == "tool") return [new(ReadableArguments(message.Text), message.ToolName ?? "工具", true)];
        if (message.Role != "assistant") return [new(message.Text)];
        var sections = new List<TranscriptSection>();
        var text = new StringBuilder();
        var lines = message.Text.Replace("\r\n", "\n").Split('\n');
        for (var i = 0; i < lines.Length; i++)
        {
            if (i + 1 < lines.Length && ToolNamePattern().IsMatch(lines[i]) && IsJsonObject(lines[i + 1]))
            {
                if (text.ToString().Trim().Length > 0) sections.Add(new(text.ToString()));
                text.Clear();
                sections.Add(new(ReadableArguments(lines[i + 1]), lines[i]));
                i++;
            }
            else text.AppendLine(lines[i]);
        }
        if (text.ToString().Trim().Length > 0) sections.Add(new(text.ToString()));
        return sections;
    }

    private static bool IsJsonObject(string value)
    {
        try { using var json = JsonDocument.Parse(value); return json.RootElement.ValueKind == JsonValueKind.Object; }
        catch (JsonException) { return false; }
    }

    public static string ReadableArguments(string value)
    {
        try
        {
            using var json = JsonDocument.Parse(value);
            if (json.RootElement.ValueKind != JsonValueKind.Object) return value;
            return string.Join("\n\n", json.RootElement.EnumerateObject().Select(p =>
                p.Name + ":\n" + (p.Value.ValueKind == JsonValueKind.String ? p.Value.GetString() : p.Value.GetRawText())));
        }
        catch (JsonException) { return value; }
    }

    [GeneratedRegex(@"^[A-Za-z_][A-Za-z0-9_.:-]*$", RegexOptions.CultureInvariant)]
    private static partial Regex ToolNamePattern();
}
