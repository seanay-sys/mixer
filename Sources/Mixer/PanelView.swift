import SwiftUI

struct PanelView: View {
    @EnvironmentObject private var mixer: MixerModel
    @EnvironmentObject private var devices: DeviceModel
    @StateObject private var loginItem = LoginItem()

    private let rowHeight: CGFloat = 54

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)

            MasterRow()
                .padding(.horizontal, 14)
                .padding(.bottom, 12)

            Divider()

            if let problem = mixer.problem {
                ProblemBanner(text: problem)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(mixer.apps) { app in
                        AppRow(app: app)
                            .frame(height: rowHeight)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 6)
            }
            .frame(height: min(CGFloat(max(mixer.apps.count, 1)) * rowHeight + 12, 470))

            Divider()

            footer
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
        }
        .frame(width: 360)
        .onAppear { mixer.panelDidOpen(); devices.reloadDevices() }
        .onDisappear { mixer.panelDidClose() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Mixer")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Menu {
                ForEach(devices.devices) { device in
                    Button {
                        devices.setDefaultDevice(device)
                    } label: {
                        if device.uid == devices.defaultUID {
                            Label(device.name, systemImage: "checkmark")
                        } else {
                            Text(device.name)
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: devices.defaultDevice?.symbol ?? "speaker.slash")
                    Text(devices.defaultDevice?.name ?? "No Output")
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Output device")
        }
    }

    private var footer: some View {
        HStack {
            Toggle("Open at login", isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.set($0) }))
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .help(loginItem.error ?? "Start Mixer automatically when you log in")
            Spacer()
            Button("Audio Permission…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.link)
            .font(.system(size: 11))
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.link)
                .font(.system(size: 11))
                .keyboardShortcut("q")
        }
    }
}

// MARK: - Master volume

private struct MasterRow: View {
    @EnvironmentObject private var devices: DeviceModel

