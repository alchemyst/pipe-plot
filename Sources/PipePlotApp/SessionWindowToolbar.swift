import SwiftUI

struct SessionWindowToolbar: ToolbarContent {
    let model: PipePlotAppModel
    let sessionModel: SessionModel
    let inspectorVisible: Bool
    let toggleInspector: () -> Void
    let renameSession: () -> Void

    private var presentationTarget: SessionCommandTarget {
        SessionCommandTarget(focused: sessionModel, editingText: false)
    }

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Label("PipePlot", systemImage: "waveform.path.ecg")
                .help("PipePlot · live measurements and local capture")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.createSessionWindow()
            } label: {
                Label("New Session", systemImage: "plus.rectangle.on.folder")
            }
            .help("Create a session in a new window (⌘N)")
            Button {
                presentationTarget.createChart(using: model)
            } label: {
                Label("Add Chart", systemImage: "chart.bar.xaxis")
            }
            .disabled(!presentationTarget.canCreateChart)
            .help("Create a chart below the selected chart (⌘⇧D)")
            Button(action: toggleInspector) {
                Label("Chart Settings", systemImage: "sidebar.right")
            }
            .tint(inspectorVisible ? .accentColor : .primary)
            .disabled(!presentationTarget.canAddGuide)
            .help(inspectorVisible ? "Hide chart settings" : "Show settings for the selected chart")
            Menu {
                Button("Rename Session…", action: renameSession)
                Button("Move Session to \(sessionTrashName)", role: .destructive) {
                    guard let session = presentationTarget.snapshot else { return }
                    model.deleteSession(session.id)
                }
            } label: {
                Label("Session", systemImage: "ellipsis.circle")
            }
            .disabled(presentationTarget.snapshot == nil)
        }
    }
}
