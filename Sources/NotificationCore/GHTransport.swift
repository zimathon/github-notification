import Foundation

public struct GHTransport: GitHubTransport, ReviewCommentTransport {
    public init() {}

    public func get(_ path: String) async throws -> APIResponse {
        try await request(path, payload: nil)
    }

    public func postComment(_ path: String, body: String) async throws -> APIResponse {
        guard BotReviewRequest.isCommentPath(path) else {
            throw SignalError.message("レビュー依頼先が正しくありません。")
        }
        return try await request(path, payload: JSONEncoder().encode(["body": body]))
    }

    private func request(_ path: String, payload: Data?) async throws -> APIResponse {
        guard path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("\n"), !path.contains("\r") else {
            throw SignalError.message("APIの接続先が正しくありません。")
        }
        return try await Task.detached(priority: .utility) {
            let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
            guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                throw SignalError.message("GitHub CLIが見つかりません。ターミナルで brew install gh を実行してください。")
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: URL(fileURLWithPath: binary).resolvingSymlinksInPath().path)
            if let mode = attributes[.posixPermissions] as? NSNumber, mode.intValue & 0o022 != 0 {
                throw SignalError.message("GitHub CLIのファイル権限を確認してください。他のユーザーが書き換えられる状態になっています。")
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["api", "--hostname", "github.com", "--method", payload == nil ? "GET" : "POST", "--include",
                                 "-H", "Accept: application/vnd.github+json", "-H", "X-GitHub-Api-Version: 2022-11-28", path]
            if payload != nil { process.arguments! += ["--input", "-"] }
            process.environment = [
                "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
                "GH_HOST": "github.com", "GH_PROMPT_DISABLED": "1", "GH_PAGER": "cat", "NO_COLOR": "1"
            ]
            let input = Pipe()
            process.standardInput = payload == nil ? FileHandle.nullDevice : input

            let pipe = Pipe()
            process.standardOutput = pipe
            // Do not mix diagnostics into JSON/HTTP headers or retain potentially sensitive errors.
            process.standardError = FileHandle.nullDevice
            try process.run()
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30, execute: timeout)
            let forceStop = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 32, execute: forceStop)
            defer {
                timeout.cancel(); forceStop.cancel()
                if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
            }
            if let payload {
                try input.fileHandleForWriting.write(contentsOf: payload)
                try input.fileHandleForWriting.close()
            }
            var output = Data()
            while true {
                let chunk = pipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                output.append(chunk)
                if output.count > 32 * 1_024 * 1_024 {
                    kill(process.processIdentifier, SIGKILL)
                    process.waitUntilExit()
                    throw SignalError.message("GitHubからの応答が大きすぎるため、取得を中断しました。")
                }
            }
            process.waitUntilExit()
            if process.terminationReason == .uncaughtSignal {
                throw SignalError.message("GitHubとの通信がタイムアウトしました。次回の更新時に再試行します。")
            }
            return try Self.parse(output, exitCode: process.terminationStatus)
        }.value
    }

    public static func parse(_ data: Data, exitCode: Int32) throws -> APIResponse {
        guard let text = String(data: data, encoding: .utf8) else { throw SignalError.message("GitHubからの応答を読み取れませんでした。") }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard let boundary = normalized.range(of: "\n\n") else {
            throw SignalError.message("GitHubに接続できません。ターミナルで gh auth status --hostname github.com を実行し、ログイン状態を確認してください。")
        }
        let lines = normalized[..<boundary.lowerBound].split(separator: "\n")
        let status = lines.first?.split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard exitCode == 0, (200..<300).contains(status) else {
            switch status {
            case 401: throw SignalError.message("GitHubへの再ログインが必要です。ターミナルで gh auth login --hostname github.com を実行してください。")
            case 403, 429: throw SignalError.message("GitHubの権限が不足しているか、APIの利用上限に達しています。認証権限やSSOの認可を確認してください。5分後に再試行します。")
            case 404: throw SignalError.message("対象が削除されたか、読み取り権限がありません。")
            default: throw SignalError.message("GitHubとの通信に失敗しました（HTTP \(status)）。次回の更新時に再試行します。")
            }
        }
        let body = Data(normalized[boundary.upperBound...].utf8)
        guard headers["content-type"]?.contains("json") == true else { throw SignalError.message("GitHubから想定外の応答が返されました。") }
        return APIResponse(data: body, headers: headers)
    }
}
