import AppKit

/// Where the app lives, and keeping it somewhere hooks can rely on.
///
/// Agent hooks call the helper inside this bundle by absolute path, so the app
/// must live at a stable location. macOS runs apps opened straight from a
/// download or disk image from a randomized read-only path ("App Translocation"),
/// which would break hooks — so we offer to move to Applications first.
enum AppLocation {
    static var bundlePath: String { Bundle.main.bundleURL.standardizedFileURL.path }

    static var isTranslocated: Bool { bundlePath.contains("/AppTranslocation/") }

    static var isInApplications: Bool {
        let p = bundlePath
        return p.hasPrefix("/Applications/") || p.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    /// Development builds (make run / swift build) shouldn't nag or rewrite hooks.
    static var isDevBuild: Bool {
        let p = bundlePath
        return p.contains("/.build/") || p.contains("/build/")
    }

    /// Offers to move to Applications. Returns true if the app is relaunching.
    static func offerMoveIfNeeded() -> Bool {
        guard !isInApplications, !isDevBuild else { return false }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Move NotchBar to your Applications folder?"
        alert.informativeText = "NotchBar connects to Claude Code, Codex and Cursor by path, so it needs a permanent home. It will relaunch from Applications."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        let fm = FileManager.default
        let name = Bundle.main.bundleURL.lastPathComponent
        for dir in ["/Applications", NSHomeDirectory() + "/Applications"] {
            let dest = URL(fileURLWithPath: dir).appendingPathComponent(name)
            do {
                try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
                if fm.fileExists(atPath: dest.path) { try fm.trashItem(at: dest, resultingItemURL: nil) }
                try fm.copyItem(at: Bundle.main.bundleURL, to: dest)
                relaunch(at: dest)
                return true
            } catch {
                continue // e.g. no write access to /Applications: try ~/Applications
            }
        }
        let fail = NSAlert()
        fail.messageText = "Couldn't move NotchBar"
        fail.informativeText = "Drag NotchBar into your Applications folder, then open it from there."
        fail.runModal()
        return false
    }

    private static func relaunch(at url: URL) {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.arguments = ["--after-move"]
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
