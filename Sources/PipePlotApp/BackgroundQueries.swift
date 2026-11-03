import Foundation
import Observation
import PipePlotCore

/// A result read never starts work. Each slot retains one running scan and one
/// replaceable desired request; cancelling a task cannot interrupt SQLite.
@MainActor @Observable
final class BackgroundQueries {
    enum State<Value: Sendable>: Sendable {
        case idle
        case loading
        case cached(Value)
        case failed(String)
    }

    @MainActor @Observable
    final class Slot<Key: Equatable & Sendable, Value: Sendable> {
        var state: State<Value> = .idle
        @ObservationIgnored var key: Key?
        @ObservationIgnored var desired: Key?
        @ObservationIgnored var running = false
        @ObservationIgnored var runningKey: Key?
        @ObservationIgnored var generation = 0
        @ObservationIgnored var cached: (Key, Value)?
        @ObservationIgnored var operation: (@Sendable (Key) -> Result<Value, Error>)?
        @ObservationIgnored var completed: (@MainActor () -> Void)?
        @ObservationIgnored var failed: (@MainActor (Error) -> Void)?
        @ObservationIgnored var finished: (@MainActor (Result<Value, Error>) -> Void)?
        @ObservationIgnored var onFinish: (@MainActor () -> Void)?

        func request(
            _ requested: Key, on queue: DispatchQueue,
            operation: @escaping @Sendable (Key) -> Result<Value, Error>,
            submitted: @escaping @MainActor () -> Void,
            finished: @escaping @MainActor (Result<Value, Error>) -> Void = { _ in },
            completed: @escaping @MainActor () -> Void = {},
            failed: @escaping @MainActor (Error) -> Void = { _ in }
        ) {
            if let cached, cached.0 == requested {
                key = requested
                desired = nil
                if case .cached = state {} else { state = .cached(cached.1) }
                return
            }
            if runningKey == requested {
                key = requested
                desired = nil
                if case .loading = state {} else { state = .loading }
                return
            }
            if key == requested {
                if case .failed = state { return }  // Retry is explicit.
                if case .loading = state { return }
            }
            key = requested
            desired = requested
            self.operation = operation
            self.completed = completed
            self.failed = failed
            self.finished = finished
            state = .loading
            launch(on: queue, submitted: submitted)
        }

        func retry(on queue: DispatchQueue, submitted: @escaping @MainActor () -> Void) {
            guard let key else { return }
            desired = key
            state = .loading
            launch(on: queue, submitted: submitted)
        }

        func cancel() {
            generation &+= 1
            desired = nil
            runningKey = nil  // The old synchronous scan still runs, but cannot satisfy a new request.
            key = nil
            cached = nil
            state = .idle
        }

        private func launch(on queue: DispatchQueue, submitted: @escaping @MainActor () -> Void) {
            guard !running, let desired, let operation else { return }
            running = true
            runningKey = desired
            self.desired = nil
            let generation = generation
            submitted()
            queue.async { [weak self] in
                let result = operation(desired)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.running = false
                    self.runningKey = nil
                    self.finished?(result)
                    if generation == self.generation, self.key == desired {
                        switch result {
                        case .success(let value):
                            self.cached = (desired, value)
                            self.state = .cached(value)
                        case .failure(let error):
                            self.state = .failed(error.localizedDescription)
                            self.failed?(error)
                        }
                        self.completed?()
                    }
                    self.launch(on: queue, submitted: submitted)
                    self.onFinish?()
                }
            }
        }

