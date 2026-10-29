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
                    SessionPicker(model: model) { id in sessionID = id }
                        .frame(minWidth: 520, minHeight: 400)
                }
            }
            .environment(model)
            .onAppear {
                model.installOpenWindow { id in openWindow(value: id) }
                model.installOpenSessionPicker { openWindow(id: "sessions") }
                if sessionID == nil, let id = model.bootstrap() { sessionID = id }
            }
        }
        .commands {
            PipePlotCommands(model: model)
        }
        WindowGroup("Saved Sessions", id: "sessions") {
            SessionPicker(model: model) { id in openWindow(value: id) }
                .frame(minWidth: 520, minHeight: 400)
        }
        Settings {
            SettingsView(model: model)
        }
    }
}

@MainActor
final class PipePlotAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { NotificationCenter.default.post(name: .pipePlotReopen, object: nil) }
        return true
    }
}

extension Notification.Name {
    static let pipePlotReopen = Notification.Name("PipePlotReopen")
}
