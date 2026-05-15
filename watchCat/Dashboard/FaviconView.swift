import SwiftUI
import AppKit

/// Small favicon image for a web bucket (host). Fetches from DuckDuckGo's
/// icon service (`icons.duckduckgo.com/ip3/<host>.ico`), which is the
/// least-tracking-friendly of the public favicon endpoints. While the image
/// is loading or if the fetch fails, falls back to a colored letter avatar
/// derived from the host's first character — so the row always has a visual
/// anchor and the layout never reflows when an icon resolves.
///
/// Special-cases the incognito pseudo-bucket: no fetch, just a lock glyph.
struct FaviconView: View {
    let host: String
    var size: CGFloat = 14

    var body: some View {
        if host == URLUtilities.incognitoBucket {
            Image(systemName: "lock.fill")
                .font(.system(size: size * 0.7, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        } else if let url = Self.url(for: host) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .interpolation(.high)
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                default:
                    letterAvatar
                }
            }
        } else {
            letterAvatar
        }
    }

    private var letterAvatar: some View {
        let firstChar = host.first.map { String($0).uppercased() } ?? "·"
        let tint = DashboardPalette.stableColor(for: host)
        return Text(firstChar)
            .font(.system(size: size * 0.62, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: 3).fill(tint))
    }

    private static func url(for host: String) -> URL? {
        // Strip any leading/trailing whitespace or trailing dots that browsers
        // tolerate — DuckDuckGo's endpoint is strict about hostname formatting.
        let cleaned = host.trimmingCharacters(in: .whitespacesAndNewlines)
                         .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !cleaned.isEmpty,
              cleaned.contains(".") || cleaned == "localhost",
              let encoded = cleaned.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed)
        else { return nil }
        return URL(string: "https://icons.duckduckgo.com/ip3/\(encoded).ico")
    }
}
