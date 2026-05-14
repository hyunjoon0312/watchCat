import AppKit
import SwiftUI

/// Settings control for picking which mascot the status-bar icon uses.
/// Renders one card per `MascotKind` with its `record-2-front` preview, name,
/// and short blurb. Selected card gets an accent ring + checkmark so the
/// current choice is obvious without reading.
struct MascotPicker: View {
    @Binding var selection: MascotKind
    @Environment(\.colorScheme) private var scheme

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 12)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(MascotKind.allCases) { kind in
                MascotCard(kind: kind, isSelected: kind == selection)
                    .onTapGesture {
                        if selection != kind { selection = kind }
                    }
                    .onHover { hovering in
                        if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
            }
        }
    }
}

private struct MascotCard: View {
    let kind: MascotKind
    let isSelected: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.background.opacity(scheme == .dark ? 0.45 : 0.95))
                Image(nsImage: previewImage)
                    .interpolation(.high)
                    .frame(width: 44, height: 44)
            }
            .frame(height: 70)
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white, accent)
                        .padding(6)
                }
            }

            VStack(spacing: 2) {
                Text(kind.displayName)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Text(kind.blurb)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected
                      ? accent.opacity(0.14)
                      : Color.secondary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isSelected ? accent : Color.secondary.opacity(0.18),
                              lineWidth: isSelected ? 2 : 1)
        )
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }

    /// 44pt preview rendered from the @2x asset. Falls back to a friendly emoji
    /// placeholder so the picker still works even if PNG generation hasn't run.
    private var previewImage: NSImage {
        let name = "\(kind.rawValue)-record-2-front"
        if let img = NSImage(named: name) {
            img.size = NSSize(width: 44, height: 44)
            img.isTemplate = false
            return img
        }
        return NSImage(systemSymbolName: "questionmark.app", accessibilityDescription: nil)
            ?? NSImage()
    }

    private var accent: Color {
        Color(.displayP3, red: 0.43, green: 0.36, blue: 0.96, opacity: 1)
    }
}
