import SwiftUI

@main
struct WalkingPadApp: App {
    @StateObject private var controller = PadController()
    var body: some Scene {
        WindowGroup {
            ContentView(pad: controller)
                .frame(minWidth: 560, idealWidth: 620, maxWidth: 760, minHeight: 620)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 620, height: 690)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

struct ContentView: View {
    @ObservedObject var pad: PadController
    @State private var showDiagnostics = false
    @State private var showAll = false
    private let accent = Color(red: 0.68, green: 0.94, blue: 0.42)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                connection
                if pad.connected { beltButton; dashboard }
                else { discovery }
                footer
            }
            .padding(28)
        }
        .background(Color(red: 0.065, green: 0.083, blue: 0.081))
        .tint(accent)
        .background(ControlKeyboardShortcuts(enabled: !showDiagnostics, toggle: pad.toggleBelt, adjust: pad.adjustSpeed))
        .sheet(isPresented: $showDiagnostics) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Connection diagnostics").font(.title2.bold())
                    Spacer()
                    Button("Done") { showDiagnostics = false }
                }
                Text("Service discovery, capabilities and command acknowledgements. Data stays on this Mac. Device identifiers are included when you copy.")
                    .font(.callout).foregroundStyle(.secondary)
                ScrollView {
                    Text(pad.diagnostics.isEmpty ? "No Bluetooth activity yet." : pad.diagnostics.joined(separator: "\n"))
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                Button("Copy diagnostics", systemImage: "doc.on.doc") { pad.copyDiagnostics() }
            }
            .padding(24).frame(width: 650, height: 500)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "figure.walk").font(.title2).foregroundStyle(accent)
            Text("WalkingPad").font(.system(size: 22, weight: .semibold, design: .rounded))
        }
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle().fill(pad.connected ? accent : Color.gray).frame(width: 7, height: 7)
                Text(pad.status).font(.system(size: 13, weight: .semibold))
                Spacer()
                if pad.connecting { ProgressView().controlSize(.small) }
                if pad.connected || pad.connecting {
                    Button(pad.connecting ? "Cancel" : "Disconnect") { pad.disconnect() }.buttonStyle(.borderless).font(.caption)
                }
            }
            Text(pad.notice).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if pad.connected && !pad.ownsControl {
                Button("Enable controls") { pad.enableControls() }.disabled(!pad.controlsAvailable || pad.busy)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
    }

    private var discovery: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("SpaceWalk E1L").font(.title3.weight(.semibold))
                    Text("UREVO").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(pad.scanning ? "Stop scan" : "Find my pad") { pad.scanning ? pad.stopScan() : pad.scan() }
                    .buttonStyle(.borderedProminent).disabled(pad.connecting)
            }
            if pad.scanning { ProgressView().controlSize(.small) }
            let visible = pad.devices.filter { showAll || $0.likelyPad }
            ForEach(visible) { device in
                HStack {
                    Image(systemName: device.likelyPad ? "figure.walk" : "antenna.radiowaves.left.and.right").foregroundStyle(accent).frame(width: 26)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(device.name).fontWeight(.medium)
                        Text("\(device.signal) dBm · \(device.id.uuidString.prefix(8))").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Connect") { pad.connect(device) }.disabled(pad.connecting)
                }.padding(12).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            }
            if !pad.devices.isEmpty {
                Toggle("Show all nearby devices (\(pad.devices.count))", isOn: $showAll).toggleStyle(.checkbox).font(.caption)
            }
            if visible.isEmpty && !pad.scanning {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Turn on the walking pad", systemImage: "power")
                    Label("Close Urevo and other treadmill apps", systemImage: "iphone.slash")
                    Label("Find your pad, then enable its controls", systemImage: "antenna.radiowaves.left.and.right")
                }.font(.callout).foregroundStyle(.secondary).padding(.vertical, 22)
            }
        }.padding(20).background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 20))
    }

    private var dashboard: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(pad.deviceName).font(.callout.weight(.medium)).foregroundStyle(.secondary)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let stale = pad.lastSample.map { context.date.timeIntervalSince($0) > 5 } ?? true
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(pad.speed.map { pad.displaySpeed($0) } ?? "—")
                        .font(.system(size: 76, weight: .light, design: .rounded)).monospacedDigit()
                        .foregroundStyle(stale ? Color.secondary : accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("mph").font(.title3).foregroundStyle(.secondary)
                        Text(stale ? "Awaiting live speed" : "Live belt speed").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            speedControls
            Divider().overlay(.white.opacity(0.06))
            HStack(spacing: 0) {
                metric("Distance", pad.distance.map { String(format: "%.2f mi", Double($0) / 1609.344) } ?? "—")
                metric("Pad timer", pad.elapsed.map { String(format: "%02d:%02d", $0 / 60, $0 % 60) } ?? "—")
                metric("Calories", pad.calories.map { "\($0) kcal" } ?? "—")
            }
            Text("Reported by the pad. Missing measurements appear as —.").font(.caption2).foregroundStyle(.tertiary)
        }.padding(22).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 22))
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 18, weight: .medium, design: .rounded)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var speedControls: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Target speed").font(.caption).foregroundStyle(.secondary)
                        Text("\(pad.targetLabel) mph").font(.title2.monospacedDigit())
                    }
                    Spacer()
                    Button { pad.adjustSpeed(-1) } label: { Image(systemName: "minus") }
                        .buttonStyle(SpeedStepButtonStyle())
                        .accessibilityLabel("Decrease speed")
                        .disabled(!pad.canAdjustSpeed(at: context.date) || (pad.targetSpeed ?? 0) <= (pad.range?.minimum ?? 0))
                    Button { pad.adjustSpeed(1) } label: { Image(systemName: "plus") }
                        .buttonStyle(SpeedStepButtonStyle())
                        .accessibilityLabel("Increase speed")
                        .disabled(!pad.canAdjustSpeed(at: context.date) || (pad.targetSpeed ?? 0) >= (pad.range?.lastStep ?? 0))
                }
                Text("\(pad.rangeLabel) · ← / → changes speed").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var beltButton: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let start = pad.offersStart(at: context.date)
            let enabled = pad.ownsControl && pad.controlsAvailable && (!start || !pad.busy)
            Button { pad.toggleBelt() } label: {
                HStack(spacing: 12) {
                    Image(systemName: start ? "play.fill" : "stop.fill")
                    Text(start ? "Start" : (pad.session.stopQueued ? "Stop queued" : "Stop"))
                    Text("SPACE").font(.system(size: 10, weight: .semibold)).tracking(1)
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(.black.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
                }
                .font(.system(size: 19, weight: .semibold))
                .frame(maxWidth: .infinity).frame(height: 64)
                .foregroundStyle(start ? Color(red: 0.08, green: 0.15, blue: 0.08) : accent)
                .background(start ? accent : Color(red: 0.18, green: 0.29, blue: 0.20), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(accent.opacity(start ? 0 : 0.4)))
                .contentShape(RoundedRectangle(cornerRadius: 16))
                .opacity(enabled ? 1 : 0.45)
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Keep the physical remote within reach. Bluetooth Stop is not an emergency stop. Closing or disconnecting this app does not stop the belt.", systemImage: "hand.raised")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Local Bluetooth · No account needed").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Diagnostics") { showDiagnostics = true }.buttonStyle(.borderless).font(.caption)
            }
        }
    }
}

