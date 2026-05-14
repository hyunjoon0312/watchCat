import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()

    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: OnboardingView(onComplete: { [weak self] in
            AppState.shared.hasCompletedOnboarding = true
            self?.window?.close()
        }))

        let w = NSWindow(contentViewController: hosting)
        w.title = "watchCat 시작하기"
        w.styleMask = [.titled, .closable]
        w.setContentSize(NSSize(width: 480, height: 580))
        w.center()
        w.isReleasedWhenClosed = false
        w.delegate = self

        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        // If user closes via the red button, treat as onboarding completed.
        Task { @MainActor in
            AppState.shared.hasCompletedOnboarding = true
            self.window = nil
        }
    }
}

struct OnboardingView: View {
    @StateObject private var permissions = PermissionManager.shared
    @State private var step: Step = .welcome
    let onComplete: () -> Void

    enum Step { case welcome, permissions }

    var body: some View {
        Group {
            switch step {
            case .welcome:
                WelcomeStep(next: { step = .permissions })
            case .permissions:
                PermissionStep(permissions: permissions, onDone: onComplete)
            }
        }
        .frame(width: 480, height: 580)
        .onAppear { permissions.refresh() }
    }
}

private struct WelcomeStep: View {
    let next: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Text("🐱").font(.system(size: 76))
            Text("watchCat")
                .font(.system(size: 28, weight: .semibold))
            Text("맥에서 어떤 앱·웹사이트를 얼마나 쓰는지\n자동으로 기록합니다.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 10) {
                Label("상태바 캐릭터가 기록 상태를 표시", systemImage: "menubar.rectangle")
                Label("잠금·슬립·자리비움 시 자동 일시중지", systemImage: "moon.zzz")
                Label("외부 전송 없음, 로컬 SQLite에만 저장", systemImage: "lock.shield")
            }
            .font(.callout)
            .padding(.horizontal, 32)
            .padding(.top, 8)

            Spacer()

            Button(action: next) {
                Text("시작하기").frame(maxWidth: .infinity)
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
    }
}

private struct PermissionStep: View {
    @ObservedObject var permissions: PermissionManager
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("권한 설정")
                .font(.system(size: 22, weight: .semibold))
            Text("watchCat이 동작하려면 아래 권한이 필요합니다. 거부해도 앱은 부분 동작 모드로 유지됩니다.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                ForEach(PermissionKind.allCases) { kind in
                    PermissionRowView(kind: kind, permissions: permissions, compact: true)
                }
            }

            Divider().padding(.vertical, 6)

            Toggle("로그인 시 자동 시작", isOn: Binding(
                get: { permissions.launchAtLoginEnabled },
                set: { permissions.setLaunchAtLogin($0) }
            ))
            .font(.callout)

            Spacer(minLength: 0)

            Button(action: onDone) {
                Text("완료").frame(maxWidth: .infinity)
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
        }
        .padding(24)
    }
}

struct PermissionRowView: View {
    let kind: PermissionKind
    @ObservedObject var permissions: PermissionManager
    var compact: Bool = false

    private var granted: Bool { permissions.states[kind] ?? false }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .font(.title3)
                .foregroundStyle(granted ? .green : .orange)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(kind.displayName).font(.headline)
                Text(kind.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                if granted {
                    Text("허용됨").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("요청") { permissions.request(kind) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                if !compact || !granted {
                    Button("시스템 설정") { permissions.openSystemSettings(for: kind) }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .font(.caption)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }
}
