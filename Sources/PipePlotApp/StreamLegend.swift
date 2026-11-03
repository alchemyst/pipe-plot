import SwiftUI
import PipePlotCore

private struct LegendSheet: Identifiable {
    enum Route {
        case rename(StreamDescriptor)
        case derived(StreamDescriptor)
        case reassociate(StreamDescriptor)
    }
    let id = UUID()
    let route: Route
}

struct StreamLegend: View {
    let chart: ChartSnapshot
    let session: SessionSnapshot
    let model: PipePlotAppModel
    @State private var sheet: LegendSheet?
    @State private var renameText = ""
    private var layoutStreams: [StreamDescriptor] { chart.streams.filter { $0.isLayoutHidden != true } }
    private var hiddenStreams: [StreamDescriptor] { chart.streams.filter { $0.isLayoutHidden == true } }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Array(layoutStreams.enumerated()), id: \.element.id) { index, stream in
                    HStack(spacing: 6) {
                        StreamDragHandle(stream: stream, state: model.streamDrag).frame(width: 18, height: 22)
                        Circle().fill(PlotCanvas.color(for: stream, fallback: index)).frame(width: 8, height: 8)
                        Text(stream.name).font(.caption.weight(.medium))
                        if !(stream.linesVisible ?? chart.settings.linesVisible)
                            && !(stream.dotsVisible ?? chart.settings.dotsVisible)
                        {
                            Text("Marks off").font(.caption2).foregroundStyle(.secondary)
                                .help(
                                    "Lines and dots are off; value labels and analysis remain visible. Hide from Layout removes all stream visuals."
                                )
                        }
                        Text(stream.state.rawValue.capitalized).font(.caption2).foregroundStyle(.secondary)
                        SnapshotMenu(title: "Actions for \(stream.name)", symbol: "ellipsis", compact: true) {
                            streamActions(stream) + [
                                .separator,
                                .command(
                                    (stream.linesVisible ?? chart.settings.linesVisible)
                                        ? "Hide connecting lines" : "Show connecting lines"
                                ) {
                                    model.updateStreamStyle(
                                        stream.id, colorHex: stream.colorHex, dotsVisible: stream.dotsVisible,
                                        linesVisible: !(stream.linesVisible ?? chart.settings.linesVisible))
                                },
                                .command((stream.dotsVisible ?? chart.settings.dotsVisible) ? "Hide dots" : "Show dots")
                                {
                                    model.updateStreamStyle(
                                        stream.id, colorHex: stream.colorHex,
                                        dotsVisible: !(stream.dotsVisible ?? chart.settings.dotsVisible),
                                        linesVisible: stream.linesVisible)
                                },
                                .submenu(
                                    "Color",
                                    (0..<9).map { index in
                                        .command("Color \(index + 1)") {
                                            model.updateStreamStyle(
                                                stream.id, colorHex: PlotCanvas.paletteHex(index),
                                                dotsVisible: stream.dotsVisible, linesVisible: stream.linesVisible)
                                        }
                                    }),
                            ]
                        }.frame(width: 30)
                    }
                    .padding(.leading, 8).padding(.trailing, 4).padding(.vertical, 5)
                    .background(.quaternary.opacity(0.6), in: Capsule())
                    .background(SnapshotContextMenu { streamActions(stream) })

                }
                if layoutStreams.isEmpty {
                    Text(
                        chart.streams.isEmpty
                            ? "No streams" : "\(hiddenStreams.count) hidden stream(s) · restore from Chart actions"
                    ).font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 14).padding(.vertical, 9)
        }.scrollIndicators(.hidden)
            .help("Drag a stream's handle onto a chart to merge, or onto a separator to insert a row")
            .sheet(item: $sheet) { item in
                switch item.route {
                case .derived(let stream):
                    DerivedSeriesSheet(stream: stream, model: model) { sheet = nil }
                case .rename(let stream):
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Rename stream").font(.title3.weight(.semibold))
                        TextField("Stream name", text: $renameText).textFieldStyle(.roundedBorder)
                        HStack {
                            Spacer()
                            Button("Cancel") { sheet = nil }
                            Button("Save") {
                                model.rename(stream.id, to: renameText)
                                sheet = nil
                            }.keyboardShortcut(.defaultAction)
                        }
                    }.padding(22).frame(width: 340)
                case .reassociate(let stream):
                    ReassociationSheet(source: stream, session: session, model: model) { sheet = nil }
                }
            }
    }

    private func streamActions(_ stream: StreamDescriptor) -> [SnapshotMenuItem] {
        [
            .command("Rename…") {
                renameText = stream.name
                sheet = LegendSheet(route: .rename(stream))
            },
            .submenu(
                "Move to Chart",
                session.charts.filter { $0.id != chart.id && $0.isVisible }.map { destination in
                    .command(destination.title) { model.move(stream.id, to: destination.id) }
                }),
            .command("Move to New Chart") { model.moveToNewChart(stream.id, sessionID: session.id, after: chart.id) },
            .submenu(
                "Insert as New Chart Before",
                session.charts.filter(\.isVisible).map { destination in
                    .command(destination.title) {
                        _ = model.dropStream(
                            [stream.id.uuidString], sessionID: session.id, destination: .before(destination.id))
                    }
                }),
            .command("Smoothing and derivative…") { sheet = LegendSheet(route: .derived(stream)) },
            .command("Continue / Reassociate Group…") { sheet = LegendSheet(route: .reassociate(stream)) },
            .command("Hide from Layout") { model.setStreamLayoutHidden(true, streamID: stream.id) },
        ]
    }

}

