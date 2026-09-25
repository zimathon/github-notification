using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace GitHubSignal.Core;

[JsonConverter(typeof(JsonStringEnumConverter<SignalKind>))]
public enum SignalKind { Mention, ReviewRequest, Comment, Review }

public sealed record Signal
{
    public required string Id { get; init; }
    public required SignalKind Kind { get; init; }
    public required string Repository { get; init; }
    public required string Title { get; init; }
    public required string Actor { get; init; }
    public required string Excerpt { get; init; }
    public required string Url { get; init; }
    public required DateTimeOffset Date { get; init; }
    public bool Acknowledged { get; set; }
    public DateTimeOffset? SnoozedUntil { get; set; }
    public DateTimeOffset? LastNotifiedAt { get; set; }
    [JsonIgnore] public bool IsApproval => Regex.IsMatch(Id, @"^review:[0-9]+:APPROVED$", RegexOptions.CultureInvariant);
    [JsonIgnore] public string KindLabel => IsApproval ? "Approve" : Rules.Label(Kind);
    [JsonIgnore] public string Preview => Rules.Preview(Excerpt);
    [JsonIgnore] public string ActorLabel => "@" + Actor;
    [JsonIgnore] public string TimeLabel => Date.ToLocalTime().ToString("MM/dd HH:mm");
    [JsonIgnore] public string ThreadKey => Rules.ThreadKey(Repository, Url);
    public bool NeedsNotification(DateTimeOffset now, int reminderMinutes) =>
        !Acknowledged && (SnoozedUntil is null || SnoozedUntil <= now) &&
        (LastNotifiedAt is null || reminderMinutes > 0 && now - LastNotifiedAt >= TimeSpan.FromMinutes(reminderMinutes));
}

public sealed class Settings
{
    public int PollSeconds { get; set; } = 120;
    public int ReminderMinutes { get; set; } = 30;
    public bool IncludeBots { get; set; } = true;
    public List<string> Organizations { get; set; } = [];
    public string ViewOrganization { get; set; } = "";
    public string ViewRepository { get; set; } = "";
    public bool Includes(string repository) => Organizations.Count == 0 ||
        Organizations.Contains(repository.Split('/')[0], StringComparer.OrdinalIgnoreCase);
    public static List<string> ParseOrganizations(string input)
    {
        var names = Regex.Split(input.ToLowerInvariant(), @"[,、\s]+").Where(x => x.Length > 0).Distinct().Order().ToList();
        if (names.Any(x => !Regex.IsMatch(x, @"^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$")))
            throw new InvalidDataException("組織名かユーザー名をカンマ区切りで入力してください。URLは不要です。");
        return names;
    }
}

public sealed record SubjectRef(string Title, string? Url, string Type);
public sealed record RepositoryRef([property: JsonPropertyName("full_name")] string FullName);
public sealed record NotificationThread(string Id, string Reason,
    [property: JsonPropertyName("updated_at")] DateTimeOffset UpdatedAt, SubjectRef Subject, RepositoryRef Repository);
public sealed record PendingThread(NotificationThread Thread, DateTimeOffset Since, DateTimeOffset? LastAttemptAt = null);

