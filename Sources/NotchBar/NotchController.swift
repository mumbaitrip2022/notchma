import AppKit
import ServiceManagement
import Combine
import SwiftUI

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Lets the first click on the (inactive) panel hit buttons directly.
final class FirstMouseHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the panel: positions it on the right screen, sizes it to the notch,
/// decides when to expand/collapse, and wires the store, services and socket.
final class NotchController: NSObject {
    let store = SessionStore()
    let ui = NotchUI()
    let prefs = Prefs()
    let server = SocketServer()
    let launcher = Launcher()
    let calendar = CalendarWatcher()
    let dictation = Dictation()
    let system = SystemMonitor()
    let pet = PetBrain()
    let updater = Updater()

    var panel: NotchPanel!
    var panelContentView: NSView? { panel.contentView }
    var screen: NSScreen?
    var notchSize = CGSize(width: 200, height: 24)
    private var shrinkWork: DispatchWorkItem?
    private var collapseWork: DispatchWorkItem?
    private var previousApp: NSRunningApplication?
    private var hoverWork: DispatchWorkItem?
    private var remeasureWork: [DispatchWorkItem] = []
    private var receiptNudgeWork: DispatchWorkItem?
    private let hotKeys = HotKeys()
    private var bag = Set<AnyCancellable>()
    private lazy var settingsWindow = SettingsWindowController { [unowned self] in
        AnyView(SettingsView(prefs: self.prefs, rules: self.store.rules, calendar: self.calendar, ledger: self.store.ledger,
                             updater: self.updater, openUpdate: { [weak self] in self?.openUpdate() },
                             openTour: { [weak self] in self?.openTour() },
                             openReport: { [weak self] in self?.openReport() },
                             setAgent: { [weak self] a, on in self?.setHooks(a, installed: on) },
                             applyCursorMode: { [weak self] in
                                 guard let self, self.prefs.installed.contains(.cursor) else { return }
                                 self.setHooks(.cursor, installed: true)
                             },
                             uninstall: { [weak self] in self?.uninstall() }))
    }

    /// Extra transparent room around the notch for its drop shadow.
    private let shadowPad: CGFloat = 28

    private var started = false

    func start() {
        started = true
        buildPanel()
        wireStore()
        wireServices()
        observeSystem()

        do { try server.start() } catch {
            NSLog("NotchBar: socket server failed: \(error.localizedDescription)")
        }
        refreshHooksState()
        repairHooksIfMoved()
        store.seedFromClaudeSessionFiles()
        updateScreen(force: true)
        panel.orderFrontRegardless()
        launcher.refreshCLIs()
        welcomeIfFirstRun()
        wireUpdater()
        checkForCrash()
        DiagLog.log("launch \(updater.current)")
    }

    // MARK: - Updates

    func openUpdate() {
        ui.page = .update
        ui.pinned = true
    }

