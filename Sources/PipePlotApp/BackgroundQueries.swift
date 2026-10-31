import Foundation
import Observation
import PipePlotCore

/// One outstanding query of each kind per stream. Queries never execute on the
/// view/responder thread; a new viewport supersedes old output by its exact key.
@MainActor @Observable
final class BackgroundQueries {
    private(set) var revision = 0
    @ObservationIgnored private let queue = DispatchQueue(label: "PipePlot.analysis", qos: .userInitiated)
    @ObservationIgnored private var displays: [StreamID: (QueryKey, [StoredSample])] = [:]
    @ObservationIgnored private var statistics: [StreamID: (QueryKey, SelectionStatistics?)] = [:]
    @ObservationIgnored private var nearest: [StreamID: (QueryKey, StoredSample?)] = [:]
    @ObservationIgnored private var nearestPending: Set<StreamID> = []
    @ObservationIgnored private var fits: [StreamID: (QueryKey, LinearFit?)] = [:]
    @ObservationIgnored private var displayPending: Set<StreamID> = []
    @ObservationIgnored private var statisticsPending: Set<StreamID> = []
    @ObservationIgnored private var fitPending: Set<StreamID> = []

    @ObservationIgnored private(set) var submittedQueryCount = 0

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
    func fit(_ id: StreamID, cacheID: UUID, key: QueryKey, store: SampleStore, completed: @escaping () -> Void, failed: @escaping (Error) -> Void) -> LinearFit? {
        if let entry = fits[cacheID], entry.0 == key { return entry.1 }
        if fitPending.insert(cacheID).inserted {
            submittedQueryCount &+= 1
            queue.async { [weak self] in
                let result = Result { try store.linearFit(streamID: id, from: key.start, to: key.end) }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.fitPending.remove(cacheID)
                    switch result { case .success(let fit): self.fits[cacheID] = (key, fit); case .failure(let error): self.fits[cacheID] = (key, nil); failed(error) }
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
        nearest = nearest.filter { ids.contains($0.key) }
        displays = displays.filter { ids.contains($0.key) }
        statistics = statistics.filter { ids.contains($0.key) }
        if fits.count > 256 { fits.removeAll() }
    }
}