    var body: some View {
        HStack(spacing: 10) {
            Button {
                devices.setMuted(!devices.isMuted)
            } label: {
                Image(systemName: speakerSymbol)
                    .font(.system(size: 13))
                    .frame(width: 22, height: 18)
                    .foregroundStyle(devices.isMuted ? Color.red : Color.primary)
            }
            .buttonStyle(.plain)
            .disabled(!devices.canMute)
            .help(devices.isMuted ? "Unmute" : "Mute")

            VolumeSlider(
                value: Binding(get: { Double(devices.volume) }, set: { devices.setVolume(Float($0)) }),
                range: 0...1,
                notch: nil,
                dimmed: devices.isMuted
            )
            .disabled(!devices.canSetVolume)

            Text(devices.isMuted ? "Muted" : "\(Int((devices.volume * 100).rounded()))%")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
    }

    private var speakerSymbol: String {
        if devices.isMuted || devices.volume == 0 { return "speaker.slash.fill" }
        if devices.volume < 0.34 { return "speaker.wave.1.fill" }
        if devices.volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}

// MARK: - Per-app row

private struct AppRow: View {
    let app: MixerApp
    @EnvironmentObject private var mixer: MixerModel
    @EnvironmentObject private var devices: DeviceModel
    @StateObject private var hover = HoverState()

    var body: some View {
        let setting = mixer.setting(for: app.id)
        let routed = devices.device(uid: setting.deviceUID)

        HStack(spacing: 10) {
            Image(nsImage: app.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(app.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    if app.isPlaying {
                        Image(systemName: "waveform")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.green)
                            .symbolEffect(.variableColor.iterative, options: .repeating)
                            .help("Playing audio")
                    }
                    if let routed {
                        Image(systemName: routed.symbol)
                            .font(.system(size: 9))
                            .foregroundStyle(Color.accentColor)
                            .help("Playing through \(routed.name)")
                    }
                    Spacer(minLength: 4)
                    Text(label(for: setting))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(setting.volume > 1.001 && !setting.muted ? Color.orange : Color.secondary)
                }

                HStack(spacing: 6) {
                    Button {
                        mixer.toggleMute(app.id)
                    } label: {
                        Image(systemName: setting.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 10))
                            .frame(width: 16, height: 14)
                            .foregroundStyle(setting.muted ? Color.red : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(setting.muted ? "Unmute \(app.name)" : "Mute \(app.name)")

                    VolumeSlider(
                        value: Binding(get: { setting.volume }, set: { mixer.setVolume($0, for: app.id) }),
                        range: 0...MixerModel.maxVolume,
                        notch: 1,
                        dimmed: setting.muted
                    )

                    optionsMenu(setting: setting)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hover.isHovering ? Color.primary.opacity(0.06) : Color.clear)
        )
        .opacity(app.hasAudio ? 1 : 0.62)
        .help(app.hasAudio ? "" : "\(app.name) hasn't opened audio yet. Your setting applies as soon as it does.")
        .onHover { hover.isHovering = $0 }
        .contextMenu {
            Button("Reset to 100%") { mixer.reset(app.id) }
        }
    }

    private func label(for setting: AppSetting) -> String {
        setting.muted ? "Muted" : "\(Int((setting.volume * 100).rounded()))%"
    }

    private func optionsMenu(setting: AppSetting) -> some View {
        Menu {
            Picker("Play Through", selection: Binding(
                get: { setting.deviceUID ?? "" },
                set: { mixer.setDevice($0.isEmpty ? nil : $0, for: app.id) }
            )) {
                Text("System Output").tag("")
                ForEach(devices.devices) { device in
                    Text(device.name).tag(device.uid)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Reset to 100%") { mixer.reset(app.id) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Output and options")
    }
}

// MARK: - Components

private final class HoverState: ObservableObject {
    @Published var isHovering = false
}

private struct ProblemBanner: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    }
}

/// A slim slider with a 100% notch; the part above the notch is drawn in orange to show boost.
struct VolumeSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var notch: Double?
    var dimmed = false

    @Environment(\.isEnabled) private var isEnabled
    private let knob: CGFloat = 14
    private let track: CGFloat = 4

    var body: some View {
        GeometryReader { geometry in
            let usable = max(geometry.size.width - knob, 1)
            let position = knob / 2 + usable * fraction(value)
            let notchPosition = notch.map { knob / 2 + usable * fraction($0) }
            let normalEnd = min(position, notchPosition ?? position)
            let fillColor = dimmed ? Color.secondary.opacity(0.5) : Color.accentColor

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.13))
                    .frame(width: usable, height: track)
                    .offset(x: knob / 2)

                Capsule()
                    .fill(fillColor)
                    .frame(width: max(normalEnd - knob / 2, 0), height: track)
                    .offset(x: knob / 2)

                if let notchPosition, position > notchPosition {
                    Capsule()
                        .fill(dimmed ? Color.secondary.opacity(0.5) : Color.orange)
                        .frame(width: position - notchPosition, height: track)
                        .offset(x: notchPosition)
                }

                if let notchPosition {
                    Capsule()
                        .fill(Color.primary.opacity(0.35))
                        .frame(width: 2, height: 10)
                        .offset(x: notchPosition - 1)
                }

                Circle()
                    .fill(Color.white)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.15), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                    .frame(width: knob, height: knob)
                    .offset(x: position - knob / 2)
            }
            .frame(height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let f = min(max((drag.location.x - knob / 2) / usable, 0), 1)
                        var newValue = range.lowerBound + Double(f) * span
                        if let notch, abs(newValue - notch) < span * 0.025 { newValue = notch }
                        value = newValue
                    }
            )
        }
        .frame(height: 16)
        .opacity(isEnabled ? 1 : 0.4)
    }

    private var span: Double { range.upperBound - range.lowerBound }

    private func fraction(_ v: Double) -> CGFloat {
        CGFloat(min(max((v - range.lowerBound) / span, 0), 1))
    }
}

