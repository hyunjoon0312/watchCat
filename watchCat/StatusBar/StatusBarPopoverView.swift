import AppKit
import SwiftUI

/// Three-screen popover that replaces the old NSMenu. Navigation is local
/// (state-driven slide transitions) instead of a NavigationStack — the popover
/// is small and the sub-screens are leaf-y, so the back-button-and-state pattern
/// keeps everything in one ObservableObject without router boilerplate.
private enum PopoverScreen: Equatable { case main, mascot, more }

struct StatusBarPopoverView: View {
    @ObservedObject var model: StatusBarPopoverModel
    /// Pulled from `PopoverWindowProvider` / closures so the SwiftUI side can
    /// open AppKit windows without a singleton lookup. Keeps the view testable
    /// in isolation if we ever add SwiftUI previews for it.
    let onOpenDashboard: () -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void
    let onClose: () -> Void

    @State private var screen: PopoverScreen = .main
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            // Container with the same modern indigo / warm gold palette as the
            // dashboard so the menubar entrypoint feels like part of the same
            // product, not a system-level alert.
            background
            content
                .padding(16)
        }
        .frame(width: 360)
        .onAppear { model.reload() }
    }

    @ViewBuilder
    private var content: some View {
        switch screen {
        case .main:
            MainScreen(
                model: model,
                onMascot: { withAnimation(.easeInOut(duration: 0.22)) { screen = .mascot } },
                onMore: { withAnimation(.easeInOut(duration: 0.22)) { screen = .more } },
                onSettings: { onClose(); onOpenSettings() },
                onDashboard: { onClose(); onOpenDashboard() }
            )
            .transition(.move(edge: .leading).combined(with: .opacity))
        case .mascot:
            MascotScreen(
                onBack: { withAnimation(.easeInOut(duration: 0.22)) { screen = .main } }
            )
            .transition(.move(edge: .trailing).combined(with: .opacity))
        case .more:
            MoreScreen(
                onBack: { withAnimation(.easeInOut(duration: 0.22)) { screen = .main } },
                onQuit: { onQuit() }
            )
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(scheme == .dark
                  ? Color(.displayP3, red: 0.10, green: 0.09, blue: 0.13, opacity: 1)
                  : Color(.displayP3, red: 0.98, green: 0.97, blue: 1.00, opacity: 1))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(scheme == .dark ? 0.05 : 0.4), lineWidth: 1)
            )
    }
}

// MARK: - Main screen

private struct MainScreen: View {
    @ObservedObject var model: StatusBarPopoverModel
    let onMascot: () -> Void
    let onMore: () -> Void
    let onSettings: () -> Void
    let onDashboard: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            statusPill
            if model.permissionDenied { permissionBanner }
            summaryBlock
            pauseToggle
            Divider().opacity(0.4)
            actionRow
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            // Small mascot preview at the head — orients the user to which
            // character is currently the recording mascot.
            Image(nsImage: previewMascot)
                .interpolation(.high)
                .frame(width: 22, height: 22)
            Text("watchCat")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
            Spacer()
            iconButton(systemImage: "ellipsis", accessibilityLabel: "더보기", action: onMore)
        }
    }

    private var statusPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.isPaused ? Color.orange : Color.green)
                .frame(width: 7, height: 7)
            Text(model.statusLabel)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Capsule().fill(.secondary.opacity(scheme == .dark ? 0.18 : 0.10)))
    }

    private var permissionBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("브라우저 탭 권한 필요")
                .font(.system(size: 12, weight: .medium, design: .rounded))
            Spacer()
            Button("설정 열기") {
                if let url = PermissionKind.appleEvents.systemSettingsURL {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.orange)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.14)))
    }

    private var summaryBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(todayLabel)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
            }
            Text(TimeFormatting.longHMS(model.todayTotalSeconds))
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .monospacedDigit()
            if model.todayTotals.isEmpty {
                Text("아직 기록된 활동이 없습니다")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 6) {
                    let cap = min(model.todayTotals.count, 3)
                    let max = model.todayTotals.first?.seconds ?? 1
                    ForEach(0..<cap, id: \.self) { idx in
                        let t = model.todayTotals[idx]
                        AppMiniRow(total: t, max: max,
                                   category: model.categoryMapping[t.bundleID])
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.background.opacity(scheme == .dark ? 0.55 : 0.7))
        )
    }

    private var pauseToggle: some View {
        Button {
            model.togglePause()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: model.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 11, weight: .bold))
                Text(model.isPaused ? "기록 재개" : "일시중지")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(model.isPaused ? Color.green : Color.orange)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill((model.isPaused ? Color.green : Color.orange).opacity(0.14))
            )
        }
        .buttonStyle(.plain)
        .onHover { h in if h { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            actionButton(systemImage: "pawprint.fill", label: "캐릭터", action: onMascot)
            actionButton(systemImage: "chart.bar.xaxis", label: "대시보드", action: onDashboard)
            actionButton(systemImage: "gear", label: "설정", action: onSettings)
        }
    }

    private func actionButton(systemImage: String, label: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(accent)
                Text(label)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.background.opacity(scheme == .dark ? 0.55 : 0.7))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.secondary.opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { h in if h { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
    }

    private func iconButton(systemImage: String, accessibilityLabel: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(.secondary.opacity(scheme == .dark ? 0.18 : 0.08)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .onHover { h in if h { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
    }

    private var previewMascot: NSImage {
        let name = "\(MascotKind.current.rawValue)-record-2-front"
        if let img = NSImage(named: name) {
            img.size = NSSize(width: 22, height: 22); img.isTemplate = false
            return img
        }
        return NSImage()
    }

    private var todayLabel: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "오늘 · M월 d일 (E)"
        return f.string(from: Date())
    }

    private var accent: Color {
        Color(.displayP3, red: 0.43, green: 0.36, blue: 0.96, opacity: 1)
    }
}

// MARK: - App mini row (summary block list)

private struct AppMiniRow: View {
    let total: AppTotal
    let max: TimeInterval
    let category: AppCategory?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(total.displayName)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .lineLimit(1)
                Spacer()
                Text(TimeFormatting.longHMS(total.seconds))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.secondary.opacity(0.12))
                    Capsule()
                        .fill(LinearGradient(colors: [barColor.opacity(0.7), barColor],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 4)
        }
    }

    private var barColor: Color {
        DashboardPalette.color(for: category)
    }
    private var fraction: Double {
        guard max > 0 else { return 0 }
        return min(1.0, total.seconds / max)
    }
}

