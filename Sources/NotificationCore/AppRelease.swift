import Foundation

public struct AppRelease: Decodable {
    public let tag_name: String
    public let draft: Bool
    public let prerelease: Bool

    // Only stable three-component versions are eligible for this app's releases.
    public static func version(_ value: String) -> [Int]? {
        let text = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let numbers = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return nil }
            return Int(part)
        }
        return numbers.count == 3 ? numbers : nil
    }

    public func isNewer(than current: String) -> Bool {
        guard !draft, !prerelease, let latest = Self.version(tag_name),
              let installed = Self.version(current) else { return false }
        return installed.lexicographicallyPrecedes(latest)
    }

    public func shouldNotify(installed: String, lastNotified: String?) -> Bool {
        isNewer(than: installed) && Self.version(tag_name) != lastNotified.flatMap(Self.version)
    }

    public static let downloadURL = URL(string: "https://github.com/zimathon/github-notification/releases/latest")!

    public static func fetch(session: URLSession = .shared) async throws -> AppRelease {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/zimathon/github-notification/releases/latest")!)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("GitHubSignal", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let release = try JSONDecoder().decode(Self.self, from: data)
        guard version(release.tag_name) != nil else { throw URLError(.cannotParseResponse) }
        return release
    }
}