private struct ReassociationSheet: View {
    let source: StreamDescriptor
    let session: SessionSnapshot
    let model: PipePlotAppModel
    let onClose: () -> Void
    @State private var targets: [StreamID: StreamID] = [:]

    private var sourceIDs: [StreamID] { model.samplerGroup(containing: source.id, sessionID: session.id) }
    private var sourceStreams: [StreamDescriptor] {
        let all = session.charts.flatMap(\.streams)
        return sourceIDs.compactMap { id in all.first(where: { $0.id == id }) }
    }
    private var candidates: [StreamDescriptor] {
        let sourceSet = Set(sourceIDs)
        return session.charts.filter(\.isVisible).flatMap(\.streams).filter {
            !sourceSet.contains($0.id) && ($0.state == .ended || $0.state == .disconnected)
        }
    }
    private var valid: Bool {
        sourceIDs.count > 0 && sourceStreams.count == sourceIDs.count
            && targets.count == sourceIDs.count && Set(targets.values).count == sourceIDs.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Reassociate sampler group").font(.title3.weight(.semibold))
            Text("Map each incoming column to a disconnected stream. The entire group is applied together.")
                .font(.callout).foregroundStyle(.secondary)
            if candidates.count < sourceIDs.count {
                ContentUnavailableView(
                    "Not enough destination streams", systemImage: "arrow.left.arrow.right",
                    description: Text("The destination group must have one disconnected stream per incoming column."))
            } else {
                ForEach(sourceStreams) { item in
                    HStack {
                        Text(item.name).frame(maxWidth: .infinity, alignment: .leading)
                        Picker("Destination", selection: targetBinding(for: item.id)) {
                            Text("Choose destination…").tag(Optional<StreamID>.none)
                            ForEach(candidates) { candidate in
                                Text("\(candidate.name) · \(candidateChartTitle(candidate.id))")
                                    .tag(Optional(candidate.id))
                            }
                        }.frame(width: 240)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: onClose)
                Button("Reassociate") {
                    let destinationIDs = sourceIDs.compactMap { targets[$0] }
                    model.reassociate(sourceIDs, with: destinationIDs, sessionID: session.id)
                    onClose()
                }.keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }
        .padding(22).frame(width: 520)
    }

    private func targetBinding(for id: StreamID) -> Binding<StreamID?> {
        Binding(
            get: { targets[id] },
            set: { value in
                if let value { targets[id] = value } else { targets.removeValue(forKey: id) }
            })
    }

    private func candidateChartTitle(_ streamID: StreamID) -> String {
        session.charts.first(where: { $0.streams.contains(where: { $0.id == streamID }) })?.title ?? "Chart"
    }
}
