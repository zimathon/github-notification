using System.Text.Json.Serialization;

namespace GitHubSignal.Core;

public sealed record ReleaseAsset(string Name, string State);
public sealed record AppRelease([property: JsonPropertyName("tag_name")] string TagName, bool Draft, bool Prerelease, List<ReleaseAsset> Assets)
{
    public static readonly Uri DownloadUrl = new("https://github.com/zimathon/github-notification/releases/latest");
    public static Version? ParseVersion(string value) => value is not null && System.Text.RegularExpressions.Regex.IsMatch(value, @"^v?[0-9]+\.[0-9]+\.[0-9]+$") &&
        Version.TryParse(value.TrimStart('v'), out var version) ? version : null;
    public bool IsNewer(string installed) => !Draft && !Prerelease && ParseVersion(TagName) is { } latest &&
        ParseVersion(installed) is { } current && latest > current &&
        Assets is not null && Assets.Any(x => x is not null && x.Name is not null && x.State == "uploaded" && x.Name.EndsWith("-windows-x64.zip", StringComparison.OrdinalIgnoreCase));
    public static async Task<AppRelease> FetchAsync(HttpClient client, CancellationToken cancellation = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, "https://api.github.com/repos/zimathon/github-notification/releases/latest");
        request.Headers.UserAgent.ParseAdd("GitHubSignal/0.2.0");
        request.Headers.Accept.ParseAdd("application/vnd.github+json");
        using var response = await client.SendAsync(request, cancellation);
        response.EnsureSuccessStatusCode();
        return Json.Read<AppRelease>(await response.Content.ReadAsStringAsync(cancellation));
    }
}
