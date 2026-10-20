import Foundation

/// Runs command-line tools safely: output is drained concurrently (no pipe
/// deadlocks on large output) and every run has a hard timeout.
/// Call from a background queue — it blocks until the tool finishes.
enum Shell {
    struct Result {
        let status: Int32
        let stdout: String
        let stderr: String
        var ok: Bool { status == 0 }
    }

    static func run(_ path: String, _ args: [String], cwd: String? = nil,
                    timeout: TimeInterval = 10, maxOutput: Int = 4 * 1024 * 1024) -> Result? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0" // never hang waiting for credentials
        env["GIT_OPTIONAL_LOCKS"] = "0"  // don't take repo locks an agent might need
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice

        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        let readers = DispatchQueue(label: "notchbar.shell.read", attributes: .concurrent)
        group.enter()
        readers.async { outData = Self.drain(out.fileHandleForReading, max: maxOutput); group.leave() }
        group.enter()
        readers.async { errData = Self.drain(err.fileHandleForReading, max: 256 * 1024); group.leave() }

        do { try p.run() } catch {
            try? out.fileHandleForWriting.close(); try? err.fileHandleForWriting.close()
            return nil
        }
        // Close our copies of the write ends so readers see EOF when the child exits.
        try? out.fileHandleForWriting.close()
        try? err.fileHandleForWriting.close()

        let deadline = DispatchTime.now() + timeout
        if group.wait(timeout: deadline) == .timedOut {
            p.terminate()
            _ = group.wait(timeout: .now() + 1)
            return nil
        }
        p.waitUntilExit()
        return Result(status: p.terminationStatus,
                      stdout: String(decoding: outData, as: UTF8.self),
                      stderr: String(decoding: errData, as: UTF8.self))
    }

    private static func drain(_ h: FileHandle, max: Int) -> Data {
        var data = Data()
        while true {
            let chunk = h.availableData
            if chunk.isEmpty { break }
            if data.count < max { data.append(chunk.prefix(max - data.count)) }
        }
        return data
    }

    /// Absolute path of a command as your login shell sees it (cached).
    private static var whichCache: [String: String?] = [:]
    private static let whichLock = NSLock()

    static func which(_ command: String) -> String? {
        whichLock.lock()
        if let cached = whichCache[command] { whichLock.unlock(); return cached }
        whichLock.unlock()
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let found = run(shell, ["-lc", "command -v \(command)"], timeout: 5)?.stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let path = (found?.hasPrefix("/") == true && FileManager.default.isExecutableFile(atPath: found!)) ? found : nil
        whichLock.lock(); whichCache[command] = path; whichLock.unlock()
        return path
    }

    /// Quotes a string for a POSIX shell.
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
