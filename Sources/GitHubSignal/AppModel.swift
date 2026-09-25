import AppKit
import Foundation
import NotificationCore
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published private(set) var state = InboxState()
    @Published private(set) var syncing = false
    @Published private(set) var error: String?
    @Published private(set) var permissionDenied = false
    @Published private(set) var lastSync: Date?
    @Published private(set) var nextSync = Date.distantPast
    @Published private(set) var ready = true
    @Published private(set) var demo: Bool
    @Published private(set) var availableRelease: String?
    @Published private(set) var checkingUpdate = false
    @Published private(set) var updateStatus: String?
    let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    private var updateLoop: Task<Void, Never>?
    private let store: StateStore
    private let client = GitHubClient(transport: GHTransport())
    private var loop: Task<Void, Never>?
    private var permissionGranted = false
    private var serverPollInterval: TimeInterval = 60

    var filteredSignals: [Signal] { state.signals.filter { state.settings.includes(repository: $0.repository) } }
    var pending: [Signal] { filteredSignals.filter { !$0.acknowledged } }
    var pendingThreadCount: Int { Set(pending.map(\.threadKey)).count }
    var availableOrganizations: [String] {
        Array(Set(state.signals.compactMap { $0.repository.split(separator: "/").first.map(String.init) })).sorted()
    }
    var activeCount: Int { pending.filter { ($0.snoozedUntil ?? .distantPast) <= Date() }.count }

    init(demo: Bool = ProcessInfo.processInfo.arguments.contains("--demo")) {
        self.demo = demo
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GitHubSignal", isDirectory: true)
        store = StateStore(url: directory.appendingPathComponent("inbox.json"))
        if demo {
            state.account = "you"
            state.signals = [
                Signal(id: "demo-mention", kind: .mention, repository: "example/product", title: "ログイン画面の改善",
                       actor: "teammate", excerpt: "@you エラー時の表示について確認してほしい。", url: "https://github.com/notifications", date: Date()),
                Signal(id: "demo-request", kind: .reviewRequest, repository: "example/api", title: "検索APIの応答を改善",
                       actor: "reviewer", excerpt: "あなたへのレビュー依頼", url: "https://github.com/notifications", date: Date().addingTimeInterval(-600)),
                Signal(id: "demo-review", kind: .review, repository: "example/product", title: "通知設定を追加",
                       actor: "teammate", excerpt: "変更リクエスト\n初期値を確認してほしい。", url: "https://github.com/notifications", date: Date().addingTimeInterval(-1800))
            ]
        } else {
            do { state = try store.load() }
            catch { self.error = "保存データを読み込めないため、更新を停止しました：\(error.localizedDescription)"; ready = false }
        }
    }

    func start() {
        guard !demo else { return }
        if updateLoop == nil {
            updateLoop = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.checkForUpdates()
                    try? await Task.sleep(nanoseconds: 86_400_000_000_000)
                }
            }
        }
        guard loop == nil, ready else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.state.enabled {
                    await self.refreshPermission()
                    if Date() >= self.nextSync { await self.sync() }
                    await self.deliverDue()
                }
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    func checkForUpdates(manual: Bool = false) async {
        guard !demo, !checkingUpdate else { return }
        checkingUpdate = true
        defer { checkingUpdate = false }
        if manual { updateStatus = nil }
        do {
            let release = try await AppRelease.fetch()
            guard !demo else { return }
            availableRelease = release.isNewer(than: appVersion) ? release.tag_name : nil
            updateStatus = availableRelease == nil ? "最新版を使用しています" : nil
        } catch {
            if manual, !demo { updateStatus = "更新を確認できませんでした。時間をおいて再試行してください。" }
        }
    }

    func openRelease() { NSWorkspace.shared.open(AppRelease.downloadURL) }

    func connect() async {
        guard ready, !demo else { return }
        state.enabled = true
        guard persist() else { return }
        await requestPermission()
        await sync()
    }

    func pause() {
        state.enabled = false
        persist()
    }

    func requestPermission() async {
        do { permissionGranted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) }
        catch { self.error = "通知の許可状態を確認できませんでした：\(error.localizedDescription)" }
        await refreshPermission()
    }

    private func refreshPermission() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        permissionGranted = [.authorized, .provisional].contains(settings.authorizationStatus)
        permissionDenied = !permissionGranted
    }

    func sync() async {
        guard ready, state.enabled, !syncing, !demo, Date() >= nextSync else { return }
        syncing = true
        defer { syncing = false }
        nextSync = Date().addingTimeInterval(max(Double(state.settings.pollSeconds), serverPollInterval))
        error = nil
        do {
            let identity = try await client.account()
            if let account = state.account, account.caseInsensitiveCompare(identity.login) != .orderedSame {
                throw SignalError.message("GitHub CLIのアカウントが \(identity.login) に変わっています。\(account) に戻してから再開してください。")
            }
            state.account = identity.login
            let since = state.cursor?.addingTimeInterval(-1_800) ?? identity.now.addingTimeInterval(-86_400)
            let batch = try await client.notifications(since: since)
            serverPollInterval = batch.pollInterval
            nextSync = Date().addingTimeInterval(max(Double(state.settings.pollSeconds), serverPollInterval))
            // Persist the work queue before moving the polling cursor. Failures survive a restart.
            state.enqueue(batch.threads, since: since, cursor: batch.serverDate)
            guard persist() else { return }
            var failures: [String] = []
            let work = state.pending.values.sorted { $0.thread.updatedAt > $1.thread.updatedAt }
            for pending in work {
                guard state.enabled, ready else { return }
                do {
                    let signals = try await client.signals(for: pending, login: identity.login)
                    state.merge(signals)
                    state.processed[pending.thread.id] = pending.thread.updatedAt
                    state.pending.removeValue(forKey: pending.thread.id)
                    guard persist() else { return }
                } catch {
                    failures.append("\(pending.thread.repository.fullName)：\(error.localizedDescription)")
                    // Avoid a burst of requests when authorization or rate limiting fails.
                    if failures.count >= 3 { break }
                }
            }
            if state.pending.isEmpty {
                lastSync = Date()
            } else {
                error = "\(state.pending.count)件の通知を取得できませんでした。時間をおいて再試行します。\n" + failures.prefix(3).joined(separator: "\n")
                nextSync = Date().addingTimeInterval(max(300, serverPollInterval))
            }
            // Keep acknowledgements for seven days, longer than the overlap and initial import.
            let cutoff = batch.serverDate.addingTimeInterval(-7 * 86_400)
            state.prune(before: cutoff)
            guard persist() else { return }
            await deliverDue()
        } catch {
            self.error = error.localizedDescription
            nextSync = Date().addingTimeInterval(max(300, serverPollInterval))
        }
    }

    func acknowledge(_ id: String) {
        guard let index = state.signals.firstIndex(where: { $0.id == id }) else { return }
        state.signals[index].acknowledged = true
        if persist() { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id]) }
    }

    func acknowledgeThread(_ threadKey: String) {
        let ids = state.signals.filter { $0.threadKey == threadKey && !$0.acknowledged }.map(\.id)
        guard !ids.isEmpty else { return }
        for index in state.signals.indices where state.signals[index].threadKey == threadKey {
            state.signals[index].acknowledged = true
        }
        if persist() { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids) }
    }

    func enterDemo() {
        guard !state.enabled, !syncing else { return }
        updateLoop?.cancel()
        updateLoop = nil
        availableRelease = nil
        updateStatus = nil
        state = AppModel(demo: true).state
        demo = true
    }

    func leaveDemo() {
        guard demo else { return }
        do {
            state = try store.load()
            demo = false
            start()
        } catch { self.error = "保存データを読み込めませんでした：\(error.localizedDescription)" }
    }

    func snooze(_ id: String) {
        guard let index = state.signals.firstIndex(where: { $0.id == id }) else { return }
        state.signals[index].snoozedUntil = Date().addingTimeInterval(3_600)
        state.signals[index].lastNotifiedAt = nil
        if persist() { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id]) }
    }

    func unsnooze(_ id: String) {
        guard let index = state.signals.firstIndex(where: { $0.id == id }) else { return }
        state.signals[index].snoozedUntil = nil
        state.signals[index].lastNotifiedAt = nil
        persist()
    }

    func updateSettings(_ transform: (inout Settings) -> Void) {
        transform(&state.settings)
        persist()
    }

    func setOrganizations(_ input: String) throws {
        let organizations = try Settings.parseOrganizations(input)
        state.settings.organizations = organizations
        guard persist() else { return }
        if !demo {
            let excluded = state.signals.filter { !state.settings.includes(repository: $0.repository) }.map(\.id)
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: excluded + ["inbox-summary"])
        }
    }

    func open(_ signal: Signal, entireThread: Bool = false) {
        guard ready else { return }
        let ids = state.openSignal(signal.id, entireThread: entireThread) { NSWorkspace.shared.open($0) }
        if !ids.isEmpty, persist() {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    func copyURL(_ signal: Signal) {
        guard let url = SignalRules.safeWebURL(signal.url) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    func testNotification() async {
        await requestPermission()
        guard permissionGranted else { return }
        let content = UNMutableNotificationContent()
        content.title = "GitHub Signal"
        content.body = "テスト通知です。未確認の通知はアプリの一覧から確認できます。"
        content.sound = .default
        do { try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "test", content: content, trigger: nil)) }
        catch { self.error = error.localizedDescription }
    }

    private func deliverDue() async {
        guard ready, state.enabled, permissionGranted, !demo else { return }
        let now = Date()
        let due = state.signals.filter {
            $0.needsNotification(at: now, reminderMinutes: state.settings.reminderMinutes)
            && state.settings.allows($0.kind)
            && state.settings.includes(repository: $0.repository)
            && (state.settings.includeBots || !$0.actor.hasSuffix("[bot]"))
        }
        guard !due.isEmpty else { return }
        do {
            if due.count > 3 {
                let content = UNMutableNotificationContent()
                content.title = "未確認のGitHub通知が\(due.count)件あります"
                content.body = "メニューバーからGitHub Signalを開くと、内容を確認できます。"
                content.sound = .default
                try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "inbox-summary", content: content, trigger: nil))
                for signal in due { markNotified(signal.id, now: now) }
            } else {
                for signal in due {
                    let content = UNMutableNotificationContent()
                    content.title = signal.kindLabel
                    content.subtitle = "\(signal.repository) · @\(signal.actor)"
                    content.body = signal.title + "\n" + String(signal.excerpt.prefix(180))
                    content.sound = .default
                    content.categoryIdentifier = "SIGNAL"
                    content.userInfo = ["signalID": signal.id]
                    try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: signal.id, content: content, trigger: nil))
                    markNotified(signal.id, now: now)
                }
            }
        } catch { self.error = "通知を送信できませんでした：\(error.localizedDescription)" }
    }

    private func markNotified(_ id: String, now: Date) {
        guard let index = state.signals.firstIndex(where: { $0.id == id }) else { return }
        state.signals[index].lastNotifiedAt = now
        persist()
    }

    @discardableResult
    private func persist() -> Bool {
        guard ready else { return false }
        if demo { return true }
        do { try store.save(state); return true }
        catch {
            ready = false
            self.error = "データを保存できないため、更新を停止しました：\(error.localizedDescription)"
            return false
        }
    }
}
