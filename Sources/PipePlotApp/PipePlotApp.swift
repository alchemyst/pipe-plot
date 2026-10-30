import SwiftUI
import AppKit
import PipePlotCore

@main
struct PipePlotApplication: App {
    @NSApplicationDelegateAdaptor(PipePlotAppDelegate.self) private var appDelegate
    @State private var model = PipePlotAppModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup("PipePlot", for: SessionID.self) { $sessionID in
            Group {
                if let sessionID {
                    SessionWindow(sessionID: sessionID, model: model)
                        .frame(minWidth: 850, minHeight: 580)
                } else {
                    SessionPicker(model: model) { id in model.openSession(id); sessionID = id }
                        .frame(minWidth: 520, minHeight: 400)
                }
            }
            .environment(model)
            .onReceive(NotificationCenter.default.publisher(for: .pipePlotReopen)) { _ in model.presentSessionPicker() }
            .onAppear {
                model.installOpenWindow { id in
                    if sessionID == nil { sessionID = id } else { openWindow(value: id) }
                }
                model.installOpenSessionPicker { openWindow(id: "sessions") }
                appDelegate.installTerminationHandler { model.prepareForTermination() }
                if sessionID == nil, let id = model.bootstrap() { sessionID = id }
            }
        }
        .commands {
            PipePlotCommands(model: model)
        }
        WindowGroup("Saved Sessions", id: "sessions") {
            SessionPicker(model: model) { id in model.openSession(id); openWindow(value: id) }
                .frame(minWidth: 520, minHeight: 400)
        }
        Settings {
            SettingsView(model: model)
        }
    }
}

@MainActor
final class PipePlotAppDelegate: NSObject, NSApplicationDelegate {
    private var terminationHandler: (() -> Void)?
    func installTerminationHandler(_ handler: @escaping () -> Void) { terminationHandler = handler }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        terminationHandler?()
        return .terminateNow
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { NotificationCenter.default.post(name: .pipePlotReopen, object: nil) }
        return true
    }
}

extension Notification.Name {
    static let pipePlotReopen = Notification.Name("PipePlotReopen")
}
