import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    /// Injected by `AppDelegate` so Settings can drive import/export against the
    /// live store. Settings won't show DB-related controls until this is set.
    var sessionStoreProvider: (() -> SessionStore?)?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = SettingsView(storeProvider: { [weak self] in self?.sessionStoreProvider?() })
        let hosting = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: hosting)
        w.title = "watchCat 설정"
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.setContentSize(NSSize(width: 560, height: 720))
        w.center()
        w.isReleasedWhenClosed = false
        w.delegate = self

        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            self.window = nil
        }
    }
}

struct SettingsView: View {
    @StateObject private var permissions = PermissionManager.shared
    @State private var retentionDays: Int = RetentionSettings.days
    @State private var selectedMascot: MascotKind = MascotKind.current
    @State private var operationMessage: String?
    @State private var operationIsError: Bool = false
    @State private var importReplaceMode: Bool = false
    @State private var confirmReplaceImport: URL?
    @State private var confirmPrune: Bool = false

    let storeProvider: () -> SessionStore?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                sectionHeader("권한")
                VStack(spacing: 10) {
                    ForEach(PermissionKind.allCases) { kind in
                        PermissionRowView(kind: kind, permissions: permissions)
                    }
                }

                Divider()

                sectionHeader("일반")
                Toggle("로그인 시 자동 시작", isOn: Binding(
                    get: { permissions.launchAtLoginEnabled },
                    set: { permissions.setLaunchAtLogin($0) }
                ))
                .font(.callout)

                Divider()

                sectionHeader("마스코트")
                MascotPicker(selection: $selectedMascot)
                    .onChange(of: selectedMascot) { _, newValue in
                        MascotKind.current = newValue
                    }
                Text("상태바 아이콘으로 보일 캐릭터를 선택합니다. 변경은 즉시 반영됩니다.")
                    .font(.caption).foregroundStyle(.secondary)

                Divider()

                sectionHeader("데이터 보관")
                HStack {
                    Text("보관 기간")
                    Spacer()
                    Picker("", selection: $retentionDays) {
                        ForEach(RetentionSettings.allowedDays, id: \.self) { d in
                            Text(RetentionSettings.displayLabel(for: d)).tag(d)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                    .onChange(of: retentionDays) { _, newValue in
                        RetentionSettings.days = newValue
                    }
                }
                Text("보관 기간을 넘긴 데이터는 앱 시작 시 자동으로 삭제됩니다. ‘무제한’을 선택하면 삭제하지 않습니다.")
                    .font(.caption).foregroundStyle(.secondary)

                HStack {
                    Button("지금 정리하기...") { confirmPrune = true }
                    Spacer()
                }
                .padding(.top, 4)
                .confirmationDialog(
                    "보관 기간을 넘긴 데이터를 지금 삭제할까요?",
                    isPresented: $confirmPrune,
                    titleVisibility: .visible
                ) {
                    Button("삭제", role: .destructive) { performPruneNow() }
                    Button("취소", role: .cancel) {}
                } message: {
                    Text("현재 보관 기간: \(RetentionSettings.displayLabel(for: retentionDays)). 삭제된 데이터는 복구할 수 없습니다.")
                }

                Divider()

                sectionHeader("데이터 가져오기 / 내보내기")
                HStack {
                    Button("데이터 내보내기 (JSON)...") { performExport() }
                    Spacer()
                }
                Toggle("가져올 때 기존 데이터를 모두 교체하기", isOn: $importReplaceMode)
                    .font(.caption)
                Text("OFF면 가져온 행이 기존 데이터에 추가됩니다(병합). ON이면 모든 기록을 삭제하고 백업으로 교체합니다.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("데이터 가져오기...") { performImport() }
                    Spacer()
                }
                .confirmationDialog(
                    "기존 데이터를 모두 교체할까요?",
                    isPresented: Binding(
                        get: { confirmReplaceImport != nil },
                        set: { if !$0 { confirmReplaceImport = nil } }
                    ),
                    titleVisibility: .visible,
                    presenting: confirmReplaceImport
                ) { url in
                    Button("교체", role: .destructive) { runImport(url: url, mode: .replace) }
                    Button("취소", role: .cancel) {}
                } message: { _ in
                    Text("이 작업은 되돌릴 수 없습니다.")
                }

                if let msg = operationMessage {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: operationIsError ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                            .foregroundStyle(operationIsError ? Color.orange : Color.green)
                        Text(msg).font(.callout)
                        Spacer()
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill((operationIsError ? Color.orange : Color.green).opacity(0.12)))
                }

                Spacer(minLength: 6)

                HStack {
                    Spacer()
                    Button("새로고침") { permissions.refresh() }
                        .controlSize(.regular)
                }
            }
            .padding(24)
        }
        .frame(minWidth: 560, minHeight: 720)
        .onAppear {
            permissions.refresh()
            retentionDays = RetentionSettings.days
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 17, weight: .semibold))
            .padding(.bottom, 2)
    }

    // MARK: - Operations

    private func performPruneNow() {
        guard let store = storeProvider() else {
            setMessage("DB를 사용할 수 없습니다.", isError: true); return
        }
        do {
            let removed = try store.prune(olderThanDays: RetentionSettings.days)
            setMessage("정리 완료 — \(removed)개 행 삭제됨.", isError: false)
        } catch {
            setMessage("정리 실패: \(error.localizedDescription)", isError: true)
        }
    }

    private func performExport() {
        guard let store = storeProvider() else {
            setMessage("DB를 사용할 수 없습니다.", isError: true); return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        let fmt = DateFormatter(); fmt.dateFormat = "yyyyMMdd-HHmmss"
        panel.nameFieldStringValue = "watchCat-backup-\(fmt.string(from: Date())).json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            try store.exportArchive(to: url, appVersion: appVersion)
            setMessage("내보내기 완료: \(url.lastPathComponent)", isError: false)
        } catch {
            setMessage("내보내기 실패: \(error.localizedDescription)", isError: true)
        }
    }

    private func performImport() {
        guard storeProvider() != nil else {
            setMessage("DB를 사용할 수 없습니다.", isError: true); return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if importReplaceMode {
            confirmReplaceImport = url
        } else {
            runImport(url: url, mode: .merge)
        }
    }

    private func runImport(url: URL, mode: ImportMode) {
        guard let store = storeProvider() else {
            setMessage("DB를 사용할 수 없습니다.", isError: true); return
        }
        do {
            let summary = try store.importArchive(from: url, mode: mode)
            let modeLabel = (mode == .replace) ? "교체" : "병합"
            setMessage("가져오기 완료 (\(modeLabel)) — 세션 \(summary.sessionsImported), 웹 \(summary.webSessionsImported), 카테고리 \(summary.categoriesImported).",
                       isError: false)
        } catch {
            setMessage("가져오기 실패: \(error.localizedDescription)", isError: true)
        }
    }

    private func setMessage(_ msg: String, isError: Bool) {
        operationMessage = msg
        operationIsError = isError
    }
}
