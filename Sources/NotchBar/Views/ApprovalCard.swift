import SwiftUI

struct ApprovalCard: View {
    let approval: Approval
    let session: Session?
    let position: Int
    let total: Int
    var trustMinutes: Int = 20
    /// Pending non-risky requests from this same session (including this one).
    var batchCount: Int = 1
    let decide: (SessionStore.Decision) -> Void
    var allowAll: () -> Void = {}

    private var agent: Agent { session?.agent ?? .claude }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            titleRow
            PreviewBox(preview: approval.preview)
            if approval.offerAlways, let c = approval.candidate { alwaysRow(c) }
            if showAssist { assistRow }
            buttons
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Palette.surface2))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(approval.risky ? Color.danger.opacity(0.55) : Palette.hairline, lineWidth: 1)
        )
    }

    // MARK: parts

    private var titleRow: some View {
        HStack(spacing: 11) {
            AgentTile(agent: agent, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.text2)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if approval.risky {
                Label("Destructive", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.danger)
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(Color.danger.opacity(0.14)))
            }
            if total > 1 {
                Text("\(position) of \(total)")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Palette.text2)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(Palette.surface3))
            }
        }
    }

    /// "You keep approving this — always allow it here?"
    private func alwaysRow(_ c: AllowCandidate) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 14))
                .foregroundStyle(Color.success)
            VStack(alignment: .leading, spacing: 1) {
                Text("Allowed \(approval.timesAllowed)× before")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Text(c.agent == .claude ? "Saves a Claude permission rule for \((c.project as NSString).lastPathComponent)"
                                        : "NotchBar will answer it for you in \((c.project as NSString).lastPathComponent)")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.text3)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button { decide(.always) } label: {
                HStack(spacing: 6) {
                    Text("Always allow ")
                        + Text(c.tool == "WebFetch" ? c.pattern : c.pattern).font(.system(size: 12, weight: .semibold, design: .monospaced))
                    Text("⌃⌥A").font(.system(size: 10.5, weight: .medium)).opacity(0.5)
                }
                .lineLimit(1)
            }
            .buttonStyle(NBButtonStyle(kind: .secondary, compact: true))
            .help("Allow now and stop asking for this in this project")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.success.opacity(0.08)))
    }

    private var canTrust: Bool { approval.trustable && !approval.risky && approval.project != nil }
    private var showAssist: Bool { canTrust || batchCount > 1 }

    /// Speed-ups: trust this project for a while, or clear a backlog at once.
    private var assistRow: some View {
        HStack(spacing: 8) {
            if canTrust, let p = approval.project {
                Button { decide(.trust(minutes: trustMinutes)) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.shield")
                        Text("Trust \((p as NSString).lastPathComponent) for \(trustMinutes)m")
                        Text("⌃⌥T").font(.system(size: 10.5, weight: .medium)).opacity(0.5)
                    }
                    .lineLimit(1)
                }
                .buttonStyle(NBButtonStyle(kind: .secondary, compact: true))
                .help("Allow this, and auto-allow safe commands and in-project edits here for \(trustMinutes) minutes. Destructive commands still ask.")
            }
            if batchCount > 1 {
                Button(action: allowAll) {
                    Text("Allow all \(batchCount)").lineLimit(1)
                }
                .buttonStyle(NBButtonStyle(kind: .secondary, compact: true))
                .help("Allow every pending safe request from this agent")
            }
            Spacer(minLength: 0)
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Button { decide(.terminal) } label: {
                HStack(spacing: 6) {
                    Text(agent.handBackLabel)
                    Text("esc").foregroundStyle(Palette.text3)
                }
            }
            .buttonStyle(NBButtonStyle(kind: .plain))
            .keyboardShortcut(.cancelAction)
            .help("Answer this one in \(agent == .cursor ? "Cursor" : "the terminal") instead")

            Spacer()

            Button { decide(.deny) } label: {
                HStack(spacing: 7) {
                    Text("Deny")
                    Text("⌃⌥N").font(.system(size: 10.5, weight: .medium)).opacity(0.5)
                }
            }
            .buttonStyle(NBButtonStyle(kind: .secondary))
            .keyboardShortcut(.delete, modifiers: .command)

            Button { decide(.allow) } label: {
                HStack(spacing: 7) {
                    Text(approval.risky ? "Allow anyway" : "Allow")
                    Text("⌃⌥Y").font(.system(size: 10.5, weight: .medium)).opacity(0.5)
                }
            }
            .buttonStyle(NBButtonStyle(kind: approval.risky ? .danger : .primary))
            .keyboardShortcut(.return, modifiers: .command)
        }
    }

    private var title: String {
        switch approval.toolName {
        case "Bash": return "Run this command?"
        case "Edit", "MultiEdit", "apply_patch": return "Apply this edit?"
        case "Write": return "Create this file?"
        case "WebFetch": return "Fetch this page?"
        case "WebSearch": return "Search the web?"
        default: return "Allow \(ToolInfo.displayName(approval.toolName))?"
        }
    }

    private var subtitle: String {
        var parts = [agent.shortName]
        if let s = session {
            parts.append(s.projectName)
            if let b = s.branch { parts.append(b) }
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Preview

struct PreviewBox: View {
    let preview: ApprovalPreview

    private let lineHeight: CGFloat = 17
    private let maxHeight: CGFloat = 180

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch preview {
            case let .command(cmd, description):
                if let description, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.text2)
                        .lineLimit(2)
                }
                CodeBox(estimate: CGFloat(cmd.components(separatedBy: "\n").count) * lineHeight + 20,
                        maxHeight: maxHeight, header: nil) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("$").foregroundStyle(Palette.text3)
                        Text(ToolInfo.highlightBash(cmd))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 12, design: .monospaced))
                }

            case let .diff(path, removed, added):
                let shownRemoved = Array(removed.prefix(12))
                let shownAdded = Array(added.prefix(16))
                let hidden = (removed.count - shownRemoved.count) + (added.count - shownAdded.count)
                CodeBox(estimate: CGFloat(shownRemoved.count + shownAdded.count + 1) * lineHeight + 20,
                        maxHeight: maxHeight,
                        header: AnyView(fileHeader(path, removed: removed.count, added: added.count))) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(shownRemoved.enumerated()), id: \.offset) { _, l in
                            DiffLine(sign: "−", text: l, color: .danger)
                        }
                        ForEach(Array(shownAdded.enumerated()), id: \.offset) { _, l in
                            DiffLine(sign: "+", text: l, color: .success)
                        }
                        if hidden > 0 {
                            Text("\(hidden) more lines")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Palette.text3)
                                .padding(.top, 4).padding(.leading, 22)
                        }
                    }
                }

            case let .text(title, body):
                if let title, !title.isEmpty {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1).truncationMode(.middle)
                }
                if !body.isEmpty {
                    CodeBox(estimate: CGFloat(body.components(separatedBy: "\n").count) * lineHeight + 20,
                            maxHeight: maxHeight, header: nil) {
                        Text(body)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.85))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func fileHeader(_ path: String, removed: Int, added: Int) -> some View {
        HStack(spacing: 6) {
            Text((path as NSString).lastPathComponent).fontWeight(.semibold).foregroundStyle(.white)
            Text(shortDir(path)).foregroundStyle(Palette.text3).lineLimit(1).truncationMode(.head)
            Spacer(minLength: 6)
            if added > 0 { Text("+\(added)").foregroundStyle(Color.success) }
            if removed > 0 { Text("−\(removed)").foregroundStyle(Color.danger) }
        }
        .font(.system(size: 11.5, weight: .medium))
        .monospacedDigit()
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func shortDir(_ path: String) -> String {
        let dir = (path as NSString).deletingLastPathComponent
        return (dir as NSString).abbreviatingWithTildeInPath
    }
}

