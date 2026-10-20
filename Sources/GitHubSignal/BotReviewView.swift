import SwiftUI
import NotificationCore

struct BotReviewView: View {
    @ObservedObject var model: AppModel
    let signals: [Signal]
    let account: String
    @Environment(\.dismiss) private var dismiss
    @State private var bots: Set<ReviewBot> = [.codex, .claude]
    @State private var results: [String: String] = [:]
    @State private var sending = false

    private var requests: [BotReviewRequest] { BotReviewRequest.plan(signals: signals, bots: bots) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AIレビューを依頼").font(.headline)
            Text("投稿アカウント：@" + account).textSelection(.enabled)
            HStack {
                ForEach(ReviewBot.allCases) { bot in
                    Toggle(bot.title, isOn: Binding(
                        get: { bots.contains(bot) },
                        set: { if $0 { bots.insert(bot) } else { bots.remove(bot) } }
                    )).toggleStyle(.checkbox)
                }
            }.disabled(sending || !results.isEmpty)
            Text("ログイン中のGitHubアカウントで、各PRに次のコメントを投稿する。両方を選ぶとPRごとに2件投稿する。")
                .fixedSize(horizontal: false, vertical: true)
            ForEach(ReviewBot.allCases.filter { bots.contains($0) }) { bot in
                Text(bot.comment).textSelection(.enabled)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(requests) { request in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(request.title).fontWeight(.medium)
                            Text(request.url.absoluteString).foregroundStyle(.secondary).textSelection(.enabled)
                            Text("\(request.bot.title)：\(results[request.id] ?? "未送信")")
                                .foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Divider()
                    }
                }
            }.frame(minHeight: 100, maxHeight: 260)
            Text("対象リポジトリで各Botの連携設定が必要。投稿済みはレビューの開始・完了を意味しない。結果が不明な場合はGitHubで確認してから再依頼する。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("閉じる") { dismiss() }.disabled(sending)
                Spacer()
                if sending { ProgressView().controlSize(.small) }
                Button("\(requests.count)件のコメントを投稿") {
                    guard !sending, results.isEmpty else { return }
                    let plan = requests
                    sending = true
                    Task { @MainActor in
                        for (index, request) in plan.enumerated() {
                            if index > 0 { try? await Task.sleep(nanoseconds: 1_000_000_000) }
                            results[request.id] = "送信中…"
                            do {
                                try await model.requestReview(request, account: account)
                                results[request.id] = "投稿済み"
                            } catch BotReviewError.accountMismatch {
                                results[request.id] = "未送信：GitHubアカウントが一致しない"
                            } catch BotReviewError.accountVerificationFailed {
                                results[request.id] = "未送信：アカウントを確認できない"
                            } catch {
                                results[request.id] = "送信を確認できない。GitHubを確認"
                            }
                        }
                        sending = false
                    }
                }.disabled(requests.isEmpty || sending || !results.isEmpty || model.demo || !model.ready)
            }
        }.font(.system(size: 13)).padding(16).frame(width: 500)
            .interactiveDismissDisabled(sending)
    }
}
