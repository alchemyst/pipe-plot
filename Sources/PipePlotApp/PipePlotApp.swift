import SwiftUI
import AppKit
import PipePlotCore

@main
enum PipePlotAppEntry {
    static func main() {
        AcceptanceTrace.record("process-start")
        // Hosted XCTest needs the app's run loop, but must not open the user's
        // database, start IPC, or restore windows. Set only by the test action.
        if ProcessInfo.processInfo.environment["PIPEPLOT_TEST_HOST"] == "1" {
            NSApplication.shared.run()
        } else {
            PipePlotApplication.main()
        }
    }
}

struct PipePlotApplication: App {
    @NSApplicationDelegateAdaptor(PipePlotAppDelegate.self) private var appDelegate
    @State private var model = PipePlotAppModel()

    var body: some Scene {
        // A data-driven WindowGroup has no initial value on cold launch. Use an
        // ordinary initial scene to mount the opener before routing to session IDs.
        WindowGroup("PipePlot", id: "initial") {
            SessionScene(model: model, appDelegate: appDelegate)
        }
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.presented)
        .commands { PipePlotCommands(model: model, installInitialWindowOpener: { appDelegate.installInitialWindowOpener($0) }) }

        WindowGroup("PipePlot", for: SessionID.self) { $sessionID in
            SessionScene(model: model, appDelegate: appDelegate, initialSessionID: sessionID)
        }
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)

        WindowGroup("Saved Sessions", id: "sessions") {
            SavedSessionScene(model: model)
        }
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)
        Settings { SettingsView(model: model) }
    }
}

private struct SessionScene: View {
    let model: PipePlotAppModel
    let appDelegate: PipePlotAppDelegate
    @State private var sessionID: SessionID?
    @Environment(\.openWindow) private var openWindow

    init(model: PipePlotAppModel, appDelegate: PipePlotAppDelegate, initialSessionID: SessionID? = nil) {
        self.model = model; self.appDelegate = appDelegate
        _sessionID = State(initialValue: initialSessionID)
    }
    var body: some View {
        Group {
            if let sessionID {
                SessionWindow(sessionID: sessionID, model: model).frame(minWidth: 850, minHeight: 580)
            } else {
                SessionPicker(model: model) { id in model.openSession(id); sessionID = id }.frame(minWidth: 520, minHeight: 400)
            }
        }
        .environment(model)
        .onAppear {
            AcceptanceTrace.record("initial-scene-appeared")
            model.installOpenWindow { id in
                if sessionID == nil { sessionID = id } else { openWindow(value: id) }
            }
            model.installOpenSessionPicker { openWindow(id: "sessions") }
            appDelegate.installTerminationHandler { model.prepareForTermination() }
            appDelegate.installReopenHandler { model.presentSessionPicker() }
            if sessionID == nil, let id = model.bootstrap() { sessionID = id }
        }
    }
}

private struct SavedSessionScene: View {
    let model: PipePlotAppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        SessionPicker(model: model) { id in model.openSession(id); openWindow(value: id) }
            .frame(minWidth: 520, minHeight: 400)
    }
}

@MainActor
final class PipePlotAppDelegate: NSObject, NSApplicationDelegate {
    private var initialWindowOpener: OpenWindowAction?
    private var needsInitialWindow = false
    func installInitialWindowOpener(_ action: OpenWindowAction) {
        AcceptanceTrace.record("command-window-opener-installed")
        initialWindowOpener = action
        if needsInitialWindow {
            needsInitialWindow = false
            DispatchQueue.main.async { action(id: "initial") }
        }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        AcceptanceTrace.record("application-did-finish-launching-active-\(NSApp.isActive)-policy-\(NSApp.activationPolicy().rawValue)-windows-\(NSApp.windows.count)")
        if NSApp.windows.isEmpty {
            if let initialWindowOpener { initialWindowOpener(id: "initial") }
            else { needsInitialWindow = true }
        }
        if ProcessInfo.processInfo.arguments.contains("--pipeplot-launched-by-cli") {
            // A cold pipeline is an explicit request for its first chart. SwiftUI
            // may defer scene appearance while a launch is inactive; IPC readiness
            // alone does not make that chart visible.
            NSApp.activate()
            DispatchQueue.main.async {
                AcceptanceTrace.record("cold-order-windows-\(NSApp.windows.count)-active-\(NSApp.isActive)")
                for window in NSApp.windows where window.canBecomeKey {
                    window.makeKeyAndOrderFront(nil)
                    window.contentView?.layoutSubtreeIfNeeded()
                    window.display()
                }
            }
        }
    }
    private var reopenHandler: (() -> Void)?
    func installReopenHandler(_ handler: @escaping () -> Void) { reopenHandler = handler }
    private var terminationHandler: (() -> Void)?
    func installTerminationHandler(_ handler: @escaping () -> Void) { terminationHandler = handler }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        terminationHandler?()
        return .terminateNow
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows, let reopenHandler { reopenHandler(); return false }
        return true
    }
}

extension Notification.Name {
    static let pipePlotReopen = Notification.Name("PipePlotReopen")
}
