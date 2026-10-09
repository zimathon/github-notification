namespace GitHubSignal.Core;

public static class PullRequestAuthorFilter
{
    public static bool Includes(Signal signal, PullRequestInfo? info, string? account, string filter)
    {
        if (filter is not ("mine" or "others")) return true;
        if (PullRequestInfo.ApiPath(signal) is null || string.IsNullOrEmpty(info?.Author) || string.IsNullOrEmpty(account)) return false;
        var own = info.Author.Equals(account, StringComparison.OrdinalIgnoreCase);
        return filter == "mine" ? own : !own;
    }
}
