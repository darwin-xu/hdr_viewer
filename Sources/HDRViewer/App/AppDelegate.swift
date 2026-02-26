import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Logger.shared.info("Application launched", source: "App")

        NSApp.setActivationPolicy(.regular)

        if let icon = NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: "HDR Viewer") {
            NSApp.applicationIconImage = icon
        }

        NSApp.activate(ignoringOtherApps: true)
    }
}
