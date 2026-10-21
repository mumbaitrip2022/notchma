import AppKit
import CryptoKit
import Foundation

/// One-tap updates from GitHub Releases.
///
/// Checks the latest release once a day (only that request, nothing about you is sent),
/// downloads the zip, verifies it (GitHub's SHA-256, bundle id, version, code signature),
/// swaps it into place and relaunches. Hooks keep working because the path doesn't change.
final class Updater: NSObject, ObservableObject {
    struct Release: Equatable {
        let version: String
        let title: String
        let notes: String
        let zipURL: URL
        let sha256: String?
        let size: Int
        let pageURL: URL

        /// "What's new": the release's bullet points, as plain text.
        var highlights: [String] {
            notes.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("- ") }
                .map { String($0.dropFirst(2)).replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "") }
                .prefix(6)
                .map { $0 }
        }

        /// The release's own headline ("Your receipt, any time 🧾").
        var headline: String {
            if let line = notes.components(separatedBy: "\n").first(where: { $0.hasPrefix("## ") }) {
                return String(line.dropFirst(3))
            }
            return title
        }
    }

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available
        case downloading(Double)
        case verifying
        case installing
        case relaunching
        case failed(String)
    }

    static let repo = "mumbaitrip2022/notchma"

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var release: Release?
    /// Set after restarting into a new version, for the "what's new" page.
    struct Installed: Equatable { let version: String; let notes: String }
    @Published var justInstalled: Installed?

    var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    var enabled: () -> Bool = { true }
    /// A newer version was found by a check (manual: also tell when there's nothing new).
    var onFound: ((Release) -> Void)?
    var onUpToDate: (() -> Void)?
    var onFailed: ((String) -> Void)?

    private var timer: Timer?
    private var session: URLSession?
    private var downloadDone: ((URL?, Error?) -> Void)?
    private let defaults = UserDefaults.standard

    var isBusy: Bool {
        switch phase {
        case .downloading, .verifying, .installing, .relaunching: return true
        default: return false
        }
    }

    // MARK: checking

    /// First check shortly after launch, then once a day.
    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.autoCheck() }
        let t = Timer(timeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.autoCheck() }
        t.tolerance = 600
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func autoCheck() {
        guard enabled() else { return }
        if let last = defaults.object(forKey: "updateCheckedAt") as? Date, Date().timeIntervalSince(last) < 20 * 3600 {
            return
        }
        check(manual: false)
    }

    func check(manual: Bool) {
        guard !isBusy, phase != .checking else { return }
        phase = .checking
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("NotchBar/\(current)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
            let parsed = data.flatMap(Self.parse)
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async {
                guard let self else { return }
                self.defaults.set(Date(), forKey: "updateCheckedAt")
                guard ok, let r = parsed else {
                    self.phase = .idle
                    if manual { self.onFailed?("Couldn't reach GitHub. Check your connection") }
                    return
                }
                if Self.isNewer(r.version, than: self.current) {
                    let isNew = self.release?.version != r.version
                    self.release = r
                    self.phase = .available
                    // Automatic checks announce each new version once; asking always shows it.
                    if manual || (isNew && self.defaults.string(forKey: "updateAnnounced") != r.version) {
                        self.defaults.set(r.version, forKey: "updateAnnounced")
                        self.onFound?(r)
                    }
                } else {
                    self.release = nil
                    self.phase = .upToDate
                    if manual { self.onUpToDate?() }
                }
            }
        }.resume()
    }

    static func parse(_ data: Data) -> Release? {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = j["tag_name"] as? String,
              (j["draft"] as? Bool) != true, (j["prerelease"] as? Bool) != true,
              let assets = j["assets"] as? [[String: Any]],
              let zip = assets.first(where: { (($0["name"] as? String) ?? "").hasSuffix(".zip") }),
              let urlString = zip["browser_download_url"] as? String, let url = URL(string: urlString),
              url.scheme == "https", url.host == "github.com",
              let page = URL(string: j["html_url"] as? String ?? "https://github.com/\(repo)/releases/latest")
        else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let digest = (zip["digest"] as? String).flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil }
        return Release(version: version, title: j["name"] as? String ?? "NotchBar \(version)",
                       notes: j["body"] as? String ?? "", zipURL: url, sha256: digest,
                       size: zip["size"] as? Int ?? 0, pageURL: page)
    }

    /// Numeric compare of dotted versions: 1.0.10 > 1.0.9.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    // MARK: installing

    func install() {
        guard let r = release, !isBusy else { return }
        guard !AppLocation.isDevBuild else { return fail("Development builds don't self-update. Run make install") }
        phase = .downloading(0)
        let s = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: .main)
        session = s
        downloadDone = { [weak self] file, error in
            guard let self else { return }
            guard let file, error == nil else { return self.fail("Download failed. Try again in a bit") }
            self.phase = .verifying
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Self.prepare(zip: file, release: r)
                DispatchQueue.main.async {
                    switch result {
                    case let .failure(e): self.fail(e.message)
                    case let .success(app): self.swapAndRelaunch(app, release: r)
                    }
                }
            }
        }
        s.downloadTask(with: r.zipURL).resume()
    }

    struct UpdateError: Error { let message: String }

    /// Off-main: checksum, unzip, and make sure it's really the next NotchBar.
    private static func prepare(zip: URL, release r: Release) -> Result<URL, UpdateError> {
        guard let data = try? Data(contentsOf: zip, options: .mappedIfSafe) else {
            return .failure(.init(message: "The download is unreadable"))
        }
        if let expected = r.sha256 {
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actual == expected.lowercased() else {
                return .failure(.init(message: "The download didn't match GitHub's checksum, so it wasn't installed"))
            }
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("NotchBarUpdate-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard Shell.run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path], timeout: 60)?.ok == true else {
            return .failure(.init(message: "Couldn't unpack the update"))
        }
        let app = dir.appendingPathComponent("NotchBar.app")
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              info["CFBundleShortVersionString"] as? String == r.version else {
            return .failure(.init(message: "The download isn't the NotchBar version it claims to be"))
        }
        guard Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path], timeout: 60)?.ok == true else {
            return .failure(.init(message: "The update's code signature is broken, so it wasn't installed"))
        }
        _ = Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        return .success(app)
    }

    private func swapAndRelaunch(_ newApp: URL, release r: Release) {
        phase = .installing
        let target = Bundle.main.bundleURL
        do {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: newApp, backupItemName: "NotchBar-previous.app",
                                                      options: [])
        } catch {
            return fail("Couldn't replace the app here. Download it from the release page instead")
        }
        // Show "what's new" after the restart.
        defaults.set(r.version, forKey: "justUpdatedTo")
        defaults.set(r.notes, forKey: "justUpdatedNotes")
        phase = .relaunching
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.createsNewApplicationInstance = true
            cfg.arguments = ["--after-move"] // waits for this copy to quit
            NSWorkspace.shared.openApplication(at: target, configuration: cfg) { _, error in
                DispatchQueue.main.async {
                    if error != nil { self.fail("Installed, but couldn't restart. Open NotchBar again"); return }
                    NSApp.terminate(nil)
                }
            }
        }
    }

    private func fail(_ message: String) {
        DiagLog.log("update failed: \(message)")
        session?.invalidateAndCancel()
        session = nil
        phase = .failed(message)
        onFailed?(message)
    }

    /// After a restart into a new version: what was installed, once.
    func takeJustUpdated() -> Installed? {
        guard let v = defaults.string(forKey: "justUpdatedTo") else { return nil }
        let notes = defaults.string(forKey: "justUpdatedNotes") ?? ""
        defaults.removeObject(forKey: "justUpdatedTo")
        defaults.removeObject(forKey: "justUpdatedNotes")
        guard v == current else { return nil }
        justInstalled = Installed(version: v, notes: notes)
        return justInstalled
    }

    #if DEBUG
    /// Test hook: pretend a release exists.
    func debugOffer(_ r: Release) {
        release = r
        phase = .available
        onFound?(r)
    }
    func debugPhase(_ p: Phase) { phase = p }
    #endif
}

extension Updater: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : Int64(release?.size ?? 0)
        guard total > 0 else { return }
        phase = .downloading(min(1, Double(totalBytesWritten) / Double(total)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file is deleted when this returns: keep a copy.
        let keep = FileManager.default.temporaryDirectory.appendingPathComponent("NotchBar-\(UUID().uuidString).zip")
        let ok = (try? FileManager.default.moveItem(at: location, to: keep)) != nil
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        downloadDone?(ok && status == 200 ? keep : nil, nil)
        downloadDone = nil
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        downloadDone?(nil, error)
        downloadDone = nil
    }
}
