import AppKit
import Foundation
import PipePlotCore

/// Opt-in, isolated launch data for checking actual WindowGroup chrome. The
/// ordinary app launch never enters this path.
@MainActor
enum Issue33AcceptanceFixture {
    static func makeModel() -> PipePlotAppModel {
        guard let requested = ProcessInfo.processInfo.environment["PIPEPLOT_ACCEPTANCE_DATABASE"] else {
            return PipePlotAppModel()
        }
        let source = URL(fileURLWithPath: requested).standardizedFileURL
        let parent = source.deletingLastPathComponent().resolvingSymlinksInPath()
        let database = parent.appendingPathComponent(source.lastPathComponent)
        guard requested.hasPrefix("/tmp/"),
            parent.path.hasPrefix("/tmp/pipeplot-acceptance-")
                || parent.path.hasPrefix("/private/tmp/pipeplot-acceptance-"),
            database.lastPathComponent == "acceptance.sqlite",
            (try? parent.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        else {
            fatalError(
                "PIPEPLOT_ACCEPTANCE_DATABASE must be acceptance.sqlite in a /tmp/pipeplot-acceptance-* directory")
        }
        if let appearance = ProcessInfo.processInfo.environment["PIPEPLOT_ACCEPTANCE_APPEARANCE"] {
            switch appearance {
            case "light": NSApplication.shared.appearance = NSAppearance(named: .aqua)
            case "dark": NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
            default: fatalError("PIPEPLOT_ACCEPTANCE_APPEARANCE must be light or dark")
            }
        }
        do {
            let store = try PipePlotStore(databaseURL: database)
            if try store.listSessions().isEmpty {
                let first = try store.createSession(title: "Acceptance · voltage")
                let second = try store.createSession(title: "Acceptance · pressure")
                for (session, names, unit, value) in [
                    (first, ["Voltage", "Aux voltage"], "mV", 12.0),
                    (second, ["Pressure"], "kPa", 85.0),
                ] {
                    let chart = session.charts[0]
                    let ready = try store.registerSampler(
                        intent: .chart(chartID: chart.id, lineNames: names),
                        sampler: SamplerIntent(columnCount: names.count, requestedNames: names))
                    var settings = chart.settings
                    settings.unit = unit
                    try store.updateSettings(settings, chartID: chart.id)
                    try store.upsertGuide(
                        Guide(orientation: .horizontalValue, value: value, label: "Reference"), chartID: chart.id)
                    for index in 0..<30 {
                        _ = try store.append(
                            SampleRow(
                                timestamp: Date().addingTimeInterval(Double(index - 30)),
                                values: names.count == 1
                                    ? [value + sin(Double(index) / 5)]
                                    : [value + sin(Double(index) / 5), value / 2 + cos(Double(index) / 5)]),
                            to: ready.attachmentID)
                    }
                    if names.count > 1 {
                        try store.updateStreamStyle(
                            ready.streams[1].id, colorHex: nil, dotsVisible: false, linesVisible: false)
                    }
                }
                try store.recordTerminationOpenSessions([first.id, second.id])
            }
        } catch {
            fatalError("Could not prepare isolated acceptance fixture: \(error)")
        }
        let socket = URL(fileURLWithPath: "/tmp/pipeplot-qa-\(UUID().uuidString.prefix(8)).sock")
        return PipePlotAppModel(databaseURL: database, socketURL: socket)
    }
}
