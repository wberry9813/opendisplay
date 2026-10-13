import SwiftUI
import Sparkle

enum EngineLaunch {
    static let managed = CommandLine.arguments.contains("--engine")
}

/// Standalone presentation policy adapts the same discovery/session controller.
@MainActor
final class SenderController: DirectEngineController {
    static let shared = SenderController(managed: EngineLaunch.managed)
    @Published var presentation = AppPresentation(
        rawValue: UserDefaults.standard.string(forKey: "presentation") ?? "") ?? .menuBar {
        didSet {
            guard !managed else { return }
            UserDefaults.standard.set(presentation.rawValue, forKey: "presentation")
            NSApp.setActivationPolicy(presentation == .dock ? .regular : .accessory)
            if presentation != .menuBar { MainWindow.show() }
        }
    }
}

@main
struct OpenSidecarMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = SenderController.shared
    var body: some Scene {
        MenuBarExtra(isInserted: Binding(
            get: { !EngineLaunch.managed && controller.presentation == .menuBar },
            set: { _ in }
        )) {
            ContentView(controller: controller, updater: appDelegate.updater)
        } label: {
            Image(systemName: controller.running
                  ? "rectangle.on.rectangle.fill" : "rectangle.on.rectangle")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let updater = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    private var controlServer: LocalControlServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if EngineLaunch.managed {
            NSApp.setActivationPolicy(.prohibited)
            do {
                let server = LocalControlServer(controller: SenderController.shared)
                try server.start()
                controlServer = server
            } catch {
                Log.info("engine control startup failed: \(error)")
                NSApp.terminate(nil)
            }
            return
        }
        MainWindow.updater = updater
        let presentation = SenderController.shared.presentation
        NSApp.setActivationPolicy(presentation == .dock ? .regular : .accessory)
        if presentation != .menuBar { MainWindow.show() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        if !EngineLaunch.managed { MainWindow.show() }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        controlServer?.stop()
        SenderController.shared.disconnectAll()
    }
}

@MainActor
enum MainWindow {
    private static var window: NSWindow?
    static var updater: SPUStandardUpdaterController?
    static func show() {
        guard !EngineLaunch.managed else { return }
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 540),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered, defer: false)
            w.title = "SideLinker Direct"
            w.contentView = NSHostingView(rootView: ContentView(
                controller: SenderController.shared, updater: updater))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
