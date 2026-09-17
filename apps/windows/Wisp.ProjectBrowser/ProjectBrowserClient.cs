using System.Diagnostics;
using System.Text;
using System.Text.Json;
using Wisp.ProjectBrowser.Contracts;

namespace Wisp.ProjectBrowser;

/// <summary>One bounded, hidden service process per query. SQLite stays in Rust.</summary>
public sealed class ProjectBrowserClient(string executablePath, TimeSpan? timeout = null) : IProjectBrowserClient
{
    public async Task<ProjectListSnapshot> ListProjectsAsync(string databasePath, CancellationToken cancellationToken = default)
    {
        var reply = await QueryAsync(databasePath, new() { ["type"] = "list_projects" }, "projects", cancellationToken);
        return new(reply.Projects ?? throw InvalidResponse(), reply.ActivitySource!);
    }

    public async Task<IReadOnlyList<BrowserSession>> ListSessionsAsync(string databasePath, string? projectId = null,
        CancellationToken cancellationToken = default)
    {
        var reply = await QueryAsync(databasePath, new() { ["type"] = "list_sessions", ["project_id"] = projectId }, "sessions", cancellationToken);
        return reply.Sessions ?? throw InvalidResponse();
    }

    public async Task<TranscriptPage> GetTranscriptAsync(string databasePath, string projectId, string sessionId,
        long? beforeSeq = null, CancellationToken cancellationToken = default)
    {
        var reply = await QueryAsync(databasePath, new()
        {
            ["type"] = "get_transcript", ["project_id"] = projectId,
            ["session_id"] = sessionId, ["before_seq"] = beforeSeq
        }, "transcript", cancellationToken);
        return new(reply.Messages ?? throw InvalidResponse(), reply.NextBeforeSeq);
    }

    public static ProjectBrowserResponse Decode(string json, string requestId, string expectedType)
    {
        ProjectBrowserResponse reply;
        try { reply = JsonSerializer.Deserialize<ProjectBrowserResponse>(json) ?? throw InvalidResponse(); }
        catch (JsonException ex) { throw new InvalidDataException("查询服务返回了无效 JSON。", ex); }
        if (reply.Schema != ProjectBrowserProtocol.Schema || reply.Id != requestId) throw InvalidResponse();
        if (reply.Type == "error") throw new InvalidOperationException(reply.Message ?? "查询失败。");
        if (reply.Type != expectedType || (expectedType != "transcript" && reply.ActivitySource != ProjectBrowserProtocol.PersistedOnly))
            throw InvalidResponse();
        return reply;
    }

    private async Task<ProjectBrowserResponse> QueryAsync(string databasePath, Dictionary<string, object?> command,
        string expectedType, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!File.Exists(executablePath)) throw new FileNotFoundException("找不到 wisp-service.exe，请重新构建原生预览。", executablePath);
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(timeout ?? TimeSpan.FromSeconds(20));
        var token = deadline.Token;
        var id = Guid.NewGuid().ToString("N");
        command["schema"] = ProjectBrowserProtocol.Schema;
        command["id"] = id;
        var start = new ProcessStartInfo(executablePath)
        {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
            StandardInputEncoding = new UTF8Encoding(false), StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8
        };
        start.ArgumentList.Add("--database");
        start.ArgumentList.Add(databasePath);
        using var process = new Process { StartInfo = start };
        process.Start();
        // Drain both pipes concurrently, including large transcripts. Bound output as well as time.
        var output = ReadBoundedAsync(process.StandardOutput, 32 * 1024 * 1024, token);
        var errors = ReadBoundedAsync(process.StandardError, 64 * 1024, token);
        try
        {
            await process.StandardInput.WriteLineAsync(JsonSerializer.Serialize(command).AsMemory(), token);
            process.StandardInput.Close();
            await Task.WhenAll(output, errors, process.WaitForExitAsync(token));
            if (process.ExitCode != 0) throw new InvalidOperationException($"查询服务退出 ({process.ExitCode})：{await errors}");
            return Decode(await output, id, expectedType);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new TimeoutException("查询超时，请重试或选择其他数据库。");
        }
        finally
        {
            if (!process.HasExited) process.Kill(entireProcessTree: true);
            await process.WaitForExitAsync();
            deadline.Cancel();
            // Observe reader failures on cancellation or a broken stdin pipe.
            try { await Task.WhenAll(output, errors); } catch { }
        }
    }

    private static async Task<string> ReadBoundedAsync(StreamReader reader, int limit, CancellationToken token)
    {
        var text = new StringBuilder();
        var buffer = new char[8192];
        while (await reader.ReadAsync(buffer.AsMemory(), token) is var count && count > 0)
        {
            if (text.Length + count > limit) throw new InvalidDataException("查询响应超过预览版读取上限。");
            text.Append(buffer, 0, count);
        }
        return text.ToString();
    }

    private static InvalidDataException InvalidResponse() => new("查询服务协议不兼容，请重新构建原生预览版。");
}
