import SwiftUI

/// A compact date-display chip that opens a graphical calendar popover when
/// clicked. Replaces SwiftUI's macOS-default stepperField `DatePicker`, which
/// puts the cursor on the year segment and forces tab/arrow-key navigation
/// just to change a day — that's the friction the user called out.
///
/// The chip itself shows whatever label the caller wants (a single day, a
/// week range, a month label) — picking a date from the popover writes through
/// the `selection` binding and dismisses.
struct DateChip: View {
    let label: String
    @Binding var selection: Date
    /// If set, picked dates are passed through this transform before being
    /// written back to `selection`. Used by the week chip to snap any pick
    /// onto its containing Monday.
    var transform: ((Date) -> Date)? = nil
    var icon: String = "calendar"

    @State private var isPresented = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DashboardPalette.accent)
                Text(label)
                    .font(.dbHeadline)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(.background.opacity(scheme == .dark ? 0.55 : 0.95))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(DashboardPalette.accentMuted.opacity(0.4), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .pointingCursor()
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            DatePicker("", selection: Binding(
                get: { selection },
                set: { newValue in
                    selection = transform?(newValue) ?? newValue
                    isPresented = false
                }
            ), displayedComponents: [.date])
            .datePickerStyle(.graphical)
            .labelsHidden()
            .padding(12)
            .frame(width: 320)
        }
    }
}

/// Month-only chip — shows "2026년 5월" and opens a popover with year +/-
/// stepper and a 12-button month grid. Cleaner than the stepperField/picker
/// combo we had before and removes the year-cursor friction entirely.
struct MonthChip: View {
    @Binding var date: Date
    @State private var isPresented = false
    @Environment(\.colorScheme) private var scheme
    private let calendar = Calendar.current

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "calendar")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DashboardPalette.accent)
                Text(label)
                    .font(.dbHeadline)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(.background.opacity(scheme == .dark ? 0.55 : 0.95))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(DashboardPalette.accentMuted.opacity(0.4), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .pointingCursor()
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(spacing: 10) {
                HStack {
                    Button { shift(year: -1) } label: { Image(systemName: "chevron.left") }
                    Spacer()
                    Text("\(yearComponent)년")
                        .font(.dbHeadline)
                        .monospacedDigit()
                    Spacer()
                    Button { shift(year: 1) } label: { Image(systemName: "chevron.right") }
                }
                .buttonStyle(.borderless)

                let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(1...12, id: \.self) { m in
                        let active = m == monthComponent
                        Button {
                            setMonth(m)
                            isPresented = false
                        } label: {
                            Text("\(m)월")
                                .font(.dbTag)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(active ? DashboardPalette.accent
                                                     : DashboardPalette.accentSoft.opacity(0.4))
                                )
                                .foregroundStyle(active ? Color.white : Color.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(14)
            .frame(width: 240)
        }
    }

    private var label: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "yyyy년 M월"
        return f.string(from: date)
    }
    private var yearComponent: Int { calendar.component(.year, from: date) }
    private var monthComponent: Int { calendar.component(.month, from: date) }

    private func shift(year: Int) {
        var comps = calendar.dateComponents([.year, .month, .day], from: date)
        comps.year = (comps.year ?? 0) + year; comps.day = 1
        if let d = calendar.date(from: comps) { date = d }
    }
    private func setMonth(_ m: Int) {
        var comps = calendar.dateComponents([.year, .month, .day], from: date)
        comps.month = m; comps.day = 1
        if let d = calendar.date(from: comps) { date = d }
    }
}
