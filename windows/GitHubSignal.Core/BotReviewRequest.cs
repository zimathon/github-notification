using System.Text.RegularExpressions;

namespace GitHubSignal.Core;

public enum ReviewBot { Codex, Claude }

public sealed record BotReviewRequest(string Path, string Url, string Title, ReviewBot Bot)
{
    public string Id => Path + ":" + Bot;
    public string Body => Bot == ReviewBot.Codex ? "@codex review" : "@claude このPRをレビューしてください。コードの変更やcommit・pushは行わず、指摘をコメントしてください。";
    public static bool IsCommentPath(string path) => !path.Contains('\n') && !path.Contains('\r') && !path.Split('/').Any(part => part is "." or "..") &&
        Regex.IsMatch(path, @"\A/repos/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/issues/[0-9]+/comments\z");
    public static BotReviewRequest? Create(Signal signal, ReviewBot bot)
    {
        if (PullRequestInfo.ApiPath(signal) is not { } apiPath) return null;
        var parts = apiPath.Split('/');
        var path = $"/repos/{parts[2]}/{parts[3]}/issues/{parts[5]}/comments";
        return IsCommentPath(path) ? new(path, $"https://github.com/{parts[2]}/{parts[3]}/pull/{parts[5]}", signal.Title, bot) : null;
    }
    public static BotReviewRequest[] Plan(IEnumerable<Signal> signals, IEnumerable<ReviewBot> bots)
    {
        var selected = bots.ToHashSet();
        return signals.SelectMany(signal => Enum.GetValues<ReviewBot>().Where(selected.Contains)
            .Select(bot => Create(signal, bot))).OfType<BotReviewRequest>().DistinctBy(x => x.Id).ToArray();
    }
}

public sealed class ReviewAccountException(string message) : Exception(message);

public interface IReviewCommentTransport : IGitHubTransport
{
    Task<ApiResponse> PostCommentAsync(string path, string body, CancellationToken cancellation = default);
}

public sealed class BotReviewClient(IReviewCommentTransport transport)
{
    // Never retry a write automatically: GitHub may have accepted it before a timeout.
    public async Task SendAsync(BotReviewRequest request, string account, CancellationToken cancellation = default)
    {
        if (!BotReviewRequest.IsCommentPath(request.Path)) throw new InvalidDataException("レビュー依頼先が正しくありません。");
        if (string.IsNullOrEmpty(account)) throw new ReviewAccountException("未送信：GitHubアカウントが一致しません。");
        string? login;
        try {
            var response = await transport.GetAsync("/user", cancellation);
            using var data = System.Text.Json.JsonDocument.Parse(response.Body);
            login = data.RootElement.GetProperty("login").GetString();
        } catch (Exception) { throw new ReviewAccountException("未送信：アカウントを確認できません。"); }
        if (!string.Equals(login, account, StringComparison.OrdinalIgnoreCase))
            throw new ReviewAccountException("未送信：GitHubアカウントが一致しません。");
        await transport.PostCommentAsync(request.Path, request.Body, cancellation);
    }
}
