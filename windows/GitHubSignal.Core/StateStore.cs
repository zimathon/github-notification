using System.Text.Json;

namespace GitHubSignal.Core;

public sealed class StateStore(string path)
{
    public string Path { get; } = path;
    public InboxState Load()
    {
        if (!File.Exists(Path)) return new();
        var state = Json.Read<InboxState>(File.ReadAllText(Path));
        // Never silently replace corrupt or newer data with a new inbox.
        if (state.SchemaVersion != 1 || state.Signals is null || state.Pending is null || state.Processed is null ||
            state.AcknowledgedBodyIds is null || state.Settings is null || state.Settings.Organizations is null ||
            state.Signals.Any(x => x is null || x.Id is null || x.Url is null || x.Actor is null || x.Repository is null || x.Title is null || x.Excerpt is null) || state.Pending.Any(x => x.Value is null || x.Value.Thread is null || x.Value.Thread.Subject is null || x.Value.Thread.Repository is null))
            throw new InvalidDataException("保存データを読み込めません。ファイルを退避して内容を確認してください。");
        return state;
    }
    public void Save(InboxState state)
    {
        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(Path)!);
        var temporary = Path + ".tmp";
        try {
            using (var stream = new FileStream(temporary, FileMode.Create, FileAccess.Write, FileShare.None)) {
                JsonSerializer.Serialize(stream, state, Json.Options);
                stream.Flush(true);
            }
            File.Move(temporary, Path, overwrite: true);
        } finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
