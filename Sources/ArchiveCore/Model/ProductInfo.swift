import Foundation

/// Product identity, shared by the app, the Quick Look extension and the command-line tool.
///
/// The bundle identifier and version come from the running bundle when there is one (the app and
/// its extension, where Xcode fills them from `project.yml`); the constants are the fallback for
/// the command-line tool and tests. To rename the product, change these constants together with
/// `ZIPPER_BUNDLE_ID` and `MARKETING_VERSION` in `project.yml`.
public enum ProductInfo {
    public static let name = "Zipper"
    public static let cliName = "zipper"
    static let fallbackBundleIdentifier = "com.erfanj.zipper"
    static let fallbackVersion = "1.0.0"

    /// The app's bundle identifier, also used for Keychain items and the preview cache.
    public static var bundleIdentifier: String {
        guard let id = Bundle.main.bundleIdentifier, !id.isEmpty else { return fallbackBundleIdentifier }
        // The Quick Look extension shares the app's identity (com.example.app.quicklook → com.example.app).
        return id.hasSuffix(".quicklook") ? String(id.dropLast(".quicklook".count)) : id
    }

    public static var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? fallbackVersion
    }

    public static var build: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    /// Folder name used under Application Support and Caches.
    public static let cacheFolderName = name

    public static var applicationSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config")
        return base.appendingPathComponent(name, isDirectory: true)
    }
}
