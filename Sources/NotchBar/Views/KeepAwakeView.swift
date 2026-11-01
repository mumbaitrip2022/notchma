import SwiftUI

/// The Keep Awake page in the notch: what's happening, one tap to start, and the lid switch.
struct KeepAwakeView: View {
    @ObservedObject var keepAwake: KeepAwake
    @ObservedObject var lid: LidGuard
    @ObservedObject var prefs: Prefs
    @ObservedObject var ui: NotchUI
    var setLid: (Bool) -> Void

    private let green = Color(red: 0.25, green: 0.84, blue: 0.47)
    private var hot: Bool { ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            BandRow(gap: ui.cameraGap) {
                Button { ui.page = .home } label: {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .bold))
                        .frame(width: 26, height: 26).contentShape(Circle())
                }
                .buttonStyle(CircleIconButtonStyle())
                .help("Back")
                Text("Keep awake").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            } trailing: {
                EmptyView()
            }
            .frame(height: max(ui.bandHeight, 30))
            .padding(.horizontal, 8)

            statusCard
            if lid.isLaptop { lidCard }
            autoCard
        }
        .animation(NotchUI.motion, value: keepAwake.reason)
        .animation(NotchUI.motion, value: keepAwake.lidHeld)
        .animation(NotchUI.motion, value: lid.phase)
        .animation(NotchUI.motion, value: lid.ready)
    }

    // MARK: status + durations

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(on ? green.opacity(0.18) : Palette.surface3)
                    Image(systemName: keepAwake.pausedForBattery ? "battery.25" : "cup.and.saucer.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(on ? green : Palette.text2)
                        .symbolEffect(.bounce, value: on)
                }
                .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 2) {
                    TimelineView(.periodic(from: .now, by: 15)) { ctx in
                        Text(title(now: ctx.date))
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                            .contentTransition(.numericText())
                    }
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(Palette.text3).lineLimit(2)
                }
                Spacer(minLength: 8)
                if keepAwake.isManual {
                    if !keepAwake.isUnlimited {
                        Button("+15 min") { keepAwake.extend(minutes: 15) }
                            .buttonStyle(NBButtonStyle(kind: .secondary, compact: true))
                    }
                    Button("Stop") { keepAwake.stop() }
                        .buttonStyle(NBButtonStyle(kind: .secondary, compact: true))
                }
            }
            HStack(spacing: 6) {
                Text("For").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.text3)
                    .padding(.trailing, 2)
                ForEach(KeepAwake.presets, id: \.self) { m in
                    pill(m < 60 ? "\(m) min" : "\(m / 60) hr") { keepAwake.start(minutes: m) }
                }
                pill("Until I stop", selected: keepAwake.isUnlimited) { keepAwake.start(minutes: nil) }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.surface2))
    }

    private var on: Bool { keepAwake.reason != nil }

    private func title(now: Date) -> String {
        if let until = keepAwake.until {
            return keepAwake.isUnlimited ? "Awake until you stop it" : "Awake, " + KeepAwake.remaining(until: until, now: now)
        }
        if keepAwake.pausedForBattery { return "Letting it sleep" }
        if keepAwake.reason == .agents { return "Awake while agents work" }
        return "Sleeping like normal"
    }

    private var subtitle: String {
        if keepAwake.pausedForBattery { return "Battery's low. Plug in and it'll stay up for your agents." }
        if keepAwake.reason == .agents { return "It naps again once they're done." }
        if keepAwake.isManual { return "The screen can still turn off." }
        return prefs.keepAwake ? "Stays up on its own whenever an agent is working." : "Pick a time to keep it up."
    }

    private func pill(_ label: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected ? Color.black : .white)
                .padding(.horizontal, 11).frame(height: 26)
                .background(Capsule().fill(selected ? Color.white : Palette.surface3))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: lid

    private var lidCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(lidActive ? green : Palette.text2)
                .frame(width: 38, height: 38)
                .background(Circle().fill(lidActive ? green.opacity(0.18) : Palette.surface3))
            VStack(alignment: .leading, spacing: 2) {
                Text("Keep going with the lid closed").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                lidStatus
            }
            Spacer(minLength: 8)
            if lid.phase == .installing {
                ProgressView().controlSize(.small)
            } else {
                Toggle("", isOn: Binding(get: { prefs.lidClosedAwake && lid.installed }, set: setLid))
                    .toggleStyle(NotchSwitch()).labelsHidden()
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.surface2))
    }

    private var lidActive: Bool { keepAwake.lidHeld && lid.ready }

    @ViewBuilder private var lidStatus: some View {
        if case let .failed(m) = lid.phase {
            Text(m).font(.system(size: 12)).foregroundStyle(.orange)
        } else if lid.phase == .installing {
            Text("Setting up, check for the password box").font(.system(size: 12)).foregroundStyle(Palette.text3)
        } else if !(prefs.lidClosedAwake && lid.installed) {
            Text("One switch. Your Mac asks for your password once.").font(.system(size: 12)).foregroundStyle(Palette.text3)
        } else if hot {
            Text("Paused, your Mac is running hot").font(.system(size: 12)).foregroundStyle(.orange)
        } else if lidActive {
            HStack(spacing: 6) {
                Circle().fill(green).frame(width: 7, height: 7)
                Text("Ready to close the lid").font(.system(size: 12, weight: .semibold)).foregroundStyle(green)
            }
        } else if keepAwake.lidHeld {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Getting ready, hold the lid a sec").font(.system(size: 12)).foregroundStyle(Palette.text3)
            }
        } else {
            Text("Kicks in whenever your Mac is kept awake").font(.system(size: 12)).foregroundStyle(Palette.text3)
        }
    }

    // MARK: auto + battery

    private var autoCard: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Stay awake while agents work").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Text(batteryLine).font(.system(size: 12)).foregroundStyle(Palette.text3)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $prefs.keepAwake).toggleStyle(NotchSwitch()).labelsHidden()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.surface2))
    }

    private var batteryLine: String {
        let floor = prefs.awakeBatteryFloor
        let rule = floor >= 100 ? "only stays up while plugged in" : "keeps going down to \(floor)%"
        guard let b = KeepAwake.batteryLevel() else { return "Plugged in, so no battery limit" }
        return (b.pluggedIn ? "Plugged in" : "Battery at \(b.percent)%") + ", " + rule
    }
}

/// A switch that reads clearly in the notch. The system one draws gray there,
/// because the notch never becomes the active window.
struct NotchSwitch: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule().fill(configuration.isOn ? Color(red: 0.25, green: 0.84, blue: 0.47) : Palette.surface3)
                Circle().fill(.white).padding(2)
            }
            .frame(width: 38, height: 22)
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: configuration.isOn)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}