public sealed class InboxState
{
    [JsonRequired] public int SchemaVersion { get; set; } = 1;
    public bool Enabled { get; set; }
    public string? Account { get; set; }
    public DateTimeOffset? Cursor { get; set; }
    [JsonRequired] public List<Signal> Signals { get; set; } = [];
    public Dictionary<string, PendingThread> Pending { get; set; } = [];
    public Dictionary<string, DateTimeOffset> Processed { get; set; } = [];
    public HashSet<string> AcknowledgedBodyIds { get; set; } = [];
    [JsonRequired] public Settings Settings { get; set; } = new();
    public void Merge(IEnumerable<Signal> incoming)
    {
        var ids = Signals.Select(x => x.Id).ToHashSet();
        Signals.AddRange(incoming.Where(x => !AcknowledgedBodyIds.Contains(x.Id) && ids.Add(x.Id)));
        Signals.Sort((a, b) => b.Date.CompareTo(a.Date));
    }
    public void Enqueue(IEnumerable<NotificationThread> threads, DateTimeOffset since, DateTimeOffset cursor)
    {
        foreach (var thread in threads)
        {
            if (Processed.TryGetValue(thread.Id, out var processed) && processed >= thread.UpdatedAt) continue;
            var boundary = Pending.TryGetValue(thread.Id, out var old) && old.Since < since ? old.Since : since;
            Pending[thread.Id] = new(thread, boundary, old?.LastAttemptAt);
        }
        Cursor = cursor;
    }
    public void OpenSignal(string id, bool entireThread, Func<Uri, bool> opener)
    {
        var signal = Signals.FirstOrDefault(x => x.Id == id);
        if (signal is null || Rules.SafeWebUrl(signal.Url) is not { } uri || !opener(uri)) return;
        foreach (var item in Signals.Where(x => entireThread ? x.ThreadKey == signal.ThreadKey : x.Id == id)) item.Acknowledged = true;
    }
    public void AcknowledgeThread(string key)
    {
        foreach (var signal in Signals.Where(x => x.ThreadKey == key)) signal.Acknowledged = true;
    }
    public void Prune(DateTimeOffset cutoff)
    {
        foreach (var signal in Signals.Where(x => x.Acknowledged && x.Id.StartsWith("body:", StringComparison.Ordinal)))
            AcknowledgedBodyIds.Add(signal.Id);
        Signals.RemoveAll(x => x.Acknowledged && x.Date < cutoff);
        foreach (var key in Processed.Where(x => x.Value < cutoff).Select(x => x.Key).ToArray()) Processed.Remove(key);
    }
}

public static class Rules
{
    public static string Label(SignalKind kind) => kind switch {
        SignalKind.Mention => "メンション", SignalKind.ReviewRequest => "レビュー依頼",
        SignalKind.Comment => "自分のPRへのコメント", _ => "自分のPRへのレビュー"
    };
    public static bool Mentions(string body, string login) => Regex.IsMatch(body,
        @"(?<![A-Za-z0-9_@/])@" + Regex.Escape(login) + @"(?![A-Za-z0-9_/-])", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    public static SignalKind? Kind(string body, string actor, string login, bool ownPr, bool review)
    {
        if (actor.Equals(login, StringComparison.OrdinalIgnoreCase)) return null;
        if (Mentions(body, login)) return SignalKind.Mention;
        return ownPr ? review ? SignalKind.Review : SignalKind.Comment : null;
    }
    public static Uri? SafeWebUrl(string value) => Uri.TryCreate(value, UriKind.Absolute, out var uri) &&
        uri.Scheme == "https" && uri.Host == "github.com" && uri.UserInfo == "" && uri.IsDefaultPort ? uri : null;
    public static string ThreadKey(string repository, string url)
    {
        if (SafeWebUrl(url) is not { } uri) return repository.ToLowerInvariant() + ":" + url;
        var path = Regex.Match(uri.AbsolutePath, @"^(/[^/]+/[^/]+/(?:pull|issues)/[0-9]+)(?:/|$)");
        return repository.ToLowerInvariant() + ":https://github.com" + (path.Success ? path.Groups[1].Value : uri.AbsolutePath);
    }
    public static string Preview(string source)
    {
        var text = Regex.Replace(source, @"<!--[\s\S]*?(?:-->|$)", "");
        text = Regex.Replace(text, @"!?\[([^\]]+)\]\([^\n)]*\)", "$1");
        text = Regex.Replace(text, @"</?[A-Za-z][^>]*(?:>|$)", "");
        text = Regex.Replace(text, @"(?m)^\s{0,3}(?:#{1,6}\s+|```[^\n]*)|\*\*|__|`", "");
        return string.Join(" · ", System.Net.WebUtility.HtmlDecode(text).Split('\n').Select(x => x.Trim()).Where(x => x.Length > 0));
    }
}

public static class Json
{
    public static readonly JsonSerializerOptions Options = new() { PropertyNameCaseInsensitive = true, PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
    public static T Read<T>(string data) => JsonSerializer.Deserialize<T>(data, Options) ?? throw new InvalidDataException("データが空です。");
}
