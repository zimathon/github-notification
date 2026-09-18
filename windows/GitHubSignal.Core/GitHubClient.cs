using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace GitHubSignal.Core;

public sealed record NotificationBatch(List<NotificationThread> Threads, DateTimeOffset ServerDate, int PollInterval);
public sealed class GitHubClient(IGitHubTransport transport)
{
    private static string Since(DateTimeOffset date) => date.UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ssZ");
    public async Task<(string Login, DateTimeOffset Now)> AccountAsync(CancellationToken cancellation = default)
    {
        var response = await transport.GetAsync("/user", cancellation);
        using var doc = JsonDocument.Parse(response.Body);
        return (Text(doc.RootElement, "login"), response.ServerDate);
    }
    public async Task<NotificationBatch> NotificationsAsync(DateTimeOffset since, CancellationToken cancellation = default)
    {
        var path = $"/notifications?all=true&since={Since(since)}&per_page=100";
        var first = await transport.GetAsync(path + "&page=1", cancellation);
        var threads = await PagesAsync<NotificationThread>(first, path, cancellation);
        var poll = int.TryParse(first.Headers.GetValueOrDefault("x-poll-interval"), out var value) ? Math.Clamp(value, 60, 86400) : 60;
        return new(threads, first.ServerDate, poll);
    }
    private async Task<List<T>> ListAsync<T>(string path, CancellationToken cancellation)
    {
        path += (path.Contains('?') ? "&" : "?") + "per_page=100";
        return await PagesAsync<T>(await transport.GetAsync(path + "&page=1", cancellation), path, cancellation);
    }
    private async Task<List<T>> PagesAsync<T>(ApiResponse first, string path, CancellationToken cancellation)
    {
        var response = first;
        List<T> result = [];
        for (int page = 1; page <= 100; page++) {
            result.AddRange(Json.Read<List<T>>(response.Body));
            if (!response.Headers.GetValueOrDefault("link", "").Contains("rel=\"next\"", StringComparison.Ordinal)) return result;
            if (page == 100) throw new InvalidDataException("通知の取得件数が上限を超えました。");
            // Never follow a Link URL from a response: reconstruct the page on the same approved endpoint.
            response = await transport.GetAsync(path + "&page=" + (page + 1), cancellation);
        }
        return result;
    }
    public async Task<List<Signal>> SignalsAsync(PendingThread pending, string login, CancellationToken cancellation = default)
    {
        var thread = pending.Thread;
        if (thread.Subject.Type is not ("PullRequest" or "Issue")) return [];
        if (!Uri.TryCreate(thread.Subject.Url, UriKind.Absolute, out var uri) || uri.Scheme != "https" ||
            uri.Host != "api.github.com" || uri.UserInfo != "" || !uri.IsDefaultPort || uri.Query != "" || uri.Fragment != "" ||
            !Regex.IsMatch(uri.AbsolutePath, @"^/repos/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/(pulls|issues)/[0-9]+$"))
            throw new InvalidDataException("通知のリンク先を確認できませんでした。");
        var response = await transport.GetAsync(uri.AbsolutePath, cancellation);
        using var subjectDoc = JsonDocument.Parse(response.Body);
        var subject = subjectDoc.RootElement;
        bool isPr = thread.Subject.Type == "PullRequest";
        bool ownPr = isPr && Text(subject.GetProperty("user"), "login").Equals(login, StringComparison.OrdinalIgnoreCase);
        var issuePath = uri.AbsolutePath.Replace("/pulls/", "/issues/");
        var since = Since(pending.Since);
        var comments = await ListAsync<JsonElement>(issuePath + "/comments?since=" + since, cancellation);
        List<Signal> signals = [];
        void Append(string id, string body, JsonElement user, DateTimeOffset date, string url, bool review = false, SignalKind? forced = null)
        {
            var actor = Text(user, "login");
            if (date < pending.Since || actor.Equals(login, StringComparison.OrdinalIgnoreCase)) return;
            var kind = forced ?? Rules.Kind(body, actor, login, ownPr, review);
            if (kind is null || Rules.SafeWebUrl(url) is null) return;
            if (OptionalText(user, "type") == "Bot" && !actor.EndsWith("[bot]", StringComparison.Ordinal)) actor += "[bot]";
            signals.Add(new() { Id = id, Kind = kind.Value, Repository = thread.Repository.FullName,
                Title = Text(subject, "title"), Actor = actor, Excerpt = string.Concat(body.EnumerateRunes().Take(500)), Url = url, Date = date });
        }
        var body = OptionalText(subject, "body") ?? "";
        if (Rules.Mentions(body, login)) {
            var digest = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(body)));
            Append($"body:{thread.Id}:{digest}", body, subject.GetProperty("user"), Date(subject, "updated_at"), Text(subject, "html_url"), forced: SignalKind.Mention);
        }
        void AppendComment(JsonElement comment, string prefix)
        {
            var date = Date(comment, "updated_at");
            Append($"{prefix}:{comment.GetProperty("id").GetInt64()}:{date.ToUnixTimeSeconds()}.0",
                OptionalText(comment, "body") ?? "", comment.GetProperty("user"), date, Text(comment, "html_url"));
        }
        foreach (var comment in comments) AppendComment(comment, "comment");
        if (isPr) {
            foreach (var comment in await ListAsync<JsonElement>(uri.AbsolutePath + "/comments?since=" + since, cancellation)) AppendComment(comment, "inline");
            foreach (var review in await ListAsync<JsonElement>(uri.AbsolutePath + "/reviews", cancellation)) {
                var state = Text(review, "state");
                if (state == "PENDING" || !review.TryGetProperty("submitted_at", out var submitted) || submitted.ValueKind == JsonValueKind.Null ||
                    !review.TryGetProperty("user", out var user) || user.ValueKind == JsonValueKind.Null) continue;
                var label = state switch { "APPROVED" => "承認", "CHANGES_REQUESTED" => "変更リクエスト", "DISMISSED" => "レビューの取り消し", _ => "レビューコメント" };
                Append($"review:{review.GetProperty("id").GetInt64()}:{state}", label + "\n" + (OptionalText(review, "body") ?? ""),
                    user, submitted.GetDateTimeOffset(), Text(review, "html_url"), review: true);
            }
            foreach (var item in await ListAsync<JsonElement>(issuePath + "/events", cancellation)) {
                if (OptionalText(item, "event") != "review_requested" || !item.TryGetProperty("requested_reviewer", out var reviewer) ||
                    reviewer.ValueKind != JsonValueKind.Object || !string.Equals(OptionalText(reviewer, "login"), login, StringComparison.OrdinalIgnoreCase) ||
                    !item.TryGetProperty("actor", out var actor) || actor.ValueKind != JsonValueKind.Object ||
                    !item.TryGetProperty("id", out var id) || !item.TryGetProperty("created_at", out var created)) continue;
                Append("request:" + id.GetInt64(), "あなたへのレビュー依頼", actor, created.GetDateTimeOffset(), Text(subject, "html_url"), forced: SignalKind.ReviewRequest);
            }
        }
        return signals;
    }
    private static string Text(JsonElement item, string property) => item.GetProperty(property).GetString() ?? throw new InvalidDataException("GitHubからの応答が不完全です。");
    private static string? OptionalText(JsonElement item, string property) => item.TryGetProperty(property, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
    private static DateTimeOffset Date(JsonElement item, string property) => item.GetProperty(property).GetDateTimeOffset();
}