/// Code area sized to its real content height; scrolls only past maxHeight.
struct CodeBox<C: View>: View {
    let estimate: CGFloat
    let maxHeight: CGFloat
    let header: AnyView?
    @ViewBuilder let content: () -> C
    @State private var measured: CGFloat?

    var body: some View {
        VStack(spacing: 0) {
            if let header {
                header
                Rectangle().fill(Palette.hairline).frame(height: 1)
            }
            ScrollView(.vertical) {
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { measured = $0 }
            }
            .scrollIndicators(.automatic)
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(measured ?? estimate, maxHeight))
        }
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Palette.code))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

struct DiffLine: View {
    let sign: String
    let text: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(sign).foregroundStyle(color).frame(width: 10).padding(.leading, 6)
            Text(text.isEmpty ? " " : text)
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.system(size: 11.5, design: .monospaced))
        .frame(maxWidth: .infinity, minHeight: 17, alignment: .leading)
        .background(color.opacity(0.12))
    }
}

// MARK: - Buttons (solid fills only)

struct NBButtonStyle: ButtonStyle {
    enum Kind { case primary, danger, secondary, plain }
    let kind: Kind
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        NBStyleBody(configuration: configuration, kind: kind, compact: compact)
    }

    private struct NBStyleBody: View {
        let configuration: ButtonStyleConfiguration
        let kind: Kind
        let compact: Bool
        @State private var hover = false

        var body: some View {
            configuration.label
                .font(.system(size: compact ? 11.5 : 13, weight: .semibold))
                .foregroundStyle(foreground)
                .padding(.horizontal, kind == .plain ? 8 : (compact ? 11 : 16))
                .frame(height: compact ? 24 : 34)
                .background(Capsule().fill(background))
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.12), value: hover)
                .onHover { hover = $0 }
        }

        private var foreground: Color {
            switch kind {
            case .primary: return .black
            case .danger: return .white
            case .secondary: return .white
            case .plain: return hover ? .white : Palette.text2
            }
        }

        private var background: Color {
            switch kind {
            case .primary: return hover ? Color(white: 0.88) : .white
            case .danger: return hover ? Color.danger.opacity(0.85) : .danger
            case .secondary: return hover ? Color(white: 0.24) : Palette.surface3
            case .plain: return .clear
            }
        }
    }
}

struct CircleIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        NBStyleBody(configuration: configuration)
    }

    private struct NBStyleBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hover = false
        var body: some View {
            configuration.label
                .foregroundStyle(hover ? .white : Palette.text2)
                .background(Circle().fill(hover ? Color(white: 0.22) : Palette.surface3))
                .scaleEffect(configuration.isPressed ? 0.9 : 1)
                .animation(.easeOut(duration: 0.12), value: hover)
                .onHover { hover = $0 }
        }
    }
}
