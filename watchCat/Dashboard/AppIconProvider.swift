import AppKit

/// bundleID → app icon lookup with a small in-memory cache. Resolving an
/// app's icon goes through Launch Services (`urlForApplication`) which is
/// fast but not free, and the dashboard re-renders rows on every state
/// change — caching keeps `AppRow` cheap.
enum AppIconProvider {
    private static let cache = NSCache<NSString, NSImage>()

    /// Returns the app icon for `bundleID`, or a generic system icon if the
    /// app is no longer installed (uninstalled apps still appear in historical
    /// totals). All returned images are sized to fit the requested point size
    /// so SwiftUI doesn't have to scale at render time.
    static func icon(for bundleID: String, size: CGFloat = 18) -> NSImage {
        let key = "\(bundleID)@\(Int(size))" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let image: NSImage = {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                icon.size = NSSize(width: size, height: size)
                return icon
            }
            // Uninstalled / pseudo-bundle (e.g., system idle row): fall back
            // to the generic app icon so the row still has a visual anchor.
            let fallback = NSImage(named: NSImage.applicationIconName) ?? NSImage()
            fallback.size = NSSize(width: size, height: size)
            return fallback
        }()
        cache.setObject(image, forKey: key)
        return image
    }
}
