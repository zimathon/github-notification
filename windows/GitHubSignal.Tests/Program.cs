using System.Text.Json;
using GitHubSignal.Core;

// A dependency-free test runner. Nonzero exit status fails CI; all HTTP is replaced with scripted responses.
var tests = new List<(string Name, Func<Task> Run)>();
void Test(string name, Action run) => tests.Add((name, () => { run(); return Task.CompletedTask; }));
void Async(string name, Func<Task> run) => tests.Add((name, run));
void Equal<T>(T expected, T actual) { if (!EqualityComparer<T>.Default.Equals(expected, actual)) throw new Exception($"Expected {expected}, got {actual}"); }
void Throws<T>(Action run) where T : Exception { try { run(); } catch (T) { return; } throw new Exception($"Expected {typeof(T).Name}"); }
var now = DateTimeOffset.Parse("2026-09-18T09:00:00Z");
Signal Signal(string id, string url = "https://github.com/acme/repo/pull/1#issuecomment-1") => new() { Id = id, Kind = SignalKind.Mention, Repository = "acme/repo", Title = "PR", Actor = "other", Excerpt = "@zimathon hello", Url = url, Date = now };
NotificationThread Thread(string id = "1") => new(id, "mention", now, new("PR", "https://api.github.com/repos/acme/repo/pulls/1", "PullRequest"), new("acme/repo"));
ApiResponse Response(string body, string? link = null) => new(body, new(StringComparer.OrdinalIgnoreCase) { ["date"] = now.ToString("R"), ["link"] = link ?? "", ["x-poll-interval"] = "120" });
var root = Path.Combine(Path.GetTempPath(), "GitHubSignal-tests-" + Guid.NewGuid());
Directory.CreateDirectory(root);
StateStore Store() => new(Path.Combine(root, Guid.NewGuid() + ".json"));

