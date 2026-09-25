using System.Text.Json;
using System.Text.RegularExpressions;

namespace GitHubSignal.Core;

public sealed record PullRequestInfo(string? Status, DateTimeOffset CheckedAt)
{
    [System.Text.Json.Serialization.JsonIgnore]
    public string Label => Status switch { "open" => "🟢 Open", "draft" => "⚪ Draft", "merged" => "🟣 マージ済み", "closed" => "🔴 クローズ", _ => "状態未取得" };
    public static PullRequestInfo FromJson(JsonElement value) {
        var state = value.TryGetProperty("state", out var s) ? s.GetString() : null;
        bool merged = value.TryGetProperty("merged", out var m) && m.ValueKind == JsonValueKind.True;
        bool draft = value.TryGetProperty("draft", out var d) && d.ValueKind == JsonValueKind.True;
        return new(merged ? "merged" : state == "closed" ? "closed" : state == "open" ? (draft ? "draft" : "open") : null, DateTimeOffset.UtcNow);
    }
    public static string? ApiPath(Signal signal) {
        if (Rules.SafeWebUrl(signal.Url) is not { } url || url.Host != "github.com") return null;
        var match = Regex.Match(url.AbsolutePath, @"^/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+(?=/|$)");
        if (!match.Success) return null;
        var parts = match.Value.Split('/');
        return $"/repos/{parts[1]}/{parts[2]}/pulls/{parts[4]}";
    }
}

public sealed record SignalBatch(List<Signal> Signals, string? ThreadKey = null, PullRequestInfo? PullRequest = null);
