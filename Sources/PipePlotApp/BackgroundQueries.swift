import Foundation
import Observation
import PipePlotCore

/// One outstanding query per stream (or forecast). Queries never execute on the
/// view/responder thread; fit snapshots additionally track selected membership.
@MainActor @Observable
final class BackgroundQueries {
    private(set) var revision = 0
    @ObservationIgnored private let queue = DispatchQueue(label: "PipePlot.analysis", qos: .userInitiated)
    @ObservationIgnored private var displays: [StreamID: (QueryKey, [StoredSample])] = [:]
    @ObservationIgnored private var statistics: [StreamID: (QueryKey, SelectionStatistics?)] = [:]
    @ObservationIgnored private var nearest: [StreamID: (QueryKey, StoredSample?)] = [:]
    @ObservationIgnored private var nearestPending: Set<StreamID> = []
    @ObservationIgnored private var fits: [UUID: (QueryKey, TimeSelection, ReusableLinearFit)] = [:]
    @ObservationIgnored private var displayPending: Set<StreamID> = []
    @ObservationIgnored private var statisticsPending: Set<StreamID> = []
    @ObservationIgnored private var fitPending: Set<UUID> = []

    @ObservationIgnored private(set) var submittedQueryCount = 0

    @ObservationIgnored private(set) var rawFitCount = 0
    @ObservationIgnored private var fitGeneration = 0
    @ObservationIgnored private var fitsNeedValidation: Set<UUID> = []

    @ObservationIgnored private var derived: [StreamID: (QueryKey, DerivedSeriesConfiguration, Bool, DerivedSeriesResult)] = [:]
    @ObservationIgnored private var derivedPending: Set<StreamID> = []
    @ObservationIgnored private var derivedGeneration = 0

    func suggestedInterval(_ id: StreamID, store: SampleStore) async -> Double? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: try? store.suggestedDerivedInterval(streamID: id)) }
        }
    }
    func derivedSeries(_ id: StreamID, key: QueryKey, configuration: DerivedSeriesConfiguration, live: Bool, store: SampleStore) -> DerivedSeriesResult? {
        _ = revision
        if let cached = derived[id], cached.0 == key, cached.1 == configuration, cached.2 == live { return cached.3 }
        let generation = derivedGeneration
        if derivedPending.insert(id).inserted {
            submittedQueryCount &+= 1
            queue.async { [weak self] in
                let result: DerivedSeriesResult
                do { result = try store.derivedSeries(streamID: id, configuration: configuration, from: key.start, to: key.end, live: live) }
                catch { result = DerivedSeriesResult(points: [], message: error.localizedDescription, processedSamples: 0) }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.derivedPending.remove(id)
                    if generation == self.derivedGeneration { self.derived[id] = (key, configuration, live, result) }
                    self.revision &+= 1
                }
            }
        }
        // Keep real coordinates during live range updates, but never show results
        // from different settings or after undo/reassociation invalidation.
        if let cached = derived[id], cached.1 == configuration, cached.2 == live { return cached.3 }
        return nil
    }

    func invalidateFits() {
        derivedGeneration &+= 1
        derived.removeAll()
        fitGeneration &+= 1
        fitsNeedValidation.formUnion(fits.keys)
    }

    struct QueryKey: Equatable {
        let start: Date
        let end: Date
        let count: Int64
        let last: Date?
    }
    func display(_ id: StreamID, key: QueryKey, store: SampleStore, failed: @escaping (Error) -> Void) -> [StoredSample] {
        _ = revision
        if let entry = displays[id], entry.0 == key { return entry.1 }
        if displayPending.insert(id).inserted {
            submittedQueryCount &+= 1
            queue.async { [weak self] in
                let result = Result { try store.displaySamples(streamID: id, from: key.start, to: key.end, bucketCount: 800) }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.displayPending.remove(id)
                    switch result { case .success(let rows): self.displays[id] = (key, rows); case .failure(let error): self.displays[id] = (key, []); failed(error) }
                    self.revision &+= 1
                }
            }
        }
        // Existing points retain their real coordinates while the new range loads.
        return displays[id]?.1 ?? []
    }
    func isCurrentDisplay(_ id: StreamID, key: QueryKey) -> Bool {
        guard let cached = displays[id]?.0, let last = key.last else { return false }
        return cached.count == key.count && cached.last == last && cached.start <= last && last <= cached.end
    }

    func stats(_ id: StreamID, key: QueryKey, store: SampleStore, failed: @escaping (Error) -> Void) -> SelectionStatistics? {
        _ = revision
        if let entry = statistics[id], entry.0 == key { return entry.1 }
        if statisticsPending.insert(id).inserted {
            submittedQueryCount &+= 1
            queue.async { [weak self] in
                let result = Result { try store.statistics(streamID: id, from: key.start, to: key.end) }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.statisticsPending.remove(id)
                    switch result { case .success(let stats): self.statistics[id] = (key, stats); case .failure(let error): self.statistics[id] = (key, nil); failed(error) }
                    self.revision &+= 1
                }
            }
        }
        return nil
    }
    func nearestSample(_ id: StreamID, key: QueryKey, store: SampleStore) -> StoredSample? {
        _ = revision
        if let entry = nearest[id], entry.0 == key { return entry.1 }
        if nearestPending.insert(id).inserted {
            submittedQueryCount &+= 1
            queue.async { [weak self] in
                let sample = try? store.nearestSample(streamID: id, at: key.start)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.nearestPending.remove(id); self.nearest[id] = (key, sample)
                    self.revision &+= 1
                }
            }
        }
        return nil
    }
    func fit(_ id: StreamID, cacheID: UUID, key: QueryKey, settings: TimeSelection, store: SampleStore, completed: @escaping () -> Void, failed: @escaping (Error) -> Void) -> LinearFit? {
        // Counts/latest time detect arrivals; mapping and history edits call
        // invalidateFits even when those descriptors happen to be unchanged.
        if !fitsNeedValidation.contains(cacheID),
           let entry = fits[cacheID], entry.2.streamID == id, entry.1 == settings,
           entry.0.count == key.count, entry.0.last == key.last,
           entry.2.contains(from: key.start, to: key.end) {
            return entry.2.fit
        }
        let previous = fits[cacheID].flatMap { $0.1 == settings ? $0.2 : nil }
        let generation = fitGeneration
        if fitPending.insert(cacheID).inserted {
            submittedQueryCount &+= 1
            queue.async { [weak self] in
                let result = Result { try store.reusableLinearFit(streamID: id, from: key.start, to: key.end, reusing: previous) }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.fitPending.remove(cacheID)
                    if case .success(let snapshot) = result, snapshot.didRefit { self.rawFitCount &+= 1 }
                    if generation == self.fitGeneration {
                        switch result {
                        case .success(let snapshot):
                            self.fits[cacheID] = (key, settings, snapshot)
                            self.fitsNeedValidation.remove(cacheID)
                        case .failure(let error): failed(error)
                        }
                    }
                    self.revision &+= 1
                    completed()
                }
            }
        }
        return nil
    }
    func isCalculatingStatistics(_ id: StreamID) -> Bool { statisticsPending.contains(id) }
    func isFitting(_ id: UUID) -> Bool { fitPending.contains(id) }
    func retain(_ ids: Set<StreamID>) {
        derived = derived.filter { ids.contains($0.key) }
        nearest = nearest.filter { ids.contains($0.key) }
        displays = displays.filter { ids.contains($0.key) }
        statistics = statistics.filter { ids.contains($0.key) }
        if fits.count > 256 { fits.removeAll(); fitsNeedValidation.removeAll() }
    }
}
