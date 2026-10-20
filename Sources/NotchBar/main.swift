import AppKit

signal(SIGPIPE, SIG_IGN)

final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = NotchController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Only one NotchBar at a time.
        if let id = Bundle.main.bundleIdentifier {
            let me = ProcessInfo.processInfo.processIdentifier
            // Just moved to Applications: give the old copy a moment to quit.
            if CommandLine.arguments.contains("--after-move") {
                let deadline = Date().addingTimeInterval(5)
                while Date() < deadline, NSRunningApplication.runningApplications(withBundleIdentifier: id)
                    .contains(where: { $0.processIdentifier != me && !$0.isTerminated }) {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                }
            }
            if NSRunningApplication.runningApplications(withBundleIdentifier: id)
                .contains(where: { $0.processIdentifier != me }) {
                NSApp.terminate(nil)
                return
            }
        }
        if AppLocation.offerMoveIfNeeded() { return } // relaunching from Applications
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
