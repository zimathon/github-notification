using System.Diagnostics;
using System.Globalization;
using System.Text;

namespace GitHubSignal.Core;

public sealed record ApiResponse(string Body, Dictionary<string, string> Headers)
{
    public DateTimeOffset ServerDate => Headers.TryGetValue("date", out var date) &&
        DateTimeOffset.TryParse(date, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var parsed)
        ? parsed : throw new InvalidDataException("GitHubのサーバー時刻を取得できませんでした。");
}
public interface IGitHubTransport { Task<ApiResponse> GetAsync(string path, CancellationToken cancellation = default); }

public sealed class GhTransport : IGitHubTransport
{
    public static string FindExecutable()
    {
        // Do not resolve through the working directory, PATH, or a repository-controlled executable.
        var programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var candidates = new[] { Path.Combine(programFiles, "GitHub CLI", "gh.exe"),
            Path.Combine(local, "Programs", "GitHub CLI", "gh.exe") };
        return candidates.FirstOrDefault(File.Exists) ?? throw new FileNotFoundException(
            "GitHub CLIが見つかりません。PowerShellで winget install --id GitHub.cli -e を実行してください。");
    }
    public async Task<ApiResponse> GetAsync(string path, CancellationToken cancellation = default)
    {
        if (!path.StartsWith('/') || path.StartsWith("//", StringComparison.Ordinal) || path.Contains('\r') || path.Contains('\n'))
            throw new InvalidDataException("APIの接続先が正しくありません。");
        var start = new ProcessStartInfo(FindExecutable()) {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true,
            RedirectStandardError = true, RedirectStandardInput = true, StandardOutputEncoding = Encoding.UTF8,
            WorkingDirectory = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)
        };
        foreach (var value in new[] { "api", "--hostname", "github.com", "--method", "GET", "--include",
            "-H", "Accept: application/vnd.github+json", "-H", "X-GitHub-Api-Version: 2022-11-28", path }) start.ArgumentList.Add(value);
        var inherited = new Dictionary<string, string>();
        foreach (var key in new[] { "SystemRoot", "WINDIR", "USERPROFILE", "APPDATA", "LOCALAPPDATA", "TEMP", "TMP", "HOMEDRIVE", "HOMEPATH" })
            if (Environment.GetEnvironmentVariable(key) is { } value) inherited[key] = value;
        start.Environment.Clear();
        foreach (var (key, value) in inherited) start.Environment[key] = value;
        start.Environment["GH_HOST"] = "github.com";
        start.Environment["GH_PROMPT_DISABLED"] = "1";
        start.Environment["NO_COLOR"] = "1";
        using var process = new Process { StartInfo = start };
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        timeout.CancelAfter(TimeSpan.FromSeconds(30));
        process.Start();
        process.StandardInput.Close();
        // Drain diagnostics, but never expose them: gh errors can contain sensitive response details.
        var diagnostics = process.StandardError.BaseStream.CopyToAsync(Stream.Null, timeout.Token);
        try {
            var output = new StringBuilder();
            var buffer = new char[8192];
            int read;
            while ((read = await process.StandardOutput.ReadAsync(buffer.AsMemory(), timeout.Token)) > 0) {
                if (output.Length + read > 32 * 1024 * 1024) throw new InvalidDataException("GitHubからの応答が大きすぎます。");
                output.Append(buffer, 0, read);
            }
            await process.WaitForExitAsync(timeout.Token);
            await diagnostics;
            return Parse(output.ToString(), process.ExitCode);
        } catch (OperationCanceledException) when (!cancellation.IsCancellationRequested) {
            throw new TimeoutException("GitHubとの通信がタイムアウトしました。後で再試行します。");
        } finally {
            try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
            try { await diagnostics; } catch (OperationCanceledException) { }
        }
    }
    public static ApiResponse Parse(string output, int exitCode)
    {
        var text = output.Replace("\r\n", "\n");
        int end = text.IndexOf("\n\n", StringComparison.Ordinal);
        if (end < 0) throw new InvalidDataException("GitHubに接続できません。gh auth login --hostname github.com でログインしてください。");
        var lines = text[..end].Split('\n');
        var status = lines[0].Split(' ', StringSplitOptions.RemoveEmptyEntries);
        int code = status.Length > 1 && int.TryParse(status[1], out var number) ? number : 0;
        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var line in lines.Skip(1)) {
            int colon = line.IndexOf(':');
            if (colon > 0) headers[line[..colon].ToLowerInvariant()] = line[(colon + 1)..].Trim();
        }
        if (exitCode != 0 || code is < 200 or >= 300) throw new InvalidDataException(code switch {
            401 => "GitHubに再ログインしてください。gh auth login --hostname github.com",
            403 or 429 => "GitHubの権限不足またはAPI上限です。権限・SSO認可を確認してください。5分後に再試行します。",
            404 => "対象が削除されたか、読み取り権限がありません。",
            _ => $"GitHubとの通信に失敗しました（HTTP {code}）。"
        });
        if (!headers.GetValueOrDefault("content-type", "").Contains("json", StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("GitHubから想定外の応答が返されました。");
        return new(text[(end + 2)..], headers);
    }
}
