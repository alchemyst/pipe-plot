import SwiftUI
import PipePlotCore

struct ChartHeader: View {
    let chart: ChartSnapshot
    let session: SessionSnapshot
    let model: PipePlotAppModel
    let sessionModel: SessionModel
    let onManageGuides: () -> Void
    @State private var renameChartText = ""
    @State private var showRenameChart = false
    private var hiddenStreams: [StreamDescriptor] { chart.streams.filter { $0.isLayoutHidden == true } }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "chart.xyaxis.line").foregroundStyle(Color.accentColor)
            Text(chart.title).font(.headline)
            if let unit = chart.settings.unit, !unit.isEmpty {
                Text(unit).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }
            Spacer()
            SnapshotMenu(title: "Guides", symbol: "line.3.horizontal") {
                [
                    .command("Add horizontal value guide…") { sessionModel.requestValueGuide(for: chart.id) },
                    .command("Add time guide at Now") {
                        model.addTimeGuide(at: model.sessionNow(session), sessionID: session.id)
                    },
                    .command("Manage Guides…") {
                        onManageGuides()
                    },
                ]
            }.help("Create and edit chart guides")
            SnapshotMenu(title: "Chart actions", symbol: "ellipsis.circle", compact: true) {
                var items: [SnapshotMenuItem] = [
                    .command("Rename Chart…") {
                        renameChartText = chart.title
                        showRenameChart = true
                    }
                ]
                let charts = session.charts.filter(\.isVisible)
                if let index = charts.firstIndex(where: { $0.id == chart.id }) {
                    items += [
                        .command("Move Up", enabled: index > 0) { model.reorderChart(chart.id, to: index - 1) },
                        .command("Move Down", enabled: index < charts.count - 1) {
                            model.reorderChart(chart.id, to: index + 1)
                        },
                    ]
                }
                items.append(
                    .command(chart.streams.isEmpty ? "Delete Empty Chart" : "Hide Chart") {
                        model.deleteChart(chart.id)
                    })
                if !hiddenStreams.isEmpty {
                    items += [
                        .separator,
                        .submenu(
                            "Restore Hidden Stream",
                            hiddenStreams.map { stream in
                                .command(stream.name) { model.setStreamLayoutHidden(false, streamID: stream.id) }
                            }),
                    ]
                }
                let hidden = session.charts.filter { !$0.isVisible }
                if !hidden.isEmpty {
                    items += [
                        .separator,
                        .submenu(
                            "Restore Hidden Chart",
                            hidden.map { item in .command(item.title) { model.restoreChart(item.id) } }),
                    ]
                }
                return items
            }.help("Chart actions")
            Button {
                model.toggleLines(chart)
            } label: {
                Image(
                    systemName: chart.settings.linesVisible
                        ? "point.topleft.down.to.point.bottomright.curvepath"
                        : "point.topleft.down.to.point.bottomright.curvepath")
            }
            .buttonStyle(.plain).foregroundStyle(chart.settings.linesVisible ? Color.accentColor : .secondary).help(
                "Toggle connecting lines")
            Button {
                model.toggleDots(chart)
            } label: {
                Image(systemName: "circle.fill")
            }.buttonStyle(.plain).foregroundStyle(
                chart.settings.dotsVisible ? Color.accentColor : .secondary
            ).help("Toggle dots")
            Button {
                model.setTarget(chart.id)
            } label: {
                Label(chart.isTarget ? "Target" : "Set target", systemImage: chart.isTarget ? "scope" : "circle.dashed")
            }.buttonStyle(.bordered).tint(chart.isTarget ? .accentColor : .secondary).controlSize(.small)
        }
        .padding(.horizontal, 15).padding(.top, 13).padding(.bottom, 5)
        .sheet(isPresented: $showRenameChart) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Rename chart").font(.title3.weight(.semibold))
                TextField("Chart name", text: $renameChartText).textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Cancel") { showRenameChart = false }
                    Button("Save") {
                        model.renameChart(chart.id, to: renameChartText)
                        showRenameChart = false
                    }.keyboardShortcut(.defaultAction)
                }
            }.padding(22).frame(width: 340)
        }
    }
}
