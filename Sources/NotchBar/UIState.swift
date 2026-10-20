import AppKit
import ServiceManagement
import SwiftUI

/// Visual state of the notch, driven by NotchController.
final class NotchUI: ObservableObject {
    @Published var expanded = false
    @Published var hovering = false
    @Published var pinned = false
    @Published var menuOpen = false
    /// A text field in the notch has focus — stay open and keep the keyboard.
    @Published var editing = false
    /// Which page the expanded notch shows.
    @Published var page: Page = .home
    /// Session row whose details (answer, review, draft) are unfolded.
    @Published var openRow: String?

    enum Page: Equatable { case home, launcher }

    /// Height of the menu-bar band on the current screen (the notch's collapsed height).
    @Published var bandHeight: CGFloat = 24
    /// Width of a real hardware notch, 0 if the screen has none.
    @Published var hardwareNotchWidth: CGFloat = 0

    var hasHardwareNotch: Bool { hardwareNotchWidth > 0 }
    /// Empty space to keep under a hardware notch (camera), with a little margin.
    var cameraGap: CGFloat { hasHardwareNotch ? hardwareNotchWidth + 16 : 0 }

    static let expandedWidth: CGFloat = 560

    static var motion: Animation {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? .easeInOut(duration: 0.18)
            : .spring(response: 0.44, dampingFraction: 0.78)
    }
}

/// Persisted user preferences.
final class Prefs: ObservableObject {
    enum ScreenMode: String, CaseIterable, Identifiable {
        case follow, main, builtin
        var id: String { rawValue }
        var title: String {
            switch self {
            case .follow: return "Follow Active Screen"
            case .main: return "Main Display"
            case .builtin: return "Built-in Display"
            }
        }
    }

    private let d = UserDefaults.standard

    @Published var screenMode: ScreenMode {
        didSet { d.set(screenMode.rawValue, forKey: "screenMode") }
    }
    @Published var sounds: Bool {
        didSet { d.set(sounds, forKey: "sounds") }
    }
    /// Agents whose hooks currently point at NotchBar.
    @Published var installed: Set<Agent> = []
    /// Review Cursor shell/MCP commands in the notch (Cursor asks hooks about *every* command).
    @Published var cursorApprovals: Bool {
        didSet { d.set(cursorApprovals, forKey: "cursorApprovals") }
    }
    /// Auto-allow plain read-only commands (git status, ls, cat…) everywhere.
    @Published var readOnlyDefaults: Bool { didSet { d.set(readOnlyDefaults, forKey: "readOnlyDefaults") } }
    /// Length of a "trust this project" window, in minutes.
    @Published var trustMinutes: Int { didSet { d.set(trustMinutes, forKey: "trustMinutes") } }
    /// Forecast / context / unused-capacity nudges.
    @Published var nudges: Bool { didSet { d.set(nudges, forKey: "nudges") } }
    /// ⌃⌥J jump-to-next-waiting, available everywhere.
    @Published var jumpShortcut: Bool { didSet { d.set(jumpShortcut, forKey: "jumpShortcut") } }
    /// Paste drafts into the terminal (needs Accessibility) instead of only copying.
    @Published var autoPaste: Bool { didSet { d.set(autoPaste, forKey: "autoPaste") } }
    /// Hold banners during calendar meetings and warn before them.
    @Published var calendarAware: Bool { didSet { d.set(calendarAware, forKey: "calendarAware") } }
    /// ⌃⌥V dictation.
    @Published var voice: Bool { didSet { d.set(voice, forKey: "voice") } }
    /// Terminal used to start new agents: "auto", or a bundle id.
    @Published var launchTerminal: String { didSet { d.set(launchTerminal, forKey: "launchTerminal") } }
    /// Most-recent-first project folders seen in sessions.
    @Published private(set) var recentProjects: [String]

    func noteProject(_ path: String) {
        guard !path.isEmpty, path != NSHomeDirectory(), path != "/" else { return }
        var list = recentProjects.filter { $0 != path }
        list.insert(path, at: 0)
        if list.count > 15 { list = Array(list.prefix(15)) }
        guard list != recentProjects else { return }
        recentProjects = list
        d.set(list, forKey: "recentProjects")
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("NotchBar: launch-at-login change failed: \(error.localizedDescription)")
            }
        }
    }

    init() {
        screenMode = ScreenMode(rawValue: d.string(forKey: "screenMode") ?? "") ?? .follow
        sounds = d.object(forKey: "sounds") as? Bool ?? true
        cursorApprovals = d.object(forKey: "cursorApprovals") as? Bool ?? false
        readOnlyDefaults = d.object(forKey: "readOnlyDefaults") as? Bool ?? false
        trustMinutes = (d.object(forKey: "trustMinutes") as? Int).map { min(max($0, 5), 240) } ?? 20
        nudges = d.object(forKey: "nudges") as? Bool ?? true
        jumpShortcut = d.object(forKey: "jumpShortcut") as? Bool ?? true
        autoPaste = d.object(forKey: "autoPaste") as? Bool ?? true
        calendarAware = d.object(forKey: "calendarAware") as? Bool ?? false
        voice = d.object(forKey: "voice") as? Bool ?? false
        launchTerminal = d.string(forKey: "launchTerminal") ?? "auto"
        recentProjects = (d.stringArray(forKey: "recentProjects") ?? [])
            .filter { FileManager.default.fileExists(atPath: $0) }
    }
}

import SwiftUI

/// Lays out a row in the menu-bar band as left | camera gap | right. On a Mac
/// with a hardware notch the gap sits exactly under the camera, so nothing
/// hides behind it; elsewhere it collapses to a normal spaced row.
struct BandRow<Leading: View, Trailing: View>: View {
    let gap: CGFloat
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        if gap > 0 {
            HStack(spacing: 0) {
                HStack(spacing: 8) { leading() }.frame(maxWidth: .infinity, alignment: .leading).clipped()
                Color.clear.frame(width: gap)
                HStack(spacing: 8) { trailing() }.frame(maxWidth: .infinity, alignment: .trailing)
            }
        } else {
            HStack(spacing: 10) {
                leading()
                Spacer(minLength: 8)
                trailing()
            }
        }
    }
}
