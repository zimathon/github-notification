import AppKit
import SwiftUI
import NotificationCore

struct InboxView: View {
    @ObservedObject var model: AppModel
    @AppStorage("backgroundTransparency") private var backgroundTransparency = 0.18
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var filter = "すべて"
    @State private var search = ""
    @State private var settingsOpen = false
    @State private var showAcknowledged = false
    @State private var organizationsInput = ""
    @State private var settingsError: String?
    @State private var expandedIDs: Set<String> = []
    @State private var expandedGroups: Set<String> = []
    @AppStorage("inboxOrganization") private var organization = ""
    @AppStorage("inboxRepository") private var repository = ""
    private let accent = Color(red: 0.24, green: 0.58, blue: 0.48)

    private var visible: [Signal] {
        model.filteredSignals.filter {
            $0.acknowledged == showAcknowledged && (filter == "すべて" || $0.kind.title == filter)
                && (search.isEmpty || "\($0.title) \($0.repository) \($0.actor) \($0.excerpt)".localizedCaseInsensitiveContains(search))
                && (organization.isEmpty || owner(of: $0.repository) == organization)
                && (repository.isEmpty || $0.repository == repository)
        }
    }

    private func owner(of repository: String) -> String {
        repository.split(separator: "/").first.map(String.init) ?? ""
    }

    private var organizations: [String] {
        Array(Set(model.filteredSignals.map { owner(of: $0.repository) })
            .union(organization.isEmpty ? [] : [organization])).sorted()
    }

    private var repositories: [String] {
        Array(Set(model.filteredSignals.filter { organization.isEmpty || owner(of: $0.repository) == organization }
            .map(\.repository)).union(repository.isEmpty ? [] : [repository])).sorted()
    }

    private struct SignalGroup: Identifiable {
        let id: String
        var signals: [Signal]
    }