private struct SpeedStepButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false
    private let accent = Color(red: 0.68, green: 0.94, blue: 0.42)

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(accent)
            .frame(width: 48, height: 48)
            .background(accent.opacity(configuration.isPressed ? 0.24 : (hovering && isEnabled ? 0.16 : 0.09)),
                        in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(accent.opacity(hovering && isEnabled ? 0.55 : 0.28)))
            .contentShape(RoundedRectangle(cornerRadius: 13))
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .opacity(isEnabled ? 1 : 0.3)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
    }
}

/// A local monitor handles keys only in this control window. Returning nil
/// consumes Space so AppKit cannot also activate a focused button.
private struct ControlKeyboardShortcuts: NSViewRepresentable {
    var enabled: Bool
    let toggle: () -> Void
    let adjust: (Int) -> Void

    func makeNSView(context: Context) -> ShortcutView { ShortcutView() }
    func updateNSView(_ view: ShortcutView, context: Context) {
        view.enabled = enabled
        view.toggle = toggle
        view.adjust = adjust
    }
    static func dismantleNSView(_ view: ShortcutView, coordinator: ()) { view.removeMonitor() }

    final class ShortcutView: NSView {
        var enabled = false
        var toggle: (() -> Void)?
        var adjust: ((Int) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.enabled, let window = self.window,
                      window.isKeyWindow, event.window === window, window.attachedSheet == nil,
                      !(window.firstResponder is NSTextView),
                      event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return event }
                switch event.keyCode {
                case 49:
                    if !event.isARepeat { self.toggle?() }
                case 123: self.adjust?(-1)
                case 124: self.adjust?(1)
                default: return event
                }
                return nil
            }
        }
        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
        deinit { removeMonitor() }
    }
}