        func exact(_ requested: Key) -> Value? {
            guard key == requested, case .cached(let value) = state else { return nil }
            return value
        }
    }

    struct QueryKey: Equatable, Sendable {
        let start: Date
        let end: Date
        let count: Int64
        let last: Date?
    }
    struct DerivedKey: Equatable, Sendable {
        let query: QueryKey
        let configuration: DerivedSeriesConfiguration
        let live: Bool
    }
    struct FitKey: Equatable, Sendable {
        let stream: StreamID
        let query: QueryKey
        let selection: TimeSelection
        let generation: Int
    }

    @ObservationIgnored private let queue = DispatchQueue(label: "PipePlot.analysis", qos: .userInitiated)
    @ObservationIgnored private var displays: [StreamID: Slot<QueryKey, [StoredSample]>] = [:]
    @ObservationIgnored private var statistics: [StreamID: Slot<QueryKey, SelectionStatistics?>] = [:]
    @ObservationIgnored private var nearest: [StreamID: Slot<QueryKey, StoredSample?>] = [:]
    @ObservationIgnored private var derived: [StreamID: Slot<DerivedKey, DerivedSeriesResult>] = [:]
    @ObservationIgnored private var fits: [UUID: Slot<FitKey, ReusableLinearFit>] = [:]
    @ObservationIgnored private var previousFits: [UUID: (StreamID, TimeSelection, ReusableLinearFit)] = [:]
    @ObservationIgnored private var retainedStreams: Set<StreamID> = []
    @ObservationIgnored private var retainedForecasts: Set<UUID> = []
    @ObservationIgnored private var hasRetentionPolicy = false
    @ObservationIgnored private(set) var submittedQueryCount = 0
    @ObservationIgnored private(set) var rawFitCount = 0
    @ObservationIgnored private var fitGeneration = 0

    private func countSubmission() { submittedQueryCount &+= 1 }
    private static func slot<Key, Value>(
        _ id: UUID, in slots: inout [UUID: Slot<Key, Value>]
    ) -> Slot<Key, Value> where Key: Equatable & Sendable, Value: Sendable {
        if let existing = slots[id] { return existing }
        let created = Slot<Key, Value>()
        slots[id] = created
        return created
    }
    func observeDisplay(_ id: StreamID) -> State<[StoredSample]> {
        Self.slot(id, in: &displays).state
    }
    func observeStatistics(_ id: StreamID) -> State<SelectionStatistics?> {
        Self.slot(id, in: &statistics).state
    }
    func observeNearest(_ id: StreamID) -> State<StoredSample?> {
        Self.slot(id, in: &nearest).state
    }
    func observeDerived(_ id: StreamID) -> State<DerivedSeriesResult> {
        Self.slot(id, in: &derived).state
    }

    func requestDisplay(
        _ id: StreamID, key: QueryKey, store: SampleStore, failed: @escaping @MainActor (Error) -> Void = { _ in }
    ) {
        let entry = Self.slot(id, in: &displays)
        entry.onFinish = { [weak self] in self?.pruneEvicted() }
        entry.request(
            key, on: queue,
            operation: { request in
                Result {
                    try store.displaySamples(streamID: id, from: request.start, to: request.end, bucketCount: 800)
                }
            }, submitted: { self.countSubmission() }, failed: failed)
    }
    func display(_ id: StreamID, key: QueryKey) -> [StoredSample] {
        if let value = displays[id]?.exact(key) { return value }
        return displays[id]?.cached?.1 ?? []  // Keep actual coordinates during a range change.
    }
    func isReadyDisplay(_ id: StreamID, key: QueryKey) -> Bool {
        displays[id]?.exact(key) != nil
    }
    func isCurrentDisplay(_ id: StreamID, key: QueryKey) -> Bool {
        guard let cached = displays[id]?.cached?.0, let last = key.last else { return false }
        return cached.count == key.count && cached.last == last && cached.start <= last && last <= cached.end
    }
    func displayState(_ id: StreamID) -> State<[StoredSample]> { displays[id]?.state ?? .idle }

    func requestStats(
        _ id: StreamID, key: QueryKey, store: SampleStore, failed: @escaping @MainActor (Error) -> Void = { _ in }
    ) {
        let entry = Self.slot(id, in: &statistics)
        entry.onFinish = { [weak self] in self?.pruneEvicted() }
        entry.request(
            key, on: queue,
            operation: { request in
                Result { try store.statistics(streamID: id, from: request.start, to: request.end) }
            }, submitted: { self.countSubmission() }, failed: failed)
    }
    func stats(_ id: StreamID, key: QueryKey) -> SelectionStatistics? { statistics[id]?.exact(key) ?? nil }
    func statisticsState(_ id: StreamID) -> State<SelectionStatistics?> { statistics[id]?.state ?? .idle }
    func isCalculatingStatistics(_ id: StreamID) -> Bool {
        if case .loading = statisticsState(id) { return true }
        return false
    }

    func requestNearest(_ id: StreamID, key: QueryKey, store: SampleStore) {
        let entry = Self.slot(id, in: &nearest)
        entry.onFinish = { [weak self] in self?.pruneEvicted() }
        entry.request(
            key, on: queue,
            operation: { request in
                Result { try store.nearestSample(streamID: id, at: request.start) }
            }, submitted: { self.countSubmission() })
    }
    func nearestSample(_ id: StreamID, key: QueryKey) -> StoredSample? { nearest[id]?.exact(key) ?? nil }
    func nearestState(_ id: StreamID) -> State<StoredSample?> { nearest[id]?.state ?? .idle }

    func requestDerived(
        _ id: StreamID, key: DerivedKey, store: SampleStore
    ) {
        let entry = Self.slot(id, in: &derived)
        entry.onFinish = { [weak self] in self?.pruneEvicted() }
        entry.request(
            key, on: queue,
            operation: { request in
                Result {
                    try store.derivedSeries(
                        streamID: id, configuration: request.configuration, from: request.query.start,
                        to: request.query.end, live: request.live)
                }
            }, submitted: { self.countSubmission() })
    }
    func derivedSeries(_ id: StreamID, key: DerivedKey) -> DerivedSeriesResult? {
        if let exact = derived[id]?.exact(key) { return exact }
        guard let cached = derived[id]?.cached, cached.0.configuration == key.configuration,
            cached.0.live == key.live
        else { return nil }
        return cached.1
    }
    func derivedState(_ id: StreamID) -> State<DerivedSeriesResult> { derived[id]?.state ?? .idle }

    func requestFit(
        _ id: StreamID, cacheID: UUID, key: QueryKey, settings: TimeSelection, store: SampleStore,
        completed: @escaping @MainActor () -> Void, failed: @escaping @MainActor (Error) -> Void
    ) {
        let entry = Self.slot(cacheID, in: &fits)
        entry.onFinish = { [weak self] in self?.pruneEvicted() }
        let request = FitKey(stream: id, query: key, selection: settings, generation: fitGeneration)
        if let cached = entry.cached, cached.0.stream == id, cached.0.selection == settings,
            cached.0.generation == fitGeneration, cached.0.query.count == key.count,
            cached.0.query.last == key.last, cached.1.contains(from: key.start, to: key.end)
        {
            entry.key = request
            entry.cached = (request, cached.1)
            entry.desired = nil
            if case .cached = entry.state {} else { entry.state = .cached(cached.1) }
            return
        }
        let previous =
            entry.cached.flatMap {
                $0.0.stream == id && $0.0.selection == settings ? $0.1 : nil
            } ?? previousFits[cacheID].flatMap { $0.0 == id && $0.1 == settings ? $0.2 : nil }
        entry.request(
            request, on: queue,
            operation: { request in
                Result {
                    try store.reusableLinearFit(
                        streamID: request.stream, from: request.query.start, to: request.query.end, reusing: previous)
                }
            }, submitted: { self.countSubmission() },
            finished: { [weak self] result in
                if case .success(let snapshot) = result, snapshot.didRefit { self?.rawFitCount &+= 1 }
            }, completed: completed, failed: failed)
    }
    func fit(_ cacheID: UUID, stream: StreamID, key: QueryKey, settings: TimeSelection) -> LinearFit? {
        guard let cached = fits[cacheID]?.cached, cached.0.stream == stream,
            cached.0.selection == settings, cached.0.generation == fitGeneration,
            cached.0.query.count == key.count, cached.0.query.last == key.last,
            cached.1.contains(from: key.start, to: key.end)
        else { return nil }
        return cached.1.fit
    }
    func fitState(_ id: UUID) -> State<ReusableLinearFit> { fits[id]?.state ?? .idle }
    func isFitting(_ id: UUID) -> Bool {
        if case .loading = fitState(id) { return true }
        return false
    }

    func retryStatistics(_ id: StreamID) { statistics[id]?.retry(on: queue) { self.countSubmission() } }
    func retryDisplay(_ id: StreamID) { displays[id]?.retry(on: queue) { self.countSubmission() } }
    func retryDerived(_ id: StreamID) { derived[id]?.retry(on: queue) { self.countSubmission() } }
    func retryNearest(_ id: StreamID) { nearest[id]?.retry(on: queue) { self.countSubmission() } }
    func retryFit(_ id: UUID) { fits[id]?.retry(on: queue) { self.countSubmission() } }

    func invalidateFits() {
        fitGeneration &+= 1
        for slot in displays.values { slot.cancel() }
        for slot in statistics.values { slot.cancel() }
        for slot in nearest.values { slot.cancel() }
        for (id, slot) in fits {
            if let cached = slot.cached { previousFits[id] = (cached.0.stream, cached.0.selection, cached.1) }
            slot.cancel()
        }
        for slot in derived.values { slot.cancel() }
    }
    func cancelDisplay(_ id: StreamID) { displays[id]?.cancel() }
    func cancelNearest(_ id: StreamID) { nearest[id]?.cancel() }
    func cancelStatistics(_ id: StreamID) { statistics[id]?.cancel() }
    func cancelDerived(_ id: StreamID) { derived[id]?.cancel() }
    func cancelFit(_ id: UUID) { fits[id]?.cancel() }
    func suspend(streamIDs: Set<StreamID>, forecastIDs: Set<UUID>) {
        for id in streamIDs {
            displays[id]?.cancel()
            statistics[id]?.cancel()
            nearest[id]?.cancel()
            derived[id]?.cancel()
        }
        for id in forecastIDs {
            if let cached = fits[id]?.cached {
                previousFits[id] = (cached.0.stream, cached.0.selection, cached.1)
            }
            fits[id]?.cancel()
        }
    }
    func retain(_ ids: Set<StreamID>, forecastIDs: Set<UUID> = []) {
        hasRetentionPolicy = true
        retainedStreams = ids
        retainedForecasts = forecastIDs
        for (id, entry) in displays where !ids.contains(id) { entry.cancel() }
        for (id, entry) in statistics where !ids.contains(id) { entry.cancel() }
        for (id, entry) in nearest where !ids.contains(id) { entry.cancel() }
        for (id, entry) in derived where !ids.contains(id) { entry.cancel() }
        for (id, entry) in fits where !forecastIDs.contains(id) { entry.cancel() }
        pruneEvicted()
        previousFits = previousFits.filter { forecastIDs.contains($0.key) }
    }

    private func pruneEvicted() {
        guard hasRetentionPolicy else { return }
        displays = displays.filter { retainedStreams.contains($0.key) || $0.value.running }
        statistics = statistics.filter { retainedStreams.contains($0.key) || $0.value.running }
        nearest = nearest.filter { retainedStreams.contains($0.key) || $0.value.running }
        derived = derived.filter { retainedStreams.contains($0.key) || $0.value.running }
        fits = fits.filter { retainedForecasts.contains($0.key) || $0.value.running }
    }

    func suggestedInterval(_ id: StreamID, store: SampleStore) async -> Double? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: try? store.suggestedDerivedInterval(streamID: id)) }
        }
    }
}