    private var groups: [SignalGroup] {
        var result: [SignalGroup] = []
        var indices: [String: Int] = [:]
        for signal in visible {
            let key = signal.threadKey
            if let index = indices[key] { result[index].signals.append(signal) }
            else { indices[key] = result.count; result.append(SignalGroup(id: key, signals: [signal])) }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let version = model.availableRelease, !model.demo {
                HStack {
                    Text("新しいバージョン \(version)")
                    Spacer()
                    Button("ダウンロード") { model.openRelease() }
                }.font(.system(size: 13)).padding(8)
            }
            if model.demo {
                HStack {
                    banner("デモ表示中（サンプルデータ）", symbol: "eye", color: accent)
                    Button("デモを終了") { model.leaveDemo() }.padding(.trailing, 12)
                }
            }
            if let error = model.error { banner(error, symbol: "exclamationmark.triangle", color: .orange) }
            if model.permissionDenied && model.state.enabled {
                HStack {
                    Text("通知がオフになっています。一覧の更新は続けています。")
                    Spacer()
                    Button("通知を許可") { Task { await model.requestPermission() } }
                    Button("通知設定を開く") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                    }
                }.font(.system(size: 12)).padding(12).background(Color.orange.opacity(0.1))
            }
            if model.state.account == nil && !model.state.enabled { onboarding }
            else { inbox }
            Divider()
            footer
        }
        .frame(minWidth: 380, minHeight: 280)
        .background(InboxMaterial())
        .tint(accent)
        .sheet(isPresented: $settingsOpen) { settings }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 16, weight: .medium)).foregroundStyle(accent)
            Text("GitHub Signal").font(.system(size: 15, weight: .semibold))
            Spacer()
            if model.state.account != nil {
                Text("未確認 \(model.pendingThreadCount)").font(.callout.weight(.medium)).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Button { settingsOpen = true } label: { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(.borderless).padding(.leading, 6).help("通知設定")
        }.padding(.horizontal, 8).padding(.vertical, 5)
    }

    private var onboarding: some View {
        VStack(alignment: .leading, spacing: 14) {
            Spacer()
            Text("GitHubの大事な更新を通知")
                .font(.system(size: 20, weight: .semibold))
            Text("メンション、レビュー依頼、自分のPRへのコメントをまとめて確認できます。")
                .font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                Label("GitHub CLIでログイン", systemImage: "person.crop.circle.badge.checkmark")
                Text("初めて使う場合は、ターミナルで次のコマンドを実行してください。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Text("brew install gh\ngh auth login --hostname github.com")
                    .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            }
            HStack {
                Button("通知を開始") { Task { await model.connect() } }
                    .buttonStyle(.borderedProminent).disabled(!model.ready)
                Button("デモを見る") { model.enterDemo() }
            }
            Text("初回は直近24時間の通知を取得します。GitHubの既読状態は変わりません。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
        }.padding(24)
    }

    private var inbox: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Picker("組織", selection: $organization) {
                    Text("すべての組織").tag("")
                    ForEach(organizations, id: \.self) { Text($0).tag($0) }
                }.labelsHidden().frame(width: 100)
                    .onChange(of: organization) { _ in repository = "" }
                Picker("リポジトリ", selection: $repository) {
                    Text("すべてのリポジトリ").tag("")
                    ForEach(repositories, id: \.self) { name in
                        Text(organization.isEmpty ? name : String(name.split(separator: "/").last ?? ""))
                            .tag(name)
                    }
                }.labelsHidden().frame(maxWidth: .infinity)
                Picker("種類", selection: $filter) {
                    Text("すべての種類").tag("すべて")
                    ForEach(SignalKind.allCases, id: \.self) { kind in Text(kind.title).tag(kind.title) }
                }.labelsHidden().frame(width: 105)
            }.font(.system(size: 13)).controlSize(.small).padding(.horizontal, 8).padding(.top, 4)
            HStack(spacing: 6) {
                Text("\(groups.count)件").monospacedDigit().foregroundStyle(.secondary).fixedSize()
                if !organization.isEmpty || !repository.isEmpty || filter != "すべて" {
                    Button { organization = ""; repository = ""; filter = "すべて" } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless).help("絞り込みを解除")
                        .accessibilityLabel("絞り込みを解除")
                }
                Spacer()
                Toggle("確認済み", isOn: $showAcknowledged).toggleStyle(.checkbox)
                TextField("検索", text: $search).textFieldStyle(.roundedBorder).frame(width: 110)
            }.font(.system(size: 13)).controlSize(.small).padding(.horizontal, 8).padding(.vertical, 4)
            if visible.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: model.syncing ? "arrow.triangle.2.circlepath" : "checkmark.circle")
                        .font(.system(size: 38, weight: .light)).foregroundStyle(accent)
                    Text(model.syncing ? "GitHubの更新を確認中" : "該当する通知はありません").font(.title3.weight(.medium))
                    Text(model.error != nil ? "取得中にエラーが発生しました。画面上部のメッセージを確認してください。" : "新しい通知は自動で表示されます。")
                        .foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(groups) { group in
                            groupRow(group)
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func groupRow(_ group: SignalGroup) -> some View {
        let expanded = expandedGroups.contains(group.id)
        return VStack(alignment: .leading, spacing: 0) {
            if let latest = group.signals.first {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(latest.repository).lineLimit(1)
                        Spacer()
                        Text(showAcknowledged ? "\(group.signals.count)件" : "未確認 \(group.signals.count)")
                        Text(latest.date, style: .relative).fixedSize()
                        Button {
                            if expanded { expandedGroups.remove(group.id) } else { expandedGroups.insert(group.id) }
                        } label: {
                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                .frame(width: 24, height: 24).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .accessibilityLabel("\(latest.title)の更新を\(expanded ? "閉じる" : "展開する")")
                            .help(expanded ? "更新を閉じる" : "更新を展開する")
                    }.font(.system(size: 12)).foregroundStyle(.secondary)
                    Button { model.open(latest) } label: {
                        Text(latest.title).font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary).lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).help("GitHubで開く")
                        .accessibilityLabel("\(latest.title)をGitHubで開く")
                    HStack {
                        if !expanded {
                            ActorAvatar(actor: latest.actor)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("@" + latest.actor).fontWeight(.semibold).lineLimit(1)
                                    .help(latest.actor)
                                Text(shortLabel(latest.kind)).font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        HStack(spacing: 6) {
                            Button("GitHubで開く") { model.open(latest) }
                            if !showAcknowledged {
                                Button("確認済み") { model.acknowledgeThread(group.id) }
                                    .help("このPR・Issueの通知をすべて確認済みにする")
                            }
                        }.buttonStyle(.bordered).controlSize(.small).fixedSize()
                    }.font(.system(size: 13))
                }.padding(.horizontal, 10).padding(.vertical, 6)
                if expanded {
                    ForEach(group.signals) { signal in row(signal) }
                }
            }
        }
    }

    private func row(_ signal: Signal) -> some View {
        let snoozed = (signal.snoozedUntil ?? .distantPast) > Date()
        let expanded = expandedIDs.contains(signal.id)
        let preview = SignalPreview.text(signal.excerpt)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                ActorAvatar(actor: signal.actor)
                Text("@" + signal.actor).fontWeight(.semibold).lineLimit(1).help(signal.actor)
                Text(shortLabel(signal.kind)).foregroundStyle(.secondary).help(signal.kind.title)
                Spacer()
                if snoozed {
                    Image(systemName: "moon.zzz").foregroundStyle(.orange).help("スヌーズ中")
                }
                Text(signal.date, style: .relative).foregroundStyle(.secondary).fixedSize()
                Button { model.open(signal) } label: {
                    Image(systemName: "arrow.up.right.square")
                }.buttonStyle(.borderless).help("GitHubで開く").accessibilityLabel("GitHubで開く")
                Menu {
                    if !signal.acknowledged {
                        Button("確認済みにする") { model.acknowledge(signal.id) }
                        Button(snoozed ? "スヌーズ解除" : "1時間後に通知") {
                            if snoozed { model.unsnooze(signal.id) } else { model.snooze(signal.id) }
                        }
                    }
                    Divider()
                    Button(expanded ? "元の本文を閉じる" : "元の本文を見る") {
                        if expanded { expandedIDs.remove(signal.id) } else { expandedIDs.insert(signal.id) }
                    }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("通知の操作").help("確認済み・スヌーズ・本文")
            }.font(.system(size: 12))
            Text(preview.isEmpty ? "本文はGitHubで確認できます" : preview)
                .font(.system(size: 13)).lineLimit(2).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if expanded {
                Text(signal.excerpt).font(.system(size: 12)).foregroundStyle(.secondary)
                    .textSelection(.enabled).padding(.top, 4)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private func shortLabel(_ kind: SignalKind) -> String {
        switch kind {
        case .mention: return "メンション"
        case .reviewRequest: return "レビュー依頼"
        case .comment: return "コメント"
        case .review: return "レビュー"
        }
    }

    private var footer: some View {
        HStack(spacing: 5) {
            Circle().fill(model.error != nil ? Color.orange : (model.state.enabled ? accent : .secondary)).frame(width: 6, height: 6)
            Text(model.demo ? "デモ" : (model.syncing ? "確認中…" : (model.state.enabled ? "監視中" : "停止中")))
            if let account = model.state.account { Text("· @\(account)") }
            if let date = model.lastSync { Text("· 更新 \(date.formatted(date: .omitted, time: .shortened))") }
            Spacer()
            if !model.demo && model.state.account != nil {
                if model.state.enabled {
                    Button("停止") { model.pause() }.disabled(model.syncing)
                    Button("今すぐ確認") { Task { await model.sync() } }
                        .disabled(model.syncing || Date() < model.nextSync)
                } else {
                    Button("再開") { Task { await model.connect() } }.disabled(!model.ready)
                }
            }
        }.font(.system(size: 12)).controlSize(.small).foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("設定").font(.headline)
                Spacer()
                Text("v" + model.appVersion).foregroundStyle(.secondary).textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("起動元").foregroundStyle(.secondary)
                Text(Bundle.main.bundleURL.path)
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                    .help(Bundle.main.bundleURL.path)
            }.font(.system(size: 12))
            HStack {
                Text("背景の透過率")
                Slider(value: $backgroundTransparency, in: 0...0.6, step: 0.01)
                    .accessibilityLabel("背景の透過率")
                    .disabled(reduceTransparency)
                Text("\(Int((backgroundTransparency * 100).rounded()))%")
                    .monospacedDigit().frame(width: 35, alignment: .trailing)
            }
            if reduceTransparency {
                Text("macOSの「透明度を下げる」が有効なため、透過率は反映されません。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Text("メンション、レビュー依頼、自分のPRへのコメント・レビューを通知します。自分の投稿は通知しません。")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Text("通知対象の組織・ユーザー").font(.headline)
                HStack {
                    TextField("org-a, org-b（空欄はすべて）", text: $organizationsInput)
                        .textFieldStyle(.roundedBorder)
                    Button("適用") {
                        do {
                            try model.setOrganizations(organizationsInput)
                            organizationsInput = model.state.settings.organizations.joined(separator: ", ")
                            settingsError = nil
                        } catch { settingsError = error.localizedDescription }
                    }
                }
                Text("指定した組織・ユーザーのリポジトリだけを通知します。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                if !model.availableOrganizations.isEmpty {
                    Text("候補：" + model.availableOrganizations.joined(separator: ", "))
                        .font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let settingsError { Text(settingsError).font(.system(size: 12)).foregroundStyle(.orange) }
            }
            Picker("更新間隔", selection: Binding(get: { model.state.settings.pollSeconds }, set: { value in model.updateSettings { $0.pollSeconds = value } })) {
                Text("2分").tag(120); Text("5分").tag(300); Text("10分").tag(600)
            }
            Picker("未確認の通知を再通知", selection: Binding(get: { model.state.settings.reminderMinutes }, set: { value in model.updateSettings { $0.reminderMinutes = value } })) {
                Text("なし").tag(0); Text("15分").tag(15); Text("30分").tag(30); Text("1時間").tag(60)
            }
            Toggle("Botからの更新も通知する", isOn: Binding(get: { model.state.settings.includeBots }, set: { value in model.updateSettings { $0.includeBots = value } }))
            Text("ウィンドウを閉じても通知は届きます。スリープ中やアプリ終了中は停止します。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack {
                Button("テスト通知") { Task { await model.testNotification() } }.disabled(model.demo)
                Spacer()
                Button("完了") { settingsOpen = false }.keyboardShortcut(.defaultAction)
            }
        }.font(.system(size: 13)).controlSize(.small).padding(12).frame(width: 390)
            .onAppear { organizationsInput = model.state.settings.organizations.joined(separator: ", "); settingsError = nil }
    }

    private func banner(_ text: String, symbol: String, color: Color) -> some View {
        Label(text, systemImage: symbol).font(.system(size: 12)).foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading).padding(12).background(color.opacity(0.08))
    }
}

// Native vibrancy follows macOS appearance and accessibility settings.
private struct InboxMaterial: NSViewRepresentable {
    @AppStorage("backgroundTransparency") private var backgroundTransparency = 0.18
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = MaterialView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.alphaValue = reduceTransparency ? 1 : 1 - min(0.6, max(0, backgroundTransparency))
    }

    private final class MaterialView: NSVisualEffectView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.isOpaque = false
            window?.backgroundColor = .clear
        }
    }
}

private struct ActorAvatar: View {
    let actor: String

    private var url: URL? {
        // GitHub user logins use ASCII letters, digits and hyphens. Bot logins use the fallback.
        guard !actor.isEmpty, actor.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45
        }) else { return nil }
        return URL(string: "https://github.com/\(actor).png?size=48")
    }

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Text(String(actor.prefix(1)).uppercased())
                .font(.system(size: 11, weight: .semibold))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.secondary.opacity(0.15))
        }
        .frame(width: 22, height: 22).clipShape(Circle()).accessibilityHidden(true)
    }
}
