import AppKit
import CoreGraphics
import Foundation
import IOKit

/// Keeps a MacBook running with the lid closed, safely.
///
/// macOS sleeps on lid close no matter which app asks it not to; only
/// `pmset disablesleep` (root) stops that. So NotchBar installs, once and with
/// the user's password, a tiny root helper run by launchd. The helper does one
/// thing: while NotchBar keeps a heartbeat file fresh, sleep stays off; when the
/// heartbeat stops (work done, NotchBar quit, crashed or hung), sleep comes back
/// within a minute. It never undoes a sleep setting it didn't change itself.
final class LidGuard: ObservableObject {
    static let label = "dev.notchbar.lidguard"
    /// Bump when the helper script changes, so existing installs are refreshed.
    static let version = 1
    static let plistPath = "/Library/LaunchDaemons/\(label).plist"
    static let supportDir = "/Library/Application Support/NotchBar"
    static let scriptPath = supportDir + "/lidguard.sh"
    /// How old the heartbeat may get before the helper gives sleep back.
    static let staleAfter = 60

    enum Phase: Equatable { case idle, installing, failed(String) }

    @Published private(set) var installed = false
    @Published private(set) var phase: Phase = .idle
    /// NotchBar is asking the helper to hold sleep off.
    @Published private(set) var holding = false
    /// macOS confirms lid sleep is off: safe to close the lid.
    @Published private(set) var ready = false

    let isLaptop: Bool = LidGuard.hasLid()
    private let heartbeat: String

    init(home: String = NSHomeDirectory()) {
        heartbeat = home + "/Library/Application Support/NotchBar/lid-awake"
        refreshInstalled()
        // Left over from a crash or forced quit: let sleep come back now.
        try? FileManager.default.removeItem(atPath: heartbeat)
    }

    func refreshInstalled() {
        let script = (try? String(contentsOfFile: Self.scriptPath, encoding: .utf8)) ?? ""
        installed = FileManager.default.fileExists(atPath: Self.plistPath)
            && script.contains("# version \(Self.version)\n") && script.contains(heartbeat)
    }

    // MARK: heartbeat