Test("Shared Mac/Windows mention and classification fixtures", () => {
    using var document = JsonDocument.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "notification-rules.json")));
    foreach (var item in document.RootElement.GetProperty("mentions").EnumerateArray()) Equal(item.GetProperty("expected").GetBoolean(), Rules.Mentions(item.GetProperty("body").GetString()!, item.GetProperty("login").GetString()!));
    foreach (var item in document.RootElement.GetProperty("classification").EnumerateArray()) Equal(item.GetProperty("expected").GetString(), Rules.Kind(item.GetProperty("body").GetString()!, item.GetProperty("actor").GetString()!, "zimathon", item.GetProperty("ownPR").GetBoolean(), item.GetProperty("review").GetBoolean())?.ToString().ToLowerInvariant());
});
Test("Approval label uses persisted state and preserves classification", () => {
    var approval = Signal("review:123:APPROVED") with { Kind = SignalKind.Review };
    var restored = Json.Read<Signal>(JsonSerializer.Serialize(approval, Json.Options));
    Equal("✅ 承認", restored.KindLabel); Equal(SignalKind.Review, restored.Kind);
    var mention = approval with { Kind = SignalKind.Mention };
    Equal("✅ 承認", mention.KindLabel); Equal(SignalKind.Mention, mention.Kind);
    Equal("✏️ 修正依頼", (approval with { Id = "review:123:CHANGES_REQUESTED" }).KindLabel);
    Equal("↩️ レビュー取消", (approval with { Id = "review:123:DISMISSED" }).KindLabel);
    Equal("📣 メンション", (mention with { Id = "review:123:COMMENTED" }).KindLabel);
    Equal("👀 レビュー依頼", (approval with { Id = "request:123", Kind = SignalKind.ReviewRequest }).KindLabel);
    Equal("💬 コメント", (approval with { Id = "comment:123", Kind = SignalKind.Comment }).KindLabel);
    foreach (var id in new[] { "review:123:COMMENTED", "comment:123:APPROVED", "request:123", "review::APPROVED" }) {
        var other = Signal(id) with { Kind = SignalKind.Review, Excerpt = "✅ 承認" };
        Equal(false, other.IsApproval); Equal("📝 レビュー", other.KindLabel);
    }
});
Test("Date filters use local calendar boundaries including DST", () => {
    var zone = TimeZoneInfo.FindSystemTimeZoneById("America/Los_Angeles");
    var current = DateTimeOffset.Parse("2026-03-09T12:00:00-07:00");
    var midnight = DateTimeOffset.Parse("2026-03-09T00:00:00-07:00");
    Equal(true, SignalDateRange.Includes(midnight, 1, current, zone));
    Equal(false, SignalDateRange.Includes(midnight.AddTicks(-1), 1, current, zone));
    var weekStart = DateTimeOffset.Parse("2026-03-03T00:00:00-08:00");
    Equal(true, SignalDateRange.Includes(weekStart, 7, current, zone));
    Equal(false, SignalDateRange.Includes(weekStart.AddTicks(-1), 7, current, zone));
    var monthStart = DateTimeOffset.Parse("2026-02-08T00:00:00-08:00");
    Equal(true, SignalDateRange.Includes(monthStart, 30, current, zone));
    Equal(false, SignalDateRange.Includes(monthStart.AddTicks(-1), 30, current, zone));
    Equal(true, SignalDateRange.Includes(current.AddSeconds(1), 1, current, zone));
    Equal(false, SignalDateRange.Includes(DateTimeOffset.Parse("2026-03-10T00:00:00-07:00"), 1, current, zone));
    Equal(true, SignalDateRange.Includes(current.AddYears(-2), 0, current, zone));
});
Test("Release notification deduplication survives restart", () => {
    var release = new AppRelease("v0.2.2", false, false, [new("GitHubSignal-0.2.2-windows-x64.zip", "uploaded")]);
    var store = Store(); var state = new InboxState();
    Equal(true, release.ShouldNotify("0.2.1", state.LastNotifiedRelease));
    state.LastNotifiedRelease = "0.2.2"; state.Settings.ViewDays = 7; store.Save(state);
    var restored = store.Load();
    Equal(false, release.ShouldNotify("0.2.1", restored.LastNotifiedRelease));
    Equal(7, restored.Settings.ViewDays);
    Equal(false, release.ShouldNotify("0.2.2", null));
    Equal(false, (release with { Prerelease = true }).ShouldNotify("0.2.1", null));
    Equal(true, (release with { TagName = "v0.2.3" }).ShouldNotify("0.2.1", restored.LastNotifiedRelease));
});
Test("Bulk acknowledgement preserves history and excluded PRs", () => {
    var one = Signal("one");
    var old = one with { Id = "old", Date = now.AddYears(-1) };
    var hidden = Signal("hidden", "https://github.com/acme/repo/pull/2");
    var state = new InboxState { Signals = [one, old, hidden] };
    state.AcknowledgeThreads([one.ThreadKey]);
    Equal(true, one.Acknowledged); Equal(true, old.Acknowledged); Equal(false, hidden.Acknowledged);
    Equal(3, state.Signals.Count);
});
Test("Opening acknowledges the selected scope only on browser success", () => {
    var state = new InboxState { Signals = [Signal("one"), Signal("two"), Signal("other", "https://github.com/acme/repo/pull/2")] };
    state.OpenSignal("one", true, _ => false); Equal(true, state.Signals.All(x => !x.Acknowledged));
    state.OpenSignal("one", false, _ => true); Equal(true, state.Signals[0].Acknowledged); Equal(false, state.Signals[1].Acknowledged);
    state.OpenSignal("one", true, _ => true); Equal(true, state.Signals[1].Acknowledged); Equal(false, state.Signals[2].Acknowledged);
    state.Signals[2] = state.Signals[2] with { Url = "file:///tmp/test" };
    bool called = false; state.OpenSignal("other", true, _ => { called = true; return true; });
    Equal(false, called); Equal(false, state.Signals[2].Acknowledged);
});
Test("PR grouping ignores comments, files, query and fragment", () => {
    Equal(Signal("1").ThreadKey, Signal("2", "https://github.com/acme/repo/pull/1/files?diff=split#x").ThreadKey);
    Equal(false, Signal("1").ThreadKey == Signal("2", "https://github.com/acme/repo/issues/2").ThreadKey);
});
Test("Browser URL allowlist", () => {
    foreach (var value in new[] { "http://github.com/acme/r", "https://evil.test", "https://github.com.evil.test/x", "https://me@github.com/x", "file:///tmp/x", "https://github.com:444/x" }) Equal<Uri?>(null, Rules.SafeWebUrl(value));
});
Test("Merging preserves acknowledgement and new revisions", () => {
    var state = new InboxState(); var original = Signal("comment:1:v1"); original.Acknowledged = true;
    state.Merge([original]); state.Merge([Signal("comment:1:v1"), Signal("comment:1:v2"), Signal("comment:1:v2")]);
    Equal(2, state.Signals.Count); Equal(true, state.Signals.Single(x => x.Id.EndsWith("v1")).Acknowledged);
});
Test("Acknowledged body does not revive after pruning", () => {
    var state = new InboxState(); var original = Signal("body:1:hash"); original.Acknowledged = true;
    state.Merge([original]); state.Prune(now.AddDays(8)); state.Merge([Signal(original.Id)]);
    Equal(0, state.Signals.Count); state.Merge([Signal("body:1:newhash")]); Equal(1, state.Signals.Count);
});
Test("Snooze, repeat and acknowledgement boundaries", () => {
    var signal = Signal("1"); Equal(true, signal.NeedsNotification(now, 30)); signal.LastNotifiedAt = now;
    Equal(false, signal.NeedsNotification(now.AddMinutes(29), 30)); Equal(true, signal.NeedsNotification(now.AddMinutes(30), 30));
    Equal(false, signal.NeedsNotification(now.AddDays(1), 0)); signal.LastNotifiedAt = null; signal.SnoozedUntil = now.AddHours(1);
    Equal(false, signal.NeedsNotification(now, 0)); Equal(true, signal.NeedsNotification(now.AddHours(1), 0));
    signal.Acknowledged = true; Equal(false, signal.NeedsNotification(now.AddDays(1), 30));
});
Test("Organization matching and input validation", () => {
    var settings = new Settings { Organizations = Settings.ParseOrganizations(" Acme, my-org、ACME\nuser ") };
    Equal("acme,my-org,user", string.Join(',', settings.Organizations)); Equal(true, settings.Includes("ACME/repo")); Equal(false, settings.Includes("acme-other/repo"));
    Throws<InvalidDataException>(() => Settings.ParseOrganizations("https://github.com/acme"));
});
Test("Queue keeps earliest retry boundary and persists atomically", () => {
    var state = new InboxState(); var store = Store(); state.Enqueue([Thread()], now.AddHours(-1), now);
    state.Enqueue([Thread()], now.AddMinutes(-30), now.AddMinutes(30)); state.Signals.Add(Signal("a")); store.Save(state);
    var restored = store.Load(); Equal(now.AddHours(-1), restored.Pending["1"].Since); Equal(1, restored.Signals.Count); Equal(false, File.Exists(store.Path + ".tmp"));
    restored.AcknowledgeThread(restored.Signals[0].ThreadKey); store.Save(restored); Equal(true, store.Load().Signals[0].Acknowledged);
});
Test("Corrupt/newer state fails closed without replacement", () => {
    foreach (var json in new[] { "not json", "{}", "{\"schemaVersion\":2,\"signals\":[],\"settings\":{}}" }) {
        var store = Store(); File.WriteAllText(store.Path, json); var engine = new InboxEngine(store, new Fake((_, _) => throw new Exception("Unexpected HTTP")));
        Equal(false, engine.Ready); engine.Mutate(x => x.Enabled = true); Equal(json, File.ReadAllText(store.Path));
    }
});
Test("HTTP errors omit body and require JSON content type", () => {
    Equal("[]", GhTransport.Parse("HTTP/2.0 200 OK\r\nContent-Type: application/json\r\nDate: Fri, 18 Sep 2026 09:00:00 GMT\r\n\r\n[]", 0).Body);
    Throws<InvalidDataException>(() => GhTransport.Parse("HTTP/2.0 200 OK\nContent-Type: text/html\n\nsecret", 0));
    Throws<InvalidDataException>(() => GhTransport.Parse("HTTP/2.0 401 Unauthorized\nContent-Type: application/json\n\nsecret", 1));
    try { GhTransport.Parse("HTTP/2.0 401 Unauthorized\nContent-Type: application/json\n\nsecret", 1); } catch (InvalidDataException error) { Equal(false, error.Message.Contains("secret")); }
});
Test("Release requires stable newer version with Windows asset", () => {
    var release = new AppRelease("v0.3.0", false, false, [new("GitHubSignal-0.3.0-windows-x64.zip", "uploaded")]);
    Equal(true, release.IsNewer("0.2.0")); Equal(false, release.IsNewer("0.3.0")); Equal(false, (release with { Prerelease = true }).IsNewer("0.2.0"));
    Equal(false, (release with { Assets = [] }).IsNewer("0.2.0")); Equal(false, (release with { TagName = "v0.3.0-beta" }).IsNewer("0.2.0"));
});
Async("Pagination never follows foreign Link URLs", async () => {
    var fake = new Fake((path, _) => Task.FromResult(Response("[]", path.EndsWith("page=1") ? "<https://evil.test>; rel=\"next\"" : null)));
    await new GitHubClient(fake).NotificationsAsync(now); Equal(2, fake.Paths.Count); Equal(true, fake.Paths.All(x => x.StartsWith("/notifications?"))); Equal(true, fake.Paths[1].EndsWith("page=2"));
});
Async("Foreign subject URL is rejected before HTTP", async () => {
    var fake = new Fake((_, _) => throw new Exception("Unexpected HTTP"));
    try { await new GitHubClient(fake).SignalsAsync(new(Thread() with { Subject = new("PR", "https://evil.test/pull/1", "PullRequest") }, now), "zimathon"); throw new Exception("Accepted foreign URL"); }
    catch (InvalidDataException) { Equal(0, fake.Paths.Count); }
});
Async("Comment, self exclusion, inline review and repeated requests", async () => {
    var fake = new Fake((path, _) => Task.FromResult(Response(path switch {
        "/repos/acme/repo/pulls/1" => """{"user":{"login":"zimathon"},"title":"PR","body":"","updated_at":"2026-09-18T09:00:00Z","html_url":"https://github.com/acme/repo/pull/1"}""",
        var p when p.Contains("/issues/1/comments") => """[{"id":1,"user":{"login":"other"},"body":"hello","updated_at":"2026-09-18T09:00:00Z","html_url":"https://github.com/acme/repo/pull/1#issuecomment-1"},{"id":2,"user":{"login":"zimathon"},"body":"self","updated_at":"2026-09-18T09:00:00Z","html_url":"https://github.com/acme/repo/pull/1#issuecomment-2"}]""",
        var p when p.Contains("/pulls/1/comments") => """[{"id":3,"user":{"login":"other"},"body":"@zimathon inline","updated_at":"2026-09-18T09:00:00Z","html_url":"https://github.com/acme/repo/pull/1#discussion-3"}]""",
        var p when p.Contains("/reviews?") => """[{"id":4,"state":"APPROVED","user":{"login":"other"},"body":"","submitted_at":"2026-09-18T09:00:00Z","html_url":"https://github.com/acme/repo/pull/1#review-4"}]""",
        var p when p.Contains("/events?") => """[{"id":5,"event":"review_requested","actor":{"login":"other"},"requested_reviewer":{"login":"zimathon"},"created_at":"2026-09-18T09:00:00Z"},{"id":6,"event":"review_requested","actor":{"login":"other"},"requested_reviewer":{"login":"zimathon"},"created_at":"2026-09-18T09:00:00Z"}]""",
        _ => throw new Exception(path)
    })));
    var signals = await new GitHubClient(fake).SignalsAsync(new(Thread(), now.AddHours(-1)), "zimathon");
    Equal(5, signals.Count); Equal(1, signals.Count(x => x.Kind == SignalKind.Comment)); Equal(1, signals.Count(x => x.Kind == SignalKind.Mention)); Equal(1, signals.Count(x => x.Kind == SignalKind.Review)); Equal(2, signals.Count(x => x.Kind == SignalKind.ReviewRequest)); Equal(1, signals.Select(x => x.ThreadKey).Distinct().Count());
});
Async("Failed detail survives persisted cursor advance", async () => {
    var store = Store(); store.Save(new InboxState { Enabled = true });
    var fake = new Fake((path, _) => path == "/user" ? Task.FromResult(Response("{\"login\":\"zimathon\"}")) : path.StartsWith("/notifications") ? Task.FromResult(Response(JsonSerializer.Serialize(new[] { Thread() }, Json.Options))) : throw new IOException("Detail unavailable"));
    var engine = new InboxEngine(store, fake); await engine.SyncAsync();
    Equal(1, store.Load().Pending.Count); Equal(now, store.Load().Cursor); Equal(0, store.Load().Processed.Count); Equal(true, engine.Error!.Contains("1件"));
});
Async("Failed entries rotate so healthy older notifications are not starved", async () => {
    var store = Store();
    var state = new InboxState { Enabled = true };
    var threads = Enumerable.Range(1, 4).Select(i => Thread(i.ToString()) with { UpdatedAt = now.AddMinutes(-i), Subject = new("PR", $"https://api.github.com/repos/acme/repo/issues/{i}", "Issue") }).ToArray();
    state.Enqueue(threads, now.AddDays(-1), now); store.Save(state);
    var fake = new Fake((path, _) => {
        if (path == "/user") return Task.FromResult(Response("{\"login\":\"zimathon\"}"));
        if (path.StartsWith("/notifications")) return Task.FromResult(Response(JsonSerializer.Serialize(threads, Json.Options)));
        if (path == "/repos/acme/repo/issues/4") return Task.FromResult(Response("""{"title":"healthy","user":{"login":"other"},"body":"@zimathon hello","updated_at":"2026-09-18T09:00:00Z","html_url":"https://github.com/acme/repo/issues/4"}"""));
        if (path.StartsWith("/repos/acme/repo/issues/4/comments")) return Task.FromResult(Response("[]"));
        throw new InvalidDataException("permanent failure");
    });
    await new InboxEngine(store, fake).SyncAsync();
    Equal(4, store.Load().Pending.Count); Equal(0, store.Load().Signals.Count);
    // Reconstruct the engine to exercise persisted scheduling without waiting five minutes.
    await new InboxEngine(store, fake).SyncAsync();
    Equal(3, store.Load().Pending.Count); Equal(1, store.Load().Signals.Count);
    Equal("healthy", store.Load().Signals[0].Title);
});
Async("Account change stops before fetching notifications", async () => {
    var store = Store(); store.Save(new InboxState { Enabled = true, Account = "zimathon" });
    var fake = new Fake((_, _) => Task.FromResult(Response("{\"login\":\"other\"}")));
    var engine = new InboxEngine(store, fake); await engine.SyncAsync(); Equal(1, fake.Paths.Count); Equal("zimathon", store.Load().Account); Equal(true, engine.Error!.Contains("アカウント"));
});
Async("Pause cancels in-flight request and prevents duplicate sync", async () => {
    var store = Store(); store.Save(new InboxState { Enabled = true });
    var entered = new TaskCompletionSource();
    var fake = new Fake(async (_, token) => { entered.SetResult(); await Task.Delay(Timeout.Infinite, token); return Response("[]"); });
    var engine = new InboxEngine(store, fake); var active = engine.SyncAsync(); await entered.Task;
    await engine.SyncAsync(); engine.Pause(); await active; Equal(1, fake.Paths.Count); Equal(false, engine.Syncing); Equal(false, store.Load().Enabled);
});
Test("Notification filtering differs from display filters", () => {
    var store = Store(); var engine = new InboxEngine(store, new Fake((_, _) => throw new Exception()));
    engine.Mutate(x => { x.Enabled = true; x.Signals.Add(Signal("1")); x.Signals.Add(Signal("2") with { Actor = "bot[bot]" }); x.Settings.IncludeBots = false; x.Settings.ViewRepository = "other/repo"; });
    Equal(1, engine.Due(now).Count); Equal(1, engine.PendingCount); engine.Mutate(x => x.Settings.Organizations = ["other"]); Equal(0, engine.Due(now).Count); Equal(0, engine.PendingCount);
});
Async("PR state updates without new signals and preserves acknowledgement", async () => {
    var existing = Signal("existing"); existing.Acknowledged = true;
    var state = new InboxState { Signals = [existing] };
    foreach (var item in new (string State, bool Draft, bool Merged, string Expected)[] { ("open", false, false, "open"), ("open", true, false, "draft"), ("closed", false, true, "merged"), ("closed", true, false, "closed") }) {
        var subject = JsonSerializer.Serialize(new { title = "PR", body = "", user = new { login = "zimathon" }, html_url = "https://github.com/acme/repo/pull/1", updated_at = now, state = item.State, draft = item.Draft, merged = item.Merged });
        var fake = new Fake((path, _) => Task.FromResult(Response(path == "/repos/acme/repo/pulls/1" ? subject : "[]")));
        var batch = await new GitHubClient(fake).DetailsAsync(new(Thread(), now.AddDays(-1)), "zimathon");
        Equal(0, batch.Signals.Count); state.Merge(batch);
        var store = Store(); store.Save(state); var restored = store.Load();
        Equal(item.Expected, restored.PullRequests[existing.ThreadKey].Status);
        Equal(true, restored.Signals[0].Acknowledged); Equal(1, restored.Signals.Count);
    }
});
Async("PR backfill is bounded and keeps cached state on failure", async () => {
    var store = Store();
    var state = new InboxState { Enabled = true, Signals = Enumerable.Range(1, 5).Select(i => Signal(i.ToString(), $"https://github.com/acme/repo/pull/{i}")).ToList() };
    store.Save(state);
    var fake = new Fake((path, _) => Task.FromResult(Response(path == "/user" ? "{\"login\":\"zimathon\"}" : path.StartsWith("/notifications") ? "[]" : "{\"state\":\"closed\",\"merged\":true,\"draft\":false}")));
    await new InboxEngine(store, fake).SyncAsync();
    Equal(3, fake.Paths.Count(x => x.StartsWith("/repos/"))); Equal(3, store.Load().PullRequests.Count);
    var failed = new Fake((path, _) => path == "/user" ? Task.FromResult(Response("{\"login\":\"zimathon\"}")) : path.StartsWith("/notifications") ? Task.FromResult(Response("[]")) : throw new IOException("offline"));
    await new InboxEngine(store, failed).SyncAsync();
    Equal(3, store.Load().PullRequests.Count);
    Equal(true, store.Load().PullRequests.Values.All(x => x.Status == "merged"));
    Equal("/repos/pull/pull/pulls/1", PullRequestInfo.ApiPath(Signal("path", "https://github.com/pull/pull/pull/1/files")));
    foreach (var url in new[] { "https://evil.test/acme/repo/pull/1", "https://github.com/acme/repo/issues/1", "https://github.com/acme/repo/pull/no" }) Equal<string?>(null, PullRequestInfo.ApiPath(Signal("bad", url)));
});
Async("Failed pending and future cache do not block healthy PR refresh", async () => {
    var store = Store(); var signal = Signal("healthy");
    var state = new InboxState { Enabled = true, Signals = [signal] };
    var bad = Thread("bad") with { Subject = new("bad", "https://evil.test/repos/acme/repo/pulls/2", "PullRequest") };
    state.Pending[bad.Id] = new(bad, now.AddDays(-1));
    state.PullRequests[signal.ThreadKey] = new("open", DateTimeOffset.UtcNow.AddDays(1));
    store.Save(state);
    var fake = new Fake((path, _) => Task.FromResult(Response(path == "/user" ? "{\"login\":\"zimathon\"}" : path.StartsWith("/notifications") ? "[]" : "{\"state\":\"closed\",\"merged\":true}")));
    await new InboxEngine(store, fake).SyncAsync();
    Equal(1, store.Load().Pending.Count); Equal("merged", store.Load().PullRequests[signal.ThreadKey].Status);
    Equal(1, fake.Paths.Count(x => x.StartsWith("/repos/")));
    state = store.Load(); state.PullRequests[signal.ThreadKey] = new("merged", DateTimeOffset.UtcNow.AddHours(-1)); store.Save(state);
    var malformed = new Fake((path, _) => Task.FromResult(Response(path == "/user" ? "{\"login\":\"zimathon\"}" : path.StartsWith("/notifications") ? "[]" : "{}")));
    await new InboxEngine(store, malformed).SyncAsync();
    Equal("merged", store.Load().PullRequests[signal.ThreadKey].Status);
});
int failures = 0;
try {
    foreach (var test in tests) {
        try { await test.Run(); Console.WriteLine("PASS " + test.Name); }
        catch (Exception error) { failures++; Console.Error.WriteLine("FAIL " + test.Name + "\n" + error); }
    }
} finally { Directory.Delete(root, true); }
Console.WriteLine($"{tests.Count - failures}/{tests.Count} passed");
return failures == 0 ? 0 : 1;

sealed class Fake(Func<string, CancellationToken, Task<ApiResponse>> respond) : IGitHubTransport
{
    public List<string> Paths { get; } = [];
    public Task<ApiResponse> GetAsync(string path, CancellationToken cancellation = default) { Paths.Add(path); return respond(path, cancellation); }
}