    private func wireUpdater() {
        updater.enabled = { [weak self] in self?.prefs.autoUpdate ?? false }
        updater.onFound = { [weak self] r in
            self?.store.showBanner(Banner(kind: .update, sessionID: "", agent: .claude,
                                          title: "NotchBar \(r.version) is here ✨",
                                          subtitle: r.headline + ". tap to see what's new", action: .update))
        }
        updater.onUpToDate = { [weak self] in
            guard let self else { return }
            self.store.showBanner(Banner(kind: .update, sessionID: "", agent: .claude,
                                         title: "You're on the latest NotchBar ✨",
                                         subtitle: "version \(self.updater.current). nothing new yet", action: .update))
        }
        updater.onFailed = { [weak self] message in
            guard let self, self.ui.page != .update else { return } // the update page shows it already
            self.store.showBanner(Banner(kind: .attention, sessionID: "", agent: .claude,
                                         title: "Update didn't work", subtitle: message, action: .update))
        }
        // The pet carries a little present while a new version waits.
        updater.$release.map { $0 != nil }.removeDuplicates()
            .sink { [weak self] has in self?.pet.hasGift = has }
            .store(in: &bag)
        updater.$phase.removeDuplicates().dropFirst()
            .sink { [weak self] _ in self?.remeasureSoon() }
            .store(in: &bag)

        // Just restarted into a new version: say hi.
        if let done = updater.takeJustUpdated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self else { return }
                self.store.showBanner(Banner(kind: .update, sessionID: "", agent: .claude,
                                             title: "Updated to NotchBar \(done.version) 🎉",
                                             subtitle: "\(self.store.ledger.petName) unwrapped it. tap to see what's new",
                                             action: .update, important: true))
                self.pet.party()
            }
        }
        updater.start()
    }

    /// First launch: open the notch once so new users see it and the Connect button.
    private func welcomeIfFirstRun() {
        let key = "welcomed"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            self.openTour()
            if self.prefs.sounds { Sounds.done() }
        }
    }

    func openTour() {
        ui.page = .tour
        ui.pinned = true
        DiagLog.log("tour opened")
    }

    private func finishTour() {
        ui.page = .home
        ui.pinned = false
        pet.party()
        DiagLog.log("tour finished")
    }

    func openReport() {
        if ui.crash == nil { ui.crash = Diagnostics.latestCrash(since: Date().addingTimeInterval(-7 * 86_400)) }
        ui.page = .report
        ui.pinned = true
    }

    /// If macOS wrote a NotchBar crash report since the last launch, offer to report it.
    private func checkForCrash() {
        let key = "lastLaunchAt"
        let last = UserDefaults.standard.object(forKey: key) as? Date
        UserDefaults.standard.set(Date(), forKey: key)
        guard let last else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let crash = Diagnostics.latestCrash(since: last) else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.ui.crash = crash
                DiagLog.log("found a crash report from the last run")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self.store.showBanner(Banner(kind: .attention, sessionID: "", agent: .claude,
                                                 title: "NotchBar crashed last time 😵",
                                                 subtitle: "sorry about that. tap to send a report, it takes 10 seconds",
                                                 action: .report, important: true))
                }
            }
        }
    }

    /// Hooks point at this bundle by path. If the app was moved (e.g. Downloads →
    /// Applications), re-point them so agents keep talking to NotchBar.
    private func repairHooksIfMoved() {
        guard AppLocation.isInApplications, !AppLocation.isTranslocated else { return }
        for a in prefs.installed {
            let text = (try? String(contentsOf: Self.configURL(a), encoding: .utf8)) ?? ""
            if !text.contains(hookBinary) { setHooks(a, installed: true) }
        }
    }

    /// Disconnects every agent, moves the app to the Trash and quits.
    func uninstall() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Uninstall NotchBar?"
        alert.informativeText = "This disconnects Claude Code, Codex and Cursor (only NotchBar's entries are removed from their settings), then moves NotchBar to the Trash."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: hookBinary)
        p.arguments = ["uninstall", "claude", "codex", "cursor"]
        p.standardOutput = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        try? SMAppService.mainApp.unregister()
        if !AppLocation.isDevBuild {
            NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { _, _ in }
        }
        NSApp.terminate(nil)
    }

    func stop() {
        DiagLog.log("quit")
        DiagLog.shared.flushNow()
        if started { server.stop() }
    }

    // MARK: - Panel

    private func buildPanel() {
        let p = NotchPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 60),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.isMovable = false
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.acceptsMouseMovedEvents = true
        p.isReleasedWhenClosed = false
        p.appearance = NSAppearance(named: .darkAqua) // system colours resolve to their dark variants

        let actions = NotchActions(
            showMenu: { [weak self] in self?.showMenu() },
            connect: { [weak self] in self?.connectDetectedAgents() },
            bannerTap: { [weak self] b in self?.handleBannerTap(b) },
            openDiff: { [weak self] sid in self?.openDiff(sid) },
            copySummary: { [weak self] sid in self?.copySummary(sid) },
            openSettings: { [weak self] in self?.openSettings() },
            setAgent: { [weak self] a, on in self?.setHooks(a, installed: on) },
            finishTour: { [weak self] in self?.finishTour() })
        let root = RootView(store: store, ui: ui, prefs: prefs, trust: store.trust, launcher: launcher,
                            dictation: dictation, system: system, pet: pet, updater: updater, actions: actions) { [weak self] size in
            // Never resize the window inside SwiftUI's update pass: that re-enters
            // layout and can swallow the state change that triggered it.
            DispatchQueue.main.async { self?.notchSizeChanged(size) }
        }
        let host = FirstMouseHostingView(rootView: root)
        host.sizingOptions = []
        p.contentView = host
        panel = p
    }

    private func notchSizeChanged(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        if size != notchSize { DiagLog.log("notch \(Int(size.width))×\(Int(size.height)) expanded \(ui.expanded)") }
        notchSize = size
        let target = windowSize(for: size)
        let current = panel.frame.size
        // Grow right away so the spring animation is never clipped…
        let grown = CGSize(width: max(target.width, current.width), height: max(target.height, current.height))
        if grown != current { place(size: grown) }
        // …and shrink to fit once the animation has settled, so the empty area
        // around the notch never swallows clicks.
        shrinkWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.place(size: self.windowSize(for: self.notchSize))
        }
        shrinkWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: work)
    }

    /// SwiftUI can drop the last size report when several state changes land in the same
    /// instant (a banner closing as an approval opens), leaving the window at the old, small
    /// size. Any later redraw delivers the missed size, so ask for a couple of redraws.
    private func remeasureSoon() {
        remeasureWork.forEach { $0.cancel() }
        remeasureWork = [0.12, 0.6].map { delay in
            let w = DispatchWorkItem { [weak self] in self?.ui.objectWillChange.send() }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
            return w
        }
    }

    private func windowSize(for notch: CGSize) -> CGSize {
        let floating = ui.expanded || store.banner != nil || dictation.state != .idle
        let pad = floating ? shadowPad : 0
        return CGSize(width: ceil(notch.width + pad * 2), height: ceil(notch.height + pad))
    }

    private func place(size: CGSize) {
        guard let screen else { return }
        let f = screen.frame
        // Never taller than the screen below the menu bar.
        let h = min(size.height, f.height - 40)
        let frame = NSRect(x: round(f.midX - size.width / 2), y: f.maxY - h, width: size.width, height: h)
        if panel.frame != frame { panel.setFrame(frame, display: false) }
    }

    // MARK: - Screen choice

    private func updateScreen(force: Bool = false) {
        let target = pickScreen()
        guard force || target != screen else { return }
        screen = target
        let menuBar = target.frame.maxY - target.visibleFrame.maxY
        let safeTop = target.safeAreaInsets.top
        ui.bandHeight = min(max(safeTop > 0 ? safeTop : menuBar, 24), 38)
        if safeTop > 0,
           let left = target.auxiliaryTopLeftArea, let right = target.auxiliaryTopRightArea {
            ui.hardwareNotchWidth = max(0, target.frame.width - left.width - right.width)
        } else {
            ui.hardwareNotchWidth = 0
        }
        #if DEBUG
        // Lets a notch-less Mac preview the notched-MacBook layout.
        if UserDefaults.standard.bool(forKey: "simulateNotch") {
            ui.hardwareNotchWidth = 185
            ui.bandHeight = 32
        }
        #endif
        place(size: windowSize(for: notchSize))
    }

    private func pickScreen() -> NSScreen {
        let screens = NSScreen.screens
        let primary = screens.first ?? NSScreen.main!
        switch prefs.screenMode {
        case .main:
            return primary
        case .builtin:
            return screens.first { $0.isBuiltIn } ?? primary
        case .follow:
            if let s = screenOfFrontmostWindow() { return s }
            let mouse = NSEvent.mouseLocation
            return screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? primary
        }
    }

    /// Screen holding the frontmost app's top window. Uses only window bounds,
    /// which need no Screen Recording permission.
    private func screenOfFrontmostWindow() -> NSScreen? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return nil }
        for w in list {
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: b), rect.width > 50, rect.height > 50
            else { continue }
            // CG coordinates are top-left based on the primary display.
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            let center = CGPoint(x: rect.midX, y: primaryHeight - rect.midY)
            return NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) }
        }
        return nil
    }

    // MARK: - Wiring

    private func wireStore() {
        server.onMessage = { [weak self] json, client in
            guard let self else { return }
            #if DEBUG
            if self.handleDebug(json) { return }
            #endif
            self.store.handle(json, clientID: client)
        }
        server.onDisconnect = { [weak self] id in self?.store.clientDisconnected(id) }
        store.sendReply = { [weak self] id, json in self?.server.reply(to: id, json) }

        store.cursorApprovalsEnabled = { [weak self] in self?.prefs.cursorApprovals ?? false }
        store.readOnlyDefaults = { [weak self] in self?.prefs.readOnlyDefaults ?? false }
        store.nudgesEnabled = { [weak self] in self?.prefs.nudges ?? true }
        store.autoPaste = { [weak self] in self?.prefs.autoPaste ?? true }
        store.isQuiet = { [weak self] in
            guard let self else { return false }
            return self.prefs.calendarAware && self.calendar.meeting != nil
        }
        store.onProjectSeen = { [weak self] p in self?.prefs.noteProject(p) }

        store.onNewApproval = { [weak self] in
            guard let self else { return }
            self.updateScreen()
            if self.prefs.sounds { Sounds.approval() } // approvals sound even in meetings: they block work
        }
        store.onTurnDone = { [weak self] in
            guard let self else { return }
            self.pet.feed() // a cookie drops into the notch next time the pet is on screen
            self.scheduleReceiptNudge()
            guard self.prefs.sounds, !self.store.isQuiet() else { return }
            Sounds.done()
        }
        wirePet()
        store.$banner.map { $0 != nil }.removeDuplicates().dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                DispatchQueue.main.async { self.notchSizeChanged(self.notchSize) }
                self.remeasureSoon()
            }
            .store(in: &bag)
        store.$approvals.map(\.count).removeDuplicates().dropFirst()
            .sink { [weak self] _ in self?.remeasureSoon() }
            .store(in: &bag)

        // Global shortcuts: approval keys only while something waits; the rest per settings.
        hotKeys.setHandler(.allow) { [weak self] in self?.decideFirst(.allow) }
        hotKeys.setHandler(.deny) { [weak self] in self?.decideFirst(.deny) }
        hotKeys.setHandler(.always) { [weak self] in
            guard let self, let a = self.store.approvals.first, a.offerAlways else { return }
            self.decideFirst(.always)
        }
        hotKeys.setHandler(.trust) { [weak self] in
            guard let self, let a = self.store.approvals.first, a.trustable, !a.risky else { return }
            self.decideFirst(.trust(minutes: self.prefs.trustMinutes))
        }
        hotKeys.setHandler(.jump) { [weak self] in self?.jumpToNext() }
        hotKeys.setHandler(.voice) { [weak self] in self?.dictation.toggle() }
        Publishers.CombineLatest3(store.$approvals.map { !$0.isEmpty }.removeDuplicates(),
                                  prefs.$jumpShortcut, prefs.$voice)
            .sink { [weak self] waiting, jump, voice in
                var keys = Set<HotKeys.Key>()
                if waiting { keys.formUnion([.allow, .deny, .always, .trust]) }
                if jump { keys.insert(.jump) }
                if voice { keys.insert(.voice) }
                self?.hotKeys.setActive(keys)
            }
            .store(in: &bag)

        // Expand while hovered, pinned, typing, on the launcher, or while approvals wait.
        let sticky = Publishers.CombineLatest4(ui.$pinned, ui.$menuOpen, ui.$editing, ui.$page.map { [.launcher, .update, .tour, .report].contains($0) })
            .map { $0 || $1 || $2 || $3 }
        Publishers.CombineLatest3(ui.$hovering, sticky, store.$approvals.map { !$0.isEmpty })
            .receive(on: RunLoop.main)
            .sink { [weak self] hovering, sticky, hasApprovals in
                self?.evaluateExpansion(hovering: hovering, sticky: sticky, hasApprovals: hasApprovals)
            }
            .store(in: &bag)
        ui.$editing.removeDuplicates().sink { [weak self] editing in
            if editing { self?.takeKey() }
        }.store(in: &bag)
        dictation.$state.removeDuplicates().sink { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async { self.notchSizeChanged(self.notchSize) }
        }.store(in: &bag)
    }

    /// Open the notch on today's receipt.
    func openReceipt() {
        ui.page = .receipt
        ui.pinned = true
    }

    /// Once an evening, after a real day of work, the pet lets you know your receipt is ready.
    private func scheduleReceiptNudge() {
        receiptNudgeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.prefs.showPet else { return }
            let ledger = self.store.ledger
            let day = ledger.today
            let hour = Calendar.current.component(.hour, from: Date())
            let key = "receiptNudgeDay"
            guard hour >= 18 || hour < 4, day.tasks >= 3,
                  UserDefaults.standard.string(forKey: key) != day.key,
                  !self.store.isAnyWorking, self.store.approvals.isEmpty, !self.ui.expanded else { return }
            UserDefaults.standard.set(day.key, forKey: key)
            self.store.showBanner(Banner(kind: .pet, sessionID: "", agent: .claude,
                                         title: "\(ledger.petName) printed your receipt 🧾",
                                         subtitle: "\(day.tasks) tasks shipped today. tap to see the damage",
                                         action: .receipt))
            self.pet.party()
        }
        receiptNudgeWork = work
        // Wait for a quiet moment. If an agent is busy by then, the next finished task tries again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: work)
    }

    private func wirePet() {
        let ledger = store.ledger
        pet.level = { ledger.level }
        pet.lastFedAt = { ledger.lastTaskAt }
        pet.streak = { ledger.streak }
        ledger.onLevelChange = { [weak self] old, new in
            guard let self, self.prefs.showPet, new > old else { return }
            let name = ledger.petName
            let title: String, sub: String
            if old == 0 {
                title = "\(name) just hatched 🐣"
                sub = "your first task fed it. it lives in your notch now"
            } else {
                title = "\(name) hit level \(new) ✨"
                switch new {
                case 3: sub = "unlocked a sprout 🌱"
                case 6: sub = "unlocked headphones 🎧"
                case 10: sub = "unlocked the crown 👑 absolute legend"
                default: sub = "keep shipping. hover the notch for today's receipt"
                }
            }
            // Let the "done" banner show first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self.store.showBanner(Banner(kind: .pet, sessionID: "", agent: .claude, title: title,
                                             subtitle: sub, action: .receipt))
                self.pet.party()
            }
        }
    }

    private func wireServices() {
        launcher.terminalPreference = { [weak self] in self?.prefs.launchTerminal ?? "auto" }
        launcher.onMessage = { [weak self] text, isError in
            self?.store.showBanner(Banner(kind: isError ? .attention : .info, sessionID: "", agent: .claude,
                                          title: text, subtitle: "", action: .expand, important: isError))
        }

        calendar.enabled = { [weak self] in self?.prefs.calendarAware ?? false }
        calendar.onUpcoming = { [weak self] title, minutes in
            guard let self else { return }
            let waiting = self.store.queue.count
            let working = self.store.activeCount
            guard waiting + working > 0 else { return }
            var parts: [String] = []
            if waiting > 0 { parts.append("\(waiting) waiting on you") }
            if working > 0 { parts.append("\(working) still working") }
            self.store.showBanner(Banner(kind: .info, sessionID: "", agent: .claude,
                                         title: "\(title) in \(minutes) min",
                                         subtitle: parts.joined(separator: " · ") + ". Clear approvals before you go",
                                         action: .expand, important: true))
        }
        calendar.onMeetingEnded = { [weak self] title in self?.store.flushDigest(context: title) }
        prefs.$calendarAware.sink { [weak self] on in
            DispatchQueue.main.async {
                self?.calendar.setActive(on)
                self?.calendar.check()   // off: just clears the meeting, never opens the calendar
            }
        }.store(in: &bag)

        // System vitals: sample only while you can see them; warn before the disk fills up.
        system.agentRoots = { [weak self] in
            self?.store.sessions.values.compactMap { $0.pid > 1 ? $0.pid : nil } ?? []
        }
        Publishers.CombineLatest(ui.$expanded, prefs.$showVitals)
            .sink { [weak self] expanded, show in self?.system.setLive(expanded && show) }
            .store(in: &bag)
        // The open panel builds a lot of short-lived views. Once it has been closed a few
        // seconds, hand the freed memory back to macOS instead of keeping it reserved.
        ui.$expanded.removeDuplicates().filter { !$0 }.dropFirst()
            .debounce(for: .seconds(4), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, !self.ui.expanded else { return }
                malloc_zone_pressure_relief(nil, 0)
            }
            .store(in: &bag)
        system.onDiskLow = { [weak self] free, critical in
            self?.store.showBanner(Banner(kind: .attention, sessionID: "", agent: .claude,
                                          title: "SSD almost full, only \(SystemMonitor.diskString(free)) left",
                                          subtitle: critical ? "Builds and agents will start failing soon" : "Agents' builds and caches can fill it quickly",
                                          action: .expand, important: critical))
        }
        system.onMemoryCritical = { [weak self] in
            self?.store.showBanner(Banner(kind: .attention, sessionID: "", agent: .claude,
                                          title: "Your Mac is short of memory",
                                          subtitle: "Memory pressure is critical. Pause an agent or close a few apps",
                                          action: .expand, important: true))
        }

        dictation.onFinal = { [weak self] text in self?.routeDictation(text) }
        dictation.onError = { [weak self] msg in
            self?.store.showBanner(Banner(kind: .attention, sessionID: "", agent: .claude,
                                          title: "Dictation unavailable", subtitle: msg, action: .expand, important: true))
        }
    }

    // MARK: - Actions

    private func decideFirst(_ d: SessionStore.Decision) {
        guard let a = store.approvals.first else { return }
        store.decide(a, d)
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    /// ⌃⌥J: approvals open the notch; everything else jumps to its terminal.
    private func jumpToNext() {
        guard let next = store.queue.first else {
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            return
        }
        if store.approvals.contains(where: { $0.sessionID == next.id }) {
            ui.pinned = true
        } else {
            store.jump(to: next.id)
        }
    }

    private func handleBannerTap(_ b: Banner) {
        store.dismissBanner()
        switch b.action {
        case .jump: if store.session(b.sessionID) != nil { store.jump(to: b.sessionID) }
        case let .copyAndJump(text): store.copyAndJump(text, sid: b.sessionID)
        case .sendDraft: store.sendDraft(b.sessionID)
        case .expand: ui.pinned = true
        case .receipt: openReceipt()
        case .update: openUpdate()
        case .report: openReport()
        }
    }

    /// Dictated text becomes the next prompt for the session you're most likely talking to.
    private func routeDictation(_ text: String) {
        let target = ui.openRow.flatMap { store.session($0) }
            ?? store.queue.first(where: { !store.approvals.map(\.sessionID).contains($0.id) })
            ?? store.sortedSessions.first
        guard let s = target else {
            let pb = NSPasteboard.general
            pb.clearContents(); pb.setString(text, forType: .string)
            store.showBanner(Banner(kind: .info, sessionID: "", agent: .claude, title: "Copied your dictation",
                                    subtitle: ToolInfo.clip(text, 70), action: .expand))
            return
        }
        store.drafts[s.id] = text
        let busy = store.isBusy(s)
        store.sendDraft(s.id) // queues if busy, otherwise delivers now
        if busy {
            store.showBanner(Banner(kind: .draft, sessionID: s.id, agent: s.agent,
                                    title: "Queued for \(s.projectName). Sends when it finishes",
                                    subtitle: ToolInfo.clip(text, 60), action: .expand))
        }
    }

    private func openDiff(_ sid: String) {
        guard let s = store.session(sid) else { return }
        Review.openDiff(for: s) { [weak self] outcome in
            let message: String?
            switch outcome {
            case .opened: message = nil
            case .noChanges: message = "No uncommitted changes in \(s.projectName)"
            case .notGit: message = "\(s.projectName) isn't a git repository"
            case let .failed(why): message = why
            }
            if let message {
                self?.store.showBanner(Banner(kind: .info, sessionID: sid, agent: s.agent, title: message,
                                              subtitle: "", action: .expand))
            }
        }
    }

    private func copySummary(_ sid: String) {
        guard let s = store.session(sid) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(Review.summary(for: s), forType: .string)
        store.attend(sid)
    }

    private func openSettings() {
        ui.pinned = false
        settingsWindow.show()
    }

    // MARK: - Expand / collapse

    private func evaluateExpansion(hovering: Bool, sticky: Bool, hasApprovals: Bool) {
        let want = hovering || sticky || hasApprovals
        collapseWork?.cancel()
        hoverWork?.cancel()
        // Hover intent: a pointer just passing through the menu bar shouldn't
        // pop the island open, so wait a beat before expanding on hover alone.
        if want && !ui.expanded && hovering && !sticky && !hasApprovals {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.ui.hovering else { return }
                self.setExpanded(true)
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
            hoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
            return
        }
        if want {
            setExpanded(true)
            // Keyboard focus only while typing, or while the pointer is on an approval,
            // so ⌘↩ / ⌘⌫ / esc work without stealing your typing otherwise.
            if ui.editing || (hovering && hasApprovals) { takeKey() } else if !hovering { giveBackKey() }
        } else {
            let work = DispatchWorkItem { [weak self] in
                self?.setExpanded(false)
                self?.giveBackKey()
            }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: work)
        }
    }

    private func setExpanded(_ value: Bool) {
        guard ui.expanded != value else { return }
        if value { updateScreen(); pet.poke() }
        DiagLog.log(value ? "expand (page \(ui.page))" : "collapse")
        // Expand first, then drop the banner, so the notch never passes through the small pill in between.
        withAnimation(NotchUI.motion) { ui.expanded = value }
        if value { store.dismissBanner() }
        remeasureSoon()
        if !value {
            ui.pinned = false
            ui.idleShowsSessions = false
            ui.page = .home
        }
    }

    private func takeKey() {
        guard !panel.isKeyWindow else { return }
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
        panel.makeKey()
    }

    private func giveBackKey() {
        guard panel.isKeyWindow, !ui.editing else { return }
        panel.resignKey()
        previousApp?.activate()
        previousApp = nil
    }

    // MARK: - System observers

    private func observeSystem() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(contextChanged),
                       name: NSWorkspace.didActivateApplicationNotification, object: nil)
        ws.addObserver(self, selector: #selector(contextChanged),
                       name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                       name: NSApplication.didChangeScreenParametersNotification, object: nil)
        prefs.$screenMode.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateScreen(force: true) }
            .store(in: &bag)
    }

    @objc private func contextChanged() {
        guard prefs.screenMode == .follow, !ui.expanded else { return }
        // Window frames settle a moment after activation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in self?.updateScreen() }
    }

    @objc private func screensChanged() {
        updateScreen(force: true)
        panel.orderFrontRegardless()
    }

    // MARK: - Menu

    private func showMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(MenuItem("New Task…") { [weak self] in self?.ui.page = .launcher })
        if prefs.showPet {
            menu.addItem(MenuItem("Today's Receipt") { [weak self] in self?.openReceipt() })
        }
        if let r = updater.release {
            menu.addItem(MenuItem("Update to \(r.version)…") { [weak self] in self?.openUpdate() })
        } else {
            menu.addItem(MenuItem("Check for Updates…") { [weak self] in
                self?.updater.check(manual: true)
            })
        }
        menu.addItem(MenuItem("Settings…", key: ",") { [weak self] in self?.openSettings() })
        menu.addItem(MenuItem("Report a Problem…") { [weak self] in self?.openReport() })
        menu.addItem(MenuItem("Show Tour") { [weak self] in self?.openTour() })
        menu.addItem(.separator())

        let agentsHeader = NSMenuItem(title: "Agents", action: nil, keyEquivalent: "")
        agentsHeader.isEnabled = false
        menu.addItem(agentsHeader)
        for agent in Agent.allCases {
            let on = prefs.installed.contains(agent)
            let item = MenuItem(agent.name) { [weak self] in self?.setHooks(agent, installed: !on) }
            item.state = on ? .on : .off
            if !on && !Self.agentDetected(agent) { item.toolTip = "Not found on this Mac" }
            menu.addItem(item)
        }
        if !store.trust.active.isEmpty {
            menu.addItem(.separator())
            for t in store.trust.active {
                let name = (t.project as NSString).lastPathComponent
                menu.addItem(MenuItem("End trust for \(name)") { [weak self] in self?.store.trust.end(project: t.project) })
            }
        }
        menu.addItem(.separator())
        let sounds = MenuItem("Sounds") { [weak self] in self?.prefs.sounds.toggle() }
        sounds.state = prefs.sounds ? .on : .off
        menu.addItem(sounds)
        menu.addItem(MenuItem("Quit NotchBar", key: "q") { NSApp.terminate(nil) })
        let un = MenuItem("Uninstall NotchBar…") { [weak self] in self?.uninstall() }
        un.isAlternate = true          // shows while holding ⌥
        un.keyEquivalentModifierMask = .option
        menu.addItem(un)

        ui.menuOpen = true
        let loc = NSEvent.mouseLocation
        let inWindow = panel.convertPoint(fromScreen: loc)
        menu.popUp(positioning: nil, at: inWindow, in: panel.contentView)
        ui.menuOpen = false
        // Collapse if the pointer left while the menu was open.
        ui.hovering = NSMouseInRect(NSEvent.mouseLocation, panel.frame, false)
    }

    // MARK: - Hooks

    private var hookBinary: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/notchbar-hook").path
    }

    static func configURL(_ agent: Agent) -> URL {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        switch agent {
        case .claude: return home.appendingPathComponent(".claude/settings.json")
        case .codex: return home.appendingPathComponent(".codex/hooks.json")
        case .cursor: return home.appendingPathComponent(".cursor/hooks.json")
        }
    }

    /// Is this agent set up on the Mac at all?
    static func agentDetected(_ agent: Agent) -> Bool {
        let home = NSHomeDirectory()
        switch agent {
        case .claude: return FileManager.default.fileExists(atPath: home + "/.claude")
        case .codex: return FileManager.default.fileExists(atPath: home + "/.codex")
        case .cursor: return FileManager.default.fileExists(atPath: home + "/.cursor")
        }
    }

    private func refreshHooksState() {
        var set = Set<Agent>()
        for a in Agent.allCases {
            let text = (try? String(contentsOf: Self.configURL(a), encoding: .utf8)) ?? ""
            if text.contains("notchbar-hook") { set.insert(a) }
        }
        prefs.installed = set
    }

    private func connectDetectedAgents() {
        for a in Agent.allCases where Self.agentDetected(a) { setHooks(a, installed: true) }
    }

    private func setHooks(_ agent: Agent, installed: Bool) {
        let token = agent == .cursor && prefs.cursorApprovals ? "cursor-approve" : agent.rawValue
        let p = Process()
        p.executableURL = URL(fileURLWithPath: hookBinary)
        p.arguments = [installed ? "install" : "uninstall", token]
        p.standardOutput = FileHandle.nullDevice
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.refreshHooksState() }
        }
        do { try p.run() } catch {
            NSLog("NotchBar: could not run hook installer: \(error.localizedDescription)")
        }
    }
}

