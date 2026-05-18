import AppKit
import SwiftUI

/// "권한 재인증이 필요해요" 배너. brew/수동 업그레이드 직후 ad-hoc 서명의
/// cdhash가 바뀌면 macOS TCC가 watchCat을 새 앱으로 인식해 접근성/화면 기록
/// 권한이 잠시 무효화되는 케이스를 사용자에게 안내한다. `needsCoreReauth`가
/// false면 자체적으로 사라지므로 호출 측에서 분기할 필요가 없다.
struct PermissionReauthBanner: View {
    @ObservedObject var manager: PermissionManager
    @State private var showingGuide = false
    @Environment(\.colorScheme) private var scheme
    /// 메뉴바 팝오버처럼 폭이 좁은 컨텍스트에서는 본문 2줄 → 1줄로, 버튼
    /// 라벨도 짧게. 대시보드(`.spacious`)는 권장 텍스트를 그대로 노출.
    var density: Density = .spacious

    enum Density { case compact, spacious }

    var body: some View {
        if manager.needsCoreReauth {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text("권한 재인증이 필요해요")
                        .font(.system(size: density == .compact ? 12 : 13,
                                      weight: .semibold, design: .rounded))
                    if density == .spacious {
                        Text("업그레이드 후 macOS가 watchCat을 새 버전으로 인식해 이전 권한이 잠시 무효화됐을 수 있어요.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                Button("해결 방법") { showingGuide = true }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.orange)
                    .font(.system(size: density == .compact ? 11 : 12,
                                  weight: .semibold, design: .rounded))
            }
            .padding(density == .compact ? 10 : 12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.orange.opacity(0.14))
            )
            .sheet(isPresented: $showingGuide) {
                PermissionReauthGuideSheet(
                    manager: manager,
                    onClose: { showingGuide = false }
                )
            }
        }
    }
}

/// 재인증 단계를 안내하는 모달. 시스템 설정 바로가기 버튼을 함께 노출해
/// 한 화면 안에서 해결하도록 유도한다.
struct PermissionReauthGuideSheet: View {
    @ObservedObject var manager: PermissionManager
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.orange)
                Text("권한 재인증이 필요해요")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
            }

            Text("새 버전으로 업데이트하면 macOS가 watchCat을 \"다른 앱\"으로 인식할 수 있어요. 시스템 설정 목록에는 watchCat 항목이 켜진 것처럼 보여도 실제로는 무효화된 상태입니다. 아래 단계로 빠르게 복구하세요.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                step(1, "시스템 설정 → 개인정보 보호 및 보안을 엽니다.")
                step(2, "필요한 권한 항목(접근성, 화면 기록)에서 watchCat 토글을 한 번 끄고 다시 켭니다. 또는 \"−\" 버튼으로 항목을 제거합니다.")
                step(3, "다음에 watchCat이 동작할 때 권한을 다시 요청하면 \"허용\"을 누릅니다.")
            }

            Divider().padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 6) {
                Text("재인증이 필요한 항목 바로가기")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                if manager.missingCorePermissions.isEmpty {
                    Text("모든 권한이 정상입니다 ✓")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(manager.missingCorePermissions) { kind in
                        Button {
                            manager.openSystemSettings(for: kind)
                        } label: {
                            HStack {
                                Text("\(kind.displayName) 설정 열기")
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                Spacer()
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(.orange.opacity(0.12))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack {
                Spacer()
                Button("확인") { onClose() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
            .padding(.top, 4)
        }
        .padding(22)
        .frame(width: 380)
    }

    private func step(_ num: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(num)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .monospacedDigit()
                .frame(width: 20, height: 20)
                .background(Circle().fill(.orange.opacity(0.18)))
                .foregroundStyle(.orange)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