// MARK: - Mascot screen

private struct MascotScreen: View {
    let onBack: () -> Void
    @State private var selection: MascotKind = MascotKind.current
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            BackHeader(title: "캐릭터 선택", onBack: onBack)
            VStack(spacing: 4) {
                ForEach(MascotKind.allCases) { kind in
                    MascotRow(
                        kind: kind,
                        isSelected: selection == kind,
                        onPick: {
                            selection = kind
                            MascotKind.current = kind
                        }
                    )
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.background.opacity(scheme == .dark ? 0.45 : 0.7))
            )
        }
    }
}

private struct MascotRow: View {
    let kind: MascotKind
    let isSelected: Bool
    let onPick: () -> Void
    @State private var isHovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(isSelected
                              ? Color(.displayP3, red: 0.43, green: 0.36, blue: 0.96, opacity: 1)
                              : Color.clear)
                        .frame(width: 8, height: 8)
                }
                .frame(width: 14)
                Text(kind.displayName)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                Spacer()
                Image(nsImage: preview)
                    .interpolation(.high)
                    .frame(width: 28, height: 28)
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovering ? Color.secondary.opacity(0.10) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { h in
            isHovering = h
            if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    private var preview: NSImage {
        let name = "\(kind.rawValue)-record-2-front"
        if let img = NSImage(named: name) {
            img.size = NSSize(width: 28, height: 28); img.isTemplate = false
            return img
        }
        return NSImage()
    }
}

// MARK: - More screen

private struct MoreScreen: View {
    let onBack: () -> Void
    let onQuit: () -> Void
    @State private var showingAbout = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            BackHeader(title: "더보기", onBack: onBack)
            VStack(spacing: 2) {
                MoreItem(icon: "info.circle", title: "watchCat 정보") {
                    showingAbout = true
                }
                MoreItem(icon: "lightbulb", title: "도움말") {
                    if let url = URL(string: "https://github.com/hyunjoon0312/watchCat") {
                        NSWorkspace.shared.open(url)
                    }
                }
                MoreItem(icon: "power", title: "watchCat 종료", isDestructive: true) {
                    onQuit()
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.background.opacity(scheme == .dark ? 0.45 : 0.7))
            )
        }
        .alert("watchCat", isPresented: $showingAbout) {
            Button("확인", role: .cancel) {}
        } message: {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
            Text("버전 \(version)\n맥 사용시간을 자동 기록하는 상태바 앱입니다.")
        }
    }
}

private struct MoreItem: View {
    let icon: String
    let title: String
    var isDestructive: Bool = false
    let action: () -> Void
    @State private var isHovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isDestructive ? Color.red : .primary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(.secondary.opacity(scheme == .dark ? 0.18 : 0.08)))
                Text(title)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(isDestructive ? Color.red : .primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovering ? Color.secondary.opacity(0.10) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { h in
            isHovering = h
            if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

// MARK: - Shared back header

private struct BackHeader: View {
    let title: String
    let onBack: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // ZStack guarantees the title is perfectly centered no matter what the
        // back button's actual width is. Previous version used `Spacer(width: 60)`
        // to "balance" the leading button, but that's brittle — Korean text
        // ("뒤로") plus the chevron isn't exactly 60pt, so the title drifted right.
        ZStack {
            HStack {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .bold))
                        Text("뒤로")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.secondary.opacity(scheme == .dark ? 0.18 : 0.08))
                    )
                }
                .buttonStyle(.plain)
                .onHover { h in if h { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
                Spacer()
            }
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }
}
