import SwiftUI
import CoreImage
import AppKit
import RemoteServer

/// The menu-bar panel.
///
/// The design goal is that a person who has never seen this can go from "downloaded" to
/// "controlling YouTube" without a terminal: what to do next is always the most prominent
/// thing on screen, and the panic control is always reachable.
struct MenuView: View {
    @ObservedObject var model: AppModel
    @State private var showTroubleshooting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if !model.hasAccessibility {
                permissionPrompt
            } else if case .failed(let message) = model.status {
                failure(message)
            } else if model.status.isRunning {
                running
            } else {
                Button("Start AirPoint") { model.start() }
                    .buttonStyle(.borderedProminent)
            }

            Divider()
            troubleshooting
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 320)
        .sheet(item: $model.pendingRequest) { request in
            PairingSheet(request: request, model: model)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
            Text(statusText)
                .font(.system(size: 13, weight: .medium))
            Spacer()
        }
    }

    private var statusColor: Color {
        switch model.status {
        case .connected: return .green
        case .listening: return model.hasAccessibility ? .blue : .orange
        case .starting: return .yellow
        case .failed: return .red
        case .stopped: return .secondary
        }
    }

    private var statusText: String {
        switch model.status {
        case .stopped: return "Not running"
        case .starting: return "Starting…"
        case .listening: return "Waiting for a phone"
        case .connected(let name): return "Connected — \(name)"
        case .failed: return "Could not start"
        }
    }

    // Accessibility is the one thing that silently breaks everything, so it takes over the
    // panel entirely rather than sitting in a corner as a warning.
    private var permissionPrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AirPoint needs Accessibility permission")
                .font(.system(size: 13, weight: .semibold))
            Text("It moves the cursor and types by posting input events, which macOS "
                 + "requires permission for. Nothing else is requested.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack {
                Button("Grant…") { model.requestAccessibility() }
                    .buttonStyle(.borderedProminent)
                Button("Open Settings") {
                    NSWorkspace.shared.open(URL(string:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
            }
            Text("The switch takes effect immediately — no relaunch needed.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try again") { model.start() }
        }
    }

    private var running: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let image = QRImage.make(from: model.pairingURL) {
                HStack {
                    Spacer()
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 168, height: 168)
                        .background(Color.white)
                        .cornerRadius(6)
                    Spacer()
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Scan on your phone, or open")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                ForEach(model.addresses.prefix(2), id: \.self) { address in
                    Text("https://\(address):8443")
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

            HStack {
                Text(model.pairingCode)
                    .font(.system(size: 24, weight: .semibold, design: .monospaced))
                    .kerning(3)
                    .textSelection(.enabled)
                Spacer()
                Text(model.codeSecondsRemaining > 0 ? "\(model.codeSecondsRemaining)s" : "expired")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(model.codeSecondsRemaining > 30 ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                Button("New") { model.newPairingCode() }
                    .controlSize(.small)
            }

            // Always present while running, never behind a submenu: if you want this, you
            // want it now.
            Button(role: .destructive) {
                model.panic()
            } label: {
                Label("Disconnect everything", systemImage: "bolt.slash.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)

            // The shortcut is global, and this is the one place a person looks when they
            // care about disconnecting — so it is taught here, not in a preferences pane.
            Text("Works from anywhere as \(PanicHotKey.displayString) while AirPoint is running.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            if !model.trustedDevices.isEmpty {
                Divider()
                Text("Remembered devices")
                    .font(.system(size: 11, weight: .semibold))
                ForEach(model.trustedDevices, id: \.deviceId) { device in
                    HStack {
                        Text(device.deviceName).font(.system(size: 11))
                        Spacer()
                        Button("Forget") { model.revoke(device) }
                            .controlSize(.small)
                    }
                }
                Button("Forget all") { model.revokeAll() }
                    .controlSize(.small)
            }
        }
    }

    // The two things a stuck user cannot see from here: a firewall silently eating the
    // connection, and warnings that went to a stderr no window shows. Collapsed by
    // default because on a healthy day it is noise.
    private var troubleshooting: some View {
        DisclosureGroup(isExpanded: $showTroubleshooting) {
            VStack(alignment: .leading, spacing: 6) {
                firewallRow
                issueList
            }
            .padding(.top, 6)
        } label: {
            Text("Troubleshooting")
                .font(.system(size: 11, weight: .semibold))
        }
        .onChange(of: showTroubleshooting) { expanded in
            // Probed on open rather than polled: the firewall changes when a human flips
            // it in System Settings, and this is the moment the answer is wanted.
            if expanded { model.refreshFirewall() }
        }
    }

    private var firewallRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(firewallText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if firewallNeedsAttention {
                Button("Open Firewall Settings") {
                    NSWorkspace.shared.open(URL(string:
                        "x-apple.systempreferences:com.apple.preference.security?Firewall")!)
                }
                .controlSize(.small)
            }
        }
    }

    private var firewallNeedsAttention: Bool {
        model.firewall == .on || model.firewall == .blockingAll
    }

    private var firewallText: String {
        switch model.firewall {
        case .off:
            return "Firewall: off — not blocking AirPoint."
        case .on:
            return "Firewall: on. If a phone cannot connect, allow AirPointApp "
                 + "under the firewall's options."
        case .blockingAll:
            return "Firewall: blocking all incoming connections. No phone can connect "
                 + "until this is relaxed."
        case .unknown:
            return "Firewall: state could not be read."
        }
    }

    private var issueList: some View {
        VStack(alignment: .leading, spacing: 3) {
            if model.recentIssues.isEmpty {
                Text("No recent warnings.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(model.recentIssues.prefix(5).enumerated()),
                        id: \.offset) { _, issue in
                    Text("\(Self.timeFormatter.string(from: issue.date))  \(issue.message)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(issue.level == .error ? AnyShapeStyle(Color.red)
                                                               : AnyShapeStyle(.secondary))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private var footer: some View {
        HStack {
            if model.status.isRunning {
                Button("Stop") { model.stop() }.controlSize(.small)
            }
            Spacer()
            Button("Quit") {
                model.stop()
                NSApplication.shared.terminate(nil)
            }
            .controlSize(.small)
        }
    }
}

/// The approval sheet. Every first-time device passes through here.
struct PairingSheet: View {
    let request: AppModel.PairingRequest
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(request.deviceName) wants to control this Mac")
                .font(.system(size: 14, weight: .semibold))
            Text("From \(request.peer). It will be able to move the cursor, click, "
                 + "scroll and type until you disconnect it.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Deny") { model.decide(.deny) }
                Spacer()
                Button("Allow once") { model.decide(.approve) }
                Button("Allow and remember") { model.decide(.approveAndTrust) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 380)
    }
}

/// Wraps the library's QR renderer for AppKit. One implementation, shared with every other
/// host — the game puts the same code on a television.
enum QRImage {
    static func make(from text: String) -> NSImage? {
        guard !text.isEmpty, let image = QRCode.cgImage(for: text) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