#if DEBUG
extension NotchController {
    /// Debug-only test hooks (not compiled into release builds).
    func handleDebug(_ json: [String: Any]) -> Bool {
        switch json["hook_event_name"] as? String {
        case "_Snapshot":
            guard let path = json["path"] as? String, let view = panelContentView else { return true }
            view.layoutSubtreeIfNeeded()
            let scale: CGFloat = 2
            let size = view.bounds.size
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return true }
            let cg = ctx.cgContext
            cg.setFillColor(NSColor(white: 0.93, alpha: 1).cgColor) // fake light wallpaper
            cg.fill(CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
            cg.translateBy(x: 0, y: size.height * scale)
            cg.scaleBy(x: scale, y: -scale)
            if (json["live"] as? Bool) == true, let p = view.layer?.presentation() {
                p.render(in: cg) // what's on screen right now, mid-animation
            } else {
                view.layer?.render(in: cg)
            }
            if ui.hasHardwareNotch {
                // Mark where the camera would be, to check nothing sits behind it.
                cg.setFillColor(NSColor.systemRed.withAlphaComponent(0.45).cgColor)
                cg.fill(CGRect(x: (size.width - ui.hardwareNotchWidth) / 2, y: 0,
                               width: ui.hardwareNotchWidth, height: ui.bandHeight))
            }
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            return true
        case "_Decide":
            if let a = store.approvals.first {
                let d: SessionStore.Decision
                switch json["decision"] as? String {
                case "deny": d = .deny
                case "terminal": d = .terminal
                case "always": d = .always
                case "trust": d = .trust(minutes: 20)
                default: d = .allow
                }
                store.decide(a, d)
            }
            return true
        case "_Dump":
            let txt = "panel=\(panel.frame) notch=\(notchSize) screen=\(String(describing: screen?.frame)) expanded=\(ui.expanded) approvals=\(store.approvals.count) sessions=\(store.sessions.count) hover=\(ui.hovering) pinned=\(ui.pinned) mouse=\(NSEvent.mouseLocation)\n"
            try? txt.write(toFile: json["path"] as? String ?? "/dev/null", atomically: true, encoding: .utf8)
            return true
        case "_Age":
            store.debugAge(json["sid"] as? String ?? "", minutes: json["minutes"] as? Double ?? 10)
            return true
        case "_Draft":
            if let sid = json["sid"] as? String { store.drafts[sid] = json["text"] as? String }
            return true
        case "_QueueByPrompt":
            // Test hook: queue a follow-up for the session whose prompt contains `match`.
            if let m = json["match"] as? String, let text = json["text"] as? String,
               let s = store.sessions.values.first(where: { $0.lastPrompt.contains(m) }) {
                store.queue(s.id, text)
            }
            return true
        case "_Vitals":
            let txt = String(format: "cpu=%.1f agent=%.1f memUsed=%.2fGiB total=%.2fGiB pressure=%d diskFree=%.2fGB diskTotal=%.1fGB\n",
                             system.cpu, system.agentCPU, Double(system.memUsed) / 1_073_741_824,
                             Double(system.memTotal) / 1_073_741_824, system.pressure.rawValue,
                             Double(system.diskFree) / 1e9, Double(system.diskTotal) / 1e9)
            try? txt.write(toFile: json["path"] as? String ?? "/dev/null", atomically: true, encoding: .utf8)
            return true
        case "_Send":
            if let sid = json["sid"] as? String { store.sendDraft(sid) }
            return true
        case "_Tap":
            if let b = store.banner { handleBannerTap(b) }
            return true
        case "_Open":
            ui.openRow = json["sid"] as? String
            return true
        case "_Page":
            switch json["page"] as? String {
            case "launcher": ui.page = .launcher
            case "receipt": ui.page = .receipt
            case "tour": openTour()
            case "report": openReport()
            default: ui.page = .home
            }
            return true
        case "_AllowAll":
            store.allowAll(sessionID: json["sid"] as? String ?? "")
            return true
        case "_Hover":
            ui.hovering = (json["on"] as? Bool) ?? false
            return true
        case "_PetDemo":
            // Sample numbers in memory only, to preview the receipt and outfits.
            var d = DayLedger.Day(key: DayLedger.dayKey(Date()))
            let now = Date()
            func t(_ a: Agent, _ p: String, _ m: Double, _ tok: Int, _ c: Double, _ add: Int, _ rem: Int) -> DayLedger.Turn {
                .init(key: UUID().uuidString, agent: a.rawValue, project: p, duration: m * 60, tokens: tok, cost: c,
                      added: add, removed: rem, endedAt: now)
            }
            if (json["empty"] as? Bool) != true {
                d.turns = [t(.claude, "notchbar", 42, 900_000, 2.10, 640, 120), t(.claude, "notchbar", 18, 400_000, 0.9, 220, 80),
                           t(.cursor, "landing-page", 26, 600_000, 1.2, 300, 110), t(.claude, "api", 9, 200_000, 0.62, 44, 8)]
                d.files = Set((0..<37).map { "f\($0)" })
                d.commands = 86; d.testsPassed = 112; d.testsFailed = 0; d.allowed = 19; d.denied = 2; d.autoAllowed = 7
            }
            let tasks = json["tasks"] as? Int ?? 60
            store.ledger.debugFill(d, lifetime: .init(tasks: tasks, files: tasks * 3, tests: 400, approvals: 50))
            pet.lastPrinted = ""
            ui.forceIdle = (json["idle"] as? Bool) ?? true
            return true
        case "_PetShare":
            let l = store.ledger
            var pose = PetSprite.Pose(eyes: .happy, mouth: .smile, blush: true, outfit: .forLevel(l.level))
            pose.egg = l.level == 0
            let c = ReceiptContent.make(day: l.today, number: l.receiptNumber, petName: l.petName, streak: l.streak)
            if let img = MainActor.assumeIsolated({ ReceiptExport.image(ReceiptShareCard(content: c, pose: pose, petName: l.petName, level: l.level)) }),
               let data = ReceiptExport.png(img) {
                try? data.write(to: URL(fileURLWithPath: json["path"] as? String ?? "/dev/null"))
            }
            return true
        case "_Promo":
            MainActor.assumeIsolated { Promo.write(to: json["dir"] as? String ?? NSTemporaryDirectory()) }
            return true
        case "_Update":
            switch json["do"] as? String {
            case "install": updater.install()
            case "open": openUpdate()
            case "fake":
                updater.debugOffer(.init(version: "9.9.9", title: "NotchBar 9.9.9",
                                         notes: "## A test release 🧪\n\n- First thing that got better\n- **Second** thing, with more words so it wraps a little\n- Third thing",
                                         zipURL: URL(string: "https://github.com/x/y.zip")!, sha256: nil, size: 2_500_000,
                                         pageURL: URL(string: "https://github.com/\(Updater.repo)/releases")!))
            default: updater.check(manual: true)
            }
            return true
        case "_TourStep":
            NotificationCenter.default.post(name: .init("NBTourStep"), object: json["step"] as? Int ?? 0)
            return true
        case "_PetAct":
            switch json["act"] as? String {
            case "feed": pet.feed()
            case "party": pet.party()
            case "pet": pet.pet()
            case "sleep": pet.debugSleep()
            default: pet.poke()
            }
            return true
        default:
            return false
        }
    }
}
#endif

/// NSMenuItem with a closure action.
final class MenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, key: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
    var isBuiltIn: Bool { CGDisplayIsBuiltin(displayID) != 0 }
}

enum Sounds {
    private static let approvalSound: NSSound? = {
        let s = NSSound(named: "Glass"); s?.volume = 0.45; return s
    }()
    private static let doneSound: NSSound? = {
        let s = NSSound(named: "Pop"); s?.volume = 0.35; return s
    }()
    static func approval() { approvalSound?.stop(); approvalSound?.play() }
    static func done() { doneSound?.stop(); doneSound?.play() }
}
