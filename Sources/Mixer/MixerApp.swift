import AppKit
import ServiceManagement
import SwiftUI

@main
struct MixerMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var devices: DeviceModel
    @StateObject private var mixer: MixerModel

    init() {
        let devices = DeviceModel()
        let mixer = MixerModel(devices: devices)
        _devices = StateObject(wrappedValue: devices)
        _mixer = StateObject(wrappedValue: mixer)
        AppDelegate.mixer = mixer
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environmentObject(mixer)
                .environmentObject(devices)
        } label: {
            Image(nsImage: MenuBarIcon.image)
                .accessibilityLabel("Mixer")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static weak var mixer: MixerModel?

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Self.mixer?.tearDownAll() }
    }
}

enum MenuBarIcon {
    /// A speaker next to three mixer sliders, drawn as a template so it follows the menu bar's color.
    static let image: NSImage = {
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        guard let speaker = NSImage(systemSymbolName: "speaker.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(config),
              let sliders = NSImage(systemSymbolName: "slider.vertical.3", accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
        else { return NSImage() }

        let gap: CGFloat = 1.5
        let height = max(speaker.size.height, sliders.size.height)
        let size = NSSize(width: speaker.size.width + gap + sliders.size.width, height: height)
        let image = NSImage(size: size, flipped: false) { _ in
            speaker.draw(in: NSRect(origin: NSPoint(x: 0, y: (height - speaker.size.height) / 2), size: speaker.size))
            sliders.draw(in: NSRect(
                origin: NSPoint(x: speaker.size.width + gap, y: (height - sliders.size.height) / 2),
                size: sliders.size))
            return true
        }
        image.isTemplate = true
        return image
    }()
}

@MainActor
final class LoginItem: ObservableObject {
    @Published private(set) var isEnabled = SMAppService.mainApp.status == .enabled
    @Published private(set) var error: String?

    func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            error = nil
        } catch {
            self.error = "Couldn't change the login setting. Move Mixer to the Applications folder and try again."
        }
        isEnabled = SMAppService.mainApp.status == .enabled
    }
}