    /// Ask the helper to keep (true) or stop keeping (false) the Mac awake with the lid closed.
    /// Call every few seconds while it should stay on; a stale heartbeat counts as off.
    func setHolding(_ on: Bool) {
        let fm = FileManager.default
        if on, installed {
            if fm.fileExists(atPath: heartbeat) {
                try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: heartbeat)
            } else {
                try? fm.createDirectory(atPath: (heartbeat as NSString).deletingLastPathComponent,
                                        withIntermediateDirectories: true)
                fm.createFile(atPath: heartbeat, contents: Data())
            }
            if !holding { holding = true }
            if !ready { confirmSoon() }
        } else {
            guard holding || fm.fileExists(atPath: heartbeat) else { return }
            try? fm.removeItem(atPath: heartbeat)
            holding = false
            ready = false
            // Work's done with the lid shut and nothing else on screen: sleep now
            // instead of cooking in a bag until the idle timer runs out.
            if Self.lidClosed(), !Self.hasExternalDisplay() { Self.sleepSoon() }
        }
    }

    /// Check with macOS that sleep is really off before saying the lid can close.
    private var confirming = false
    private func confirmSoon() {
        guard !confirming else { return }
        confirming = true
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.2) { [weak self] in
            let off = Self.sleepDisabled()
            DispatchQueue.main.async {
                guard let self else { return }
                self.confirming = false
                if self.holding && off { self.ready = true } else if self.holding { self.confirmSoon() }
            }
        }
    }

    /// Is lid/system sleep switched off right now (`pmset -g` shows SleepDisabled 1)?
    static func sleepDisabled() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return parseSleepDisabled(text)
    }

    static func parseSleepDisabled(_ pmset: String) -> Bool {
        pmset.split(separator: "\n").contains { line in
            let parts = line.split(whereSeparator: \.isWhitespace)
            return parts.count == 2 && parts[0] == "SleepDisabled" && parts[1] == "1"
        }
    }

    // MARK: install / remove

    /// One-time setup. Shows the standard macOS password prompt.
    func install(done: @escaping (Bool) -> Void) {
        phase = .installing
        let script = Self.installScript(heartbeat: heartbeat)
        // Let the UI show "Setting up…" before the password sheet takes over.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            let result = Self.runAsAdmin(script, prompt: "NotchBar wants to keep your Mac awake with the lid closed. You only need to do this once.")
            self.refreshInstalled()
            switch result {
            case .ok where self.installed: self.phase = .idle
            case .cancelled: self.phase = .idle
            case let .failed(m): self.phase = .failed(m)
            default: self.phase = .failed("The helper didn't install. Try again?")
            }
            done(self.installed)
        }
    }

    /// Remove the helper and give sleep back. Asks for the password again.
    @discardableResult
    func uninstall() -> Bool {
        setHolding(false)
        let ok = Self.runAsAdmin(Self.removeScript, prompt: "NotchBar wants to remove its closed-lid helper.") == .ok
        refreshInstalled()
        return ok
    }

    // MARK: scripts

    /// The root helper. Reads only the heartbeat's age; never writes to the user's folder.
    static func guardScript(heartbeat: String) -> String {
        """
        #!/bin/sh
        # NotchBar closed-lid helper
        # version \(version)
        # Keeps sleep off only while NotchBar's heartbeat is fresh. Removing NotchBar's
        # Keep Awake helper (Settings) deletes this file and its launchd job.
        HB=\(shellQuote(heartbeat))
        STATE=\(shellQuote(supportDir + "/lidguard.on"))
        want=0
        if [ -f "$HB" ]; then
          age=$(( $(/bin/date +%s) - $(/usr/bin/stat -f %m "$HB" 2>/dev/null || echo 0) ))
          [ "$age" -lt \(staleAfter) ] && want=1
        fi
        if [ "$want" = 1 ]; then
          [ -f "$STATE" ] || { /usr/bin/pmset -a disablesleep 1 && /usr/bin/touch "$STATE"; }
        elif [ -f "$STATE" ]; then
          /usr/bin/pmset -a disablesleep 0 && /bin/rm -f "$STATE"
        fi
        exit 0

        """
    }

    static func plist(heartbeat: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>\(label)</string>
          <key>ProgramArguments</key><array><string>/bin/sh</string><string>\(scriptPath)</string></array>
          <key>WatchPaths</key><array><string>\(xmlEscape((heartbeat as NSString).deletingLastPathComponent))</string></array>
          <key>StartInterval</key><integer>20</integer>
          <key>RunAtLoad</key><true/>
          <key>ThrottleInterval</key><integer>2</integer>
        </dict>
        </plist>

        """
    }

    static func installScript(heartbeat: String) -> String {
        """
        set -e
        mkdir -p \(shellQuote(supportDir))
        printf '%s' \(shellQuote(guardScript(heartbeat: heartbeat))) > \(shellQuote(scriptPath))
        chown root:wheel \(shellQuote(supportDir)) \(shellQuote(scriptPath))
        chmod 755 \(shellQuote(supportDir)) \(shellQuote(scriptPath))
        printf '%s' \(shellQuote(plist(heartbeat: heartbeat))) > \(shellQuote(plistPath))
        chown root:wheel \(shellQuote(plistPath))
        chmod 644 \(shellQuote(plistPath))
        launchctl bootout system/\(label) 2>/dev/null || true
        launchctl bootstrap system \(shellQuote(plistPath))
        """
    }

    static var removeScript: String {
        """
        launchctl bootout system/\(label) 2>/dev/null || true
        if [ -f \(shellQuote(supportDir + "/lidguard.on")) ]; then /usr/bin/pmset -a disablesleep 0; fi
        rm -f \(shellQuote(plistPath)) \(shellQuote(scriptPath)) \(shellQuote(supportDir + "/lidguard.on"))
        rmdir \(shellQuote(supportDir)) 2>/dev/null || true
        """
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    enum AdminResult: Equatable { case ok, cancelled, failed(String) }

    /// Runs a shell script as root behind the standard macOS password prompt.
    /// The script travels base64-encoded, so no quoting can break out of it.
    static func runAsAdmin(_ script: String, prompt: String) -> AdminResult {
        let b64 = Data(script.utf8).base64EncodedString()
        let source = "do shell script \"echo \(b64) | /usr/bin/base64 -D | /bin/sh\" with prompt \"\(prompt)\" with administrator privileges"
        var err: NSDictionary?
        _ = NSAppleScript(source: source)?.executeAndReturnError(&err)
        guard let err else { return .ok }
        if (err[NSAppleScript.errorNumber] as? Int) == -128 { return .cancelled }
        let msg = err[NSAppleScript.errorMessage] as? String ?? "Unknown error"
        NSLog("NotchBar: closed-lid helper: \(msg)")
        return .failed("Setup didn't finish. Try again?")
    }

    // MARK: hardware

    /// Does this Mac have a lid? (MacBooks report a clamshell state; desktops don't.)
    static func hasLid() -> Bool { clamshellState() != nil }

    static func lidClosed() -> Bool { clamshellState() ?? false }

    private static func clamshellState() -> Bool? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        let v = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return v as? Bool
    }

    static func hasExternalDisplay() -> Bool {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &n) == .success else { return false }
        return ids.prefix(Int(n)).contains { CGDisplayIsBuiltin($0) == 0 }
    }

    /// Give the helper a moment to turn sleep back on, then sleep.
    private static func sleepSoon() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 4) {
            guard lidClosed(), !hasExternalDisplay() else { return }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            p.arguments = ["sleepnow"]
            try? p.run()
        }
    }
}
