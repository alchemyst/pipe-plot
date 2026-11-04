import AppKit
import PipePlotCore
import UniformTypeIdentifiers

@MainActor
enum RawCSVExport {
    static func chooseDestination(
        store: SampleStore, streams: [StreamDescriptor], bounds: ClosedRange<Date>? = nil, name: String
    ) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "\(name.replacingOccurrences(of: "/", with: "-")).csv"
        panel.canCreateDirectories = true
        let window = NSApp.keyWindow ?? NSApp.mainWindow

        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let destination = panel.url else { return }
            export(store: store, streams: streams, bounds: bounds, to: destination, in: window)
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private static func export(
        store: SampleStore, streams: [StreamDescriptor], bounds: ClosedRange<Date>?,
        to destination: URL, in window: NSWindow?
    ) {
        let progress = NSAlert()
        progress.messageText = "Exporting raw observations"
        progress.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        let indicator = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 240, height: 16))
        indicator.isIndeterminate = true
        indicator.startAnimation(nil)
        progress.accessoryView = indicator

        let worker = Task.detached(priority: .utility) {
            try store.exportRawCSV(streams: streams, bounds: bounds, to: destination)
        }

        // The save panel has finished before the progress sheet is presented.
        Task {
            if let window {
                progress.beginSheetModal(for: window) { response in
                    if response == .alertFirstButtonReturn { worker.cancel() }
                }
            }
            let result = await worker.result
            if let window, progress.window.sheetParent === window {
                window.endSheet(progress.window)
            }
            if case .failure(let error) = result, !(error is CancellationError) {
                let alert = NSAlert(error: error)
                alert.messageText = "Could not export raw observations"
                alert.informativeText = error.localizedDescription
                if let window { _ = await alert.beginSheetModal(for: window) } else { alert.runModal() }
            }
        }
    }
}
