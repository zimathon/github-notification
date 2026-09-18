namespace GitHubSignal.Core;

// All methods are called on the WPF dispatcher. Await preserves that context; tests run serially.
public sealed class InboxEngine
{
    private readonly StateStore store;
    private readonly GitHubClient client;
    private CancellationTokenSource? currentSync;
    private Task activeSync = Task.CompletedTask;
    public Task WaitForIdleAsync() => activeSync;
    private int serverPoll = 60;
    public InboxState State { get; private set; } = new();
    public bool Ready { get; private set; } = true;
    public bool Syncing { get; private set; }
    public string? Error { get; private set; }
    public DateTimeOffset NextSync { get; private set; } = DateTimeOffset.MinValue;
    public DateTimeOffset? LastSync { get; private set; }
    public event Action? Changed;
    public IEnumerable<Signal> Included => State.Signals.Where(x => State.Settings.Includes(x.Repository));
    public int PendingCount => Included.Where(x => !x.Acknowledged).Select(x => x.ThreadKey).Distinct().Count();
    public InboxEngine(StateStore store, IGitHubTransport transport)
    {
        this.store = store;
        client = new(transport);
        try { State = store.Load(); }
        catch (Exception exception) when (exception is IOException or InvalidDataException or System.Text.Json.JsonException or UnauthorizedAccessException) {
            Ready = false;
            Error = "保存データを読み込めないため停止しています：" + exception.Message;
        }
    }
    public void Mutate(Action<InboxState> change)
    {
        if (!Ready) return;
        change(State);
        Persist();
        Changed?.Invoke();
    }
    public void Pause()
    {
        currentSync?.Cancel();
        Mutate(state => state.Enabled = false);
    }
    private bool Persist()
    {
        if (!Ready) return false;
        try { store.Save(State); return true; }
        catch (Exception exception) when (exception is IOException or InvalidDataException or UnauthorizedAccessException) {
            Ready = false;
            Error = "保存できないため停止しています：" + exception.Message;
            return false;
        }
    }
    public Task SyncAsync(CancellationToken cancellation = default)
    {
        if (!Ready || !State.Enabled || Syncing || DateTimeOffset.UtcNow < NextSync) return Task.CompletedTask;
        return activeSync = RunSyncAsync(cancellation);
    }
    private async Task RunSyncAsync(CancellationToken cancellation)
    {
        Syncing = true;
        Error = null;
        currentSync = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        var token = currentSync.Token;
        NextSync = DateTimeOffset.UtcNow.AddSeconds(Math.Max(Math.Clamp(State.Settings.PollSeconds, 120, 600), serverPoll));
        Changed?.Invoke();
        try {
            var (login, now) = await client.AccountAsync(token);
            if (State.Account is { } account && !account.Equals(login, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException($"GitHub CLIのアカウントが変わっています。{account} に戻してから再開してください。");
            State.Account = login;
            var since = State.Cursor?.AddMinutes(-30) ?? now.AddDays(-1);
            var batch = await client.NotificationsAsync(since, token);
            serverPoll = batch.PollInterval;
            NextSync = DateTimeOffset.UtcNow.AddSeconds(Math.Max(Math.Clamp(State.Settings.PollSeconds, 120, 600), serverPoll));
            State.Enqueue(batch.Threads, since, batch.ServerDate);
            if (!Persist()) return;
            int failures = 0;
            foreach (var pending in State.Pending.Values.OrderBy(x => x.LastAttemptAt ?? DateTimeOffset.MinValue).ThenByDescending(x => x.Thread.UpdatedAt).ToArray()) {
                token.ThrowIfCancellationRequested();
                if (!Ready || !State.Enabled) break;
                // Rotate failed entries behind untouched work without discarding retry history.
                State.Pending[pending.Thread.Id] = pending with { LastAttemptAt = DateTimeOffset.UtcNow };
                try {
                    var signals = await client.SignalsAsync(pending, login, token);
                    State.Merge(signals);
                    State.Processed[pending.Thread.Id] = pending.Thread.UpdatedAt;
                    State.Pending.Remove(pending.Thread.Id);
                    if (!Persist()) return;
                } catch (OperationCanceledException) { throw; }
                catch (Exception exception) when (exception is IOException or InvalidDataException or System.Text.Json.JsonException or TimeoutException or InvalidOperationException or KeyNotFoundException or FormatException) {
                    Error = exception.Message;
                    if (!Persist()) return;
                    if (++failures >= 3) break;
                }
            }
            if (State.Pending.Count == 0) LastSync = DateTimeOffset.UtcNow;
            else {
                Error = $"{State.Pending.Count}件を取得できませんでした。5分後に再試行します。\n" + Error;
                NextSync = DateTimeOffset.UtcNow.AddSeconds(Math.Max(300, serverPoll));
            }
            State.Prune(batch.ServerDate.AddDays(-7));
            Persist();
        } catch (OperationCanceledException) { }
        catch (Exception exception) when (exception is IOException or InvalidDataException or System.Text.Json.JsonException or TimeoutException or InvalidOperationException or KeyNotFoundException or FormatException or System.ComponentModel.Win32Exception) {
            Error = exception.Message;
            NextSync = DateTimeOffset.UtcNow.AddSeconds(Math.Max(300, serverPoll));
        } finally {
            currentSync.Dispose(); currentSync = null;
            Syncing = false;
            Changed?.Invoke();
        }
    }
    public List<Signal> Due(DateTimeOffset now) => !Ready || !State.Enabled ? [] : Included.Where(x =>
        x.NeedsNotification(now, State.Settings.ReminderMinutes) && (State.Settings.IncludeBots || !x.Actor.EndsWith("[bot]", StringComparison.OrdinalIgnoreCase))).ToList();
    public void MarkNotified(IEnumerable<Signal> signals, DateTimeOffset now)
    {
        if (!Ready) return;
        foreach (var signal in signals) signal.LastNotifiedAt = now;
        Persist(); Changed?.Invoke();
    }
}
