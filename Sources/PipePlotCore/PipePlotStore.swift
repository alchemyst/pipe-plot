import Foundation

public enum DomainError: Error, LocalizedError {
    case unknownSession, unknownChart, unknownStream, invalidColumnCount, duplicateName(String), streamBusy(String), noDestination, invalidMove, invalidAxisSettings, invalidSelection
    public var errorDescription: String? { switch self {
    case .unknownSession:return "unknown session"; case .unknownChart:return "unknown chart"; case .unknownStream:return "unknown stream"
    case .invalidColumnCount:return "sampler column count must be positive and match the provided names"
    case .duplicateName(let n):return "line name is ambiguous: \(n)"; case .streamBusy(let n):return "line is already attached: \(n)"
    case .noDestination:return "no destination chart is available"; case .invalidMove:return "cannot move a stream to its current chart"
    case .invalidAxisSettings:return "axis limits must be finite and minimum must be less than maximum";case .invalidSelection:return "selection start must be before its end" } }
}

/// Serialized, thread-safe domain boundary. Metadata is atomically saved beside the SQLite sample database.
public final class PipePlotStore {
    public let samples: SampleStore
    public private(set) var previouslyOpenSessionIDs:Set<SessionID> = []
    private let lock=NSRecursiveLock()
    private let metadataURL: URL
    private var sessions:[SessionRecord]=[]
    private var targetChartID:ChartID?
    private var nextNumber=1
    private var epoch:UInt64=0
    private var lastContinuation:Continuation?
    private var attachments:[AttachmentID:AttachmentRecord]=[:]
    private var owners:[StreamID:AttachmentID]=[:]
    private var undoStacks:[SessionID:[UndoRecord]]=[:]
    private var redoStacks:[SessionID:[UndoRecord]]=[:]
    private var recency:[ChartID]=[]
    private var restoreOpenSessionIDs:Set<SessionID>=[]
    private var terminationSnapshotTaken=false

    public init(databaseURL:URL) throws {
        samples=try SampleStore(databaseURL:databaseURL)
        metadataURL=databaseURL.appendingPathExtension("metadata.json")
        if FileManager.default.fileExists(atPath: metadataURL.path) {
            let state = try JSONDecoder().decode(PersistedState.self, from: Data(contentsOf: metadataURL))
            previouslyOpenSessionIDs=state.restoreOpenSessionIDs ?? Set(state.sessions.filter(\.isOpen).map(\.id))
            restoreOpenSessionIDs=previouslyOpenSessionIDs
            sessions=state.sessions; targetChartID=state.targetChartID; nextNumber=state.nextNumber; recency=state.recency
            for i in sessions.indices { sessions[i].isOpen=false; for c in sessions[i].charts.indices { for s in sessions[i].charts[c].streams.indices { sessions[i].charts[c].streams[s].state = .disconnected } } }
            for i in sessions.indices {
                for c in sessions[i].charts.indices {
                    let moved=sessions[i].charts[c].guides.filter{$0.orientation == .verticalTime}
                    sessions[i].charts[c].guides.removeAll{$0.orientation == .verticalTime}
                    for guide in moved where !sessions[i].timeGuides.contains(where:{$0.id==guide.id}) { sessions[i].timeGuides.append(guide) }
                }
            }
            for i in sessions.indices where sessions[i].timeline.clockStoppedAt == nil {
                sessions[i].timeline.clockStoppedAt = sessions[i].charts.flatMap(\.streams).compactMap(\.lastSampleAt).max() ?? Date()
            }
            if let targetChartID, findChart(targetChartID) == nil { self.targetChartID=nil }
            // SQLite is authoritative for raw history; repair metadata counts if a prior
            // process stopped after a committed sample transaction but before its snapshot write.
            for i in sessions.indices { for c in sessions[i].charts.indices { for j in sessions[i].charts[c].streams.indices {
                let id=sessions[i].charts[c].streams[j].id
                let bounds=try samples.bounds(streamID:id)
                sessions[i].charts[c].streams[j].sampleCount=try samples.count(streamID:id)
                sessions[i].charts[c].streams[j].firstSampleAt=bounds.first
                sessions[i].charts[c].streams[j].lastSampleAt=bounds.last
            } } }
        }
    }

    @discardableResult public func createSession(title:String?=nil) throws -> SessionSnapshot {
        lock.lock(); defer{lock.unlock()}
        let number=nextNumber; nextNumber += 1
        let session=SessionRecord(id:UUID(),number:number,title:title ?? "Session \(number)",charts:[],timeGuides:[],timeline:TimelineState(),isOpen:true,rejectedLineCount:0)
        sessions.append(session)
        let chart=ChartRecord(id:UUID(),title:"Chart 1",streams:[],settings:AxisSettings(),guides:[],isVisible:true)
        sessions[sessions.count-1].charts.append(chart); setTargetInternal(chart.id, invalidate:true)
        try persist(); return snapshotRecord(sessions[sessions.count-1])
    }
    @discardableResult public func createChart(in sessionID:SessionID, after chartID:ChartID?=nil) throws -> ChartSnapshot {
        lock.lock(); defer{lock.unlock()}; guard let si=sessionIndex(sessionID) else{throw DomainError.unknownSession}
        let id=UUID(); let title="Chart \(sessions[si].charts.count+1)"
        let chart=ChartRecord(id:id,title:title,streams:[],settings:AxisSettings(),guides:[],isVisible:true)
        let insertAt: Int
        if let chartID, let idx=sessions[si].charts.firstIndex(where:{$0.id==chartID}) { insertAt=idx+1 } else { insertAt=sessions[si].charts.count }
        sessions[si].charts.insert(chart,at:insertAt)
        record(.createdChart(sessionID:sessionID,chartID:id,index:insertAt),in:sessionID)
        setTargetInternal(id,invalidate:true); try persist()
        return chartSnapshot(chart, target:targetChartID)
    }
    @discardableResult public func setTarget(_ chartID:ChartID) throws -> ChartID {
        lock.lock(); defer{lock.unlock()}; guard let (si,ci)=findChartIndices(chartID), sessions[si].charts[ci].isVisible, sessions[si].isOpen else { throw DomainError.unknownChart }
        setTargetInternal(chartID,invalidate:true); try persist(); return chartID
    }
    public func currentTarget() -> ChartID? { lock.lock(); defer{lock.unlock()}; return targetChartID }
    public func sessionID(forNumber number:Int)->SessionID? { lock.lock(); defer{lock.unlock()}; return sessions.first{$0.number==number}?.id }
    public func snapshot(sessionID:SessionID) throws -> SessionSnapshot? { lock.lock(); defer{lock.unlock()}; guard let i=sessionIndex(sessionID) else{return nil}; return snapshotRecord(sessions[i]) }
    public func snapshot(number:Int) throws -> SessionSnapshot? { lock.lock(); defer{lock.unlock()}; guard let s=sessions.first(where:{$0.number==number}) else{return nil}; return snapshotRecord(s) }
    public func listSessions() throws -> [SessionSnapshot] { lock.lock(); defer{lock.unlock()}; return sessions.map(snapshotRecord) }
    public func renameSession(_ sessionID:SessionID,to title:String) throws { lock.lock();defer{lock.unlock()};guard let i=sessionIndex(sessionID) else{throw DomainError.unknownSession};let value=title.trimmingCharacters(in:.whitespacesAndNewlines);guard !value.isEmpty else{throw DomainError.invalidSelection};let old=sessions[i].title;guard old != value else{return};sessions[i].title=value;record(.sessionTitle(sessionID,old:old,new:value),in:sessionID);try persist() }
    /// Call from application-termination handling before per-window close callbacks run.
    public func recordTerminationOpenSessions(_ ids:Set<SessionID>) throws { lock.lock();defer{lock.unlock()};restoreOpenSessionIDs=ids;terminationSnapshotTaken=true;try persist() }

    @discardableResult public func registerSampler(intent:SinkIntent, sampler:SamplerIntent, owner:UUID=UUID()) throws -> ReadyReply {
        lock.lock(); defer{lock.unlock()}
        guard sampler.columnCount>0, sampler.requestedNames.map({$0.count==sampler.columnCount}) ?? true else { throw DomainError.invalidColumnCount }
        var chartID:ChartID; var explicitNames=sampler.requestedNames ?? []
        switch intent {
        case .newSession:
            let new=try createSession(title:nil); chartID=new.charts[0].id
        case .newChart:
            if targetChartID == nil || findChart(targetChartID!) == nil { let s=try createSession(); chartID=s.charts[0].id }
            else if let t=targetChartID, let si=findSessionIndex(forChart:t) { chartID=try createChart(in:sessions[si].id,after:t).id }
            else { throw DomainError.noDestination }
        case .session(let sid,let names):
            guard let si=sessionIndex(sid) else { throw DomainError.unknownSession }
            sessions[si].isOpen=true
            if sessions[si].charts.isEmpty { let c=ChartRecord(id:UUID(),title:"Chart 1",streams:[],settings:AxisSettings(),guides:[],isVisible:true); sessions[si].charts=[c] }
            chartID=sessions[si].charts.last!.id; if !names.isEmpty { explicitNames=names }
        case .chart(let cid,let names):
            guard let (chartSession,chartIndex)=findChartIndices(cid),sessions[chartSession].isOpen,sessions[chartSession].charts[chartIndex].isVisible else { throw DomainError.unknownChart }; chartID=cid; if !names.isEmpty { explicitNames=names }
        case .target,.fresh:
            if intent == .fresh { lastContinuation=nil }
            if !isUsableTarget(targetChartID) { let s=try createSession(); chartID=s.charts[0].id }
            else { chartID=targetChartID! }
        }
        guard let (si,ci)=findChartIndices(chartID) else { throw DomainError.unknownChart }
        if !explicitNames.isEmpty, explicitNames.count != sampler.columnCount { throw DomainError.invalidColumnCount }
        // Explicit name binding validates the entire group before mutating any ownership.
        var streamIDs:[StreamID]=[]; var descriptors:[StreamDescriptor]=[]; var continued=false
        if !explicitNames.isEmpty {
            guard Set(explicitNames).count == explicitNames.count else { throw DomainError.duplicateName(explicitNames.first(where:{name in explicitNames.filter{$0==name}.count>1}) ?? "") }
            var resolved:[StreamRecord]=[]
            for name in explicitNames {
                let matches=sessions[si].charts.flatMap(\.streams).filter{$0.name==name}
                if matches.count>1 { throw DomainError.duplicateName(name) }
                if let line=matches.first { if owners[line.id] != nil { throw DomainError.streamBusy(name) }; resolved.append(line) }
                else { resolved.append(StreamRecord(id:UUID(),name:name,state:.live,unitHint:sampler.unitHint)) }
            }
            for var line in resolved { line.state = .live; if line.unitHint == nil { line.unitHint=sampler.unitHint }; streamIDs.append(line.id); descriptors.append(descriptor(line)); if streamLocation(line.id)==nil { sessions[si].charts[ci].streams.append(line) } else if let (li,lj)=streamIndices(line.id) { sessions[li].charts[lj].streams[sessions[li].charts[lj].streams.firstIndex{$0.id==line.id}!].state = .live } }
        } else if intent == .target, let previous=lastContinuation, previous.epoch==epoch, previous.chartID==chartID, previous.streamIDs.count==sampler.columnCount, !previous.active {
            streamIDs=previous.streamIDs; continued=true
            for id in streamIDs { guard let (li,lj)=streamIndices(id) else { throw DomainError.unknownStream }; sessions[li].charts[lj].streams[sessions[li].charts[lj].streams.firstIndex{$0.id==id}!].state = .live; descriptors.append(descriptor(sessions[li].charts[lj].streams.first{$0.id==id}!)) }
        } else {
            for col in 0..<sampler.columnCount { let name=(sampler.requestedNames?.indices.contains(col) == true ? sampler.requestedNames![col] : nextDefaultLineName(sessionIndex:si)); let line=StreamRecord(id:UUID(),name:name,state:.live,unitHint:sampler.unitHint); sessions[si].charts[ci].streams.append(line); streamIDs.append(line.id); descriptors.append(descriptor(line)) }
        }
        let aid=UUID(); let attach=AttachmentRecord(id:aid,owner:owner,sessionID:sessions[si].id,chartID:chartID,streamIDs:streamIDs,active:true)
        attachments[aid]=attach; for id in streamIDs { owners[id]=aid }
        sessions[si].timeline.clockStoppedAt = nil
        if intent == .target { lastContinuation=Continuation(epoch:epoch,chartID:chartID,streamIDs:streamIDs,active:true) }
        touch(chartID); try persist()
        return ReadyReply(sessionID:sessions[si].id,chartID:chartID,attachmentID:aid,streams:descriptors,continued:continued)
    }

    @discardableResult public func append(_ row:SampleRow,to attachmentID:AttachmentID) throws -> [UInt64] {
        lock.lock(); defer{lock.unlock()}; guard let attachment=attachments[attachmentID], attachment.active else { throw DomainError.unknownStream }
        guard row.values.count==attachment.streamIDs.count, row.values.allSatisfy(\.isFinite) else { throw DomainError.invalidColumnCount }
        let seqs=try samples.append(values:row.values,timestamp:row.timestamp,to:attachment.streamIDs,segmentID:attachmentID.uuidString.lowercased())
        for id in attachment.streamIDs { if let (si,ci)=streamIndices(id), let idx=sessions[si].charts[ci].streams.firstIndex(where:{$0.id==id}) { var s=sessions[si].charts[ci].streams[idx]; s.sampleCount += 1; if s.firstSampleAt == nil {s.firstSampleAt=row.timestamp}; s.lastSampleAt=row.timestamp; s.state = .live; sessions[si].charts[ci].streams[idx]=s } }
        try persist(); return seqs
    }
    public func finishAttachment(_ attachmentID:AttachmentID, reason:FinishReason) throws {
        lock.lock(); defer{lock.unlock()}; guard var a=attachments[attachmentID], a.active else{return}; a.active=false; attachments[attachmentID]=a
        for id in a.streamIDs { owners.removeValue(forKey:id); if let (si,ci)=streamIndices(id),let ix=sessions[si].charts[ci].streams.firstIndex(where:{$0.id==id}) { sessions[si].charts[ci].streams[ix].state = reason == .error ? .errored : (reason == .clientDisconnected ? .disconnected : .ended) } }
        if lastContinuation?.streamIDs == a.streamIDs { lastContinuation?.active=false }
        if !attachments.values.contains(where: { $0.sessionID == a.sessionID && $0.active }), let i = sessionIndex(a.sessionID) {
            sessions[i].timeline.clockStoppedAt = Date()
        }
        try persist()
    }
    public func recordRejectedInput(_ rejection:InputRejection,to attachmentID:AttachmentID) throws {
        lock.lock();defer{lock.unlock()};guard let attachment=attachments[attachmentID],let i=sessionIndex(attachment.sessionID) else{throw DomainError.unknownStream}
        sessions[i].rejectedLineCount += 1;try persist()
    }

    public func moveStream(_ streamID:StreamID,to chartID:ChartID) throws {
        lock.lock(); defer{lock.unlock()}; guard let (si,ci)=findChartIndices(chartID), let (oi,oj)=streamIndices(streamID) else { throw DomainError.unknownStream }
        guard si == oi, !(si==oi && ci==oj), sessions[si].charts[ci].isVisible else { throw DomainError.invalidMove }
        let sourceWasVisible=sessions[oi].charts[oj].isVisible, destinationWasVisible=sessions[si].charts[ci].isVisible
        let stream=sessions[oi].charts[oj].streams.remove(at:sessions[oi].charts[oj].streams.firstIndex{$0.id==streamID}!)
        sessions[si].charts[ci].streams.append(stream)
        if sessions[oi].charts[oj].streams.isEmpty { sessions[oi].charts[oj].isVisible=false; if targetChartID==sessions[oi].charts[oj].id { fallbackTarget() } }
        record(.movedStream(streamID,from:sessions[oi].charts[oj].id,to:chartID,fromWasVisible:sourceWasVisible,toWasVisible:destinationWasVisible,fromNowVisible:sessions[oi].charts[oj].isVisible,toNowVisible:sessions[si].charts[ci].isVisible),in:sessions[oi].id)
        try persist()
    }
    /// Associates an active sampler group with older disconnected lines. Histories stay in
    /// SQLite and all columns are remapped in one transaction, so undo can restore routing.
    public func reassociateStreams(_ sourceStreamIDs:[StreamID],to destinationStreamIDs:[StreamID]) throws {
        lock.lock();defer{lock.unlock()}
        guard !sourceStreamIDs.isEmpty,sourceStreamIDs.count==destinationStreamIDs.count,
              Set(sourceStreamIDs).count==sourceStreamIDs.count,Set(destinationStreamIDs).count==destinationStreamIDs.count,
              Set(sourceStreamIDs).isDisjoint(with:destinationStreamIDs) else { throw DomainError.invalidColumnCount }
        let locations=sourceStreamIDs.compactMap(streamIndices)
        guard locations.count==sourceStreamIDs.count,Set(locations.map{$0.0}).count==1 else { throw DomainError.unknownStream }
        let sessionIndex=locations[0].0
        guard let firstDest=destinationStreamIDs.first.flatMap(streamIndices),firstDest.0==sessionIndex else { throw DomainError.invalidMove }
        var attachmentID:AttachmentID?
        for id in sourceStreamIDs {
            guard let aid=owners[id],attachments[aid]?.active==true else { throw DomainError.streamBusy(findStream(id)?.name ?? id.uuidString) }
            if let attachmentID, attachmentID != aid { throw DomainError.invalidMove }
            attachmentID=aid
        }
        guard let aid=attachmentID, let attachment=attachments[aid],Set(attachment.streamIDs)==Set(sourceStreamIDs),attachment.streamIDs.count==sourceStreamIDs.count else { throw DomainError.invalidMove }
        for id in destinationStreamIDs {
            guard owners[id]==nil,let (di,dj)=streamIndices(id),sessions[di].isOpen,sessions[di].charts[dj].isVisible else { throw DomainError.streamBusy(findStream(id)?.name ?? id.uuidString) }
        }
        let destLocations=destinationStreamIDs.compactMap(streamIndices)
        guard Set(destLocations.map{$0.0})==Set([sessionIndex]) else { throw DomainError.invalidMove }
        var items:[ReassociationItem]=[]
        for (source,dest) in zip(sourceStreamIDs,destinationStreamIDs) {
            guard let (si,ci)=streamIndices(source),let (di,dj)=streamIndices(dest),si==di,
                  let sourceIndex=sessions[si].charts[ci].streams.firstIndex(where:{$0.id==source}),
                  let _=sessions[di].charts[dj].streams.firstIndex(where:{$0.id==dest}) else { throw DomainError.unknownStream }
            var segmentIDs=try samples.segmentIDs(streamID:source)
            let liveSegment=aid.uuidString.lowercased()
            if !segmentIDs.contains(liveSegment) { segmentIDs.append(liveSegment) }
            items.append(ReassociationItem(sourceID:source,destinationID:dest,segmentIDs:segmentIDs,
                sourceRecord:sessions[si].charts[ci].streams[sourceIndex],sourceChartID:sessions[si].charts[ci].id,
                sourceChartIndex:ci,sourceStreamIndex:sourceIndex,destinationChartID:sessions[di].charts[dj].id))
        }
        var visibility:[ChartID:Bool]=[:]
        for (si,ci) in locations { let chart=sessions[si].charts[ci];visibility[chart.id]=chart.isVisible }
        let action=ReassociationAction(sessionID:sessions[sessionIndex].id,attachmentID:aid,items:items,chartVisibility:visibility)
        try applyReassociation(action,reverse:false)
        record(.reassociation(action),in:sessions[sessionIndex].id)
        try persist()
    }
    public func renameStream(_ streamID:StreamID,to name:String) throws {
        lock.lock(); defer{lock.unlock()}; guard let (si,ci)=streamIndices(streamID),let ix=sessions[si].charts[ci].streams.firstIndex(where:{$0.id==streamID}) else{throw DomainError.unknownStream}
        let old=sessions[si].charts[ci].streams[ix].name;guard old != name else{return}
        if sessions[si].charts.flatMap(\.streams).contains(where:{$0.id != streamID && $0.name==name}) { throw DomainError.duplicateName(name) }
        sessions[si].charts[ci].streams[ix].name=name
        record(.renamedStream(streamID,old:old,new:name),in:sessions[si].id); try persist()
    }
    public func updateSettings(_ settings:AxisSettings,chartID:ChartID) throws { lock.lock();defer{lock.unlock()}; guard let(si,ci)=findChartIndices(chartID) else{throw DomainError.unknownChart};if case .fixed(let min,let max)=settings.yScale,(!min.isFinite || !max.isFinite || min>=max){throw DomainError.invalidAxisSettings};let old=sessions[si].charts[ci].settings;guard old != settings else{return};sessions[si].charts[ci].settings=settings; record(.settings(chartID,old:old,new:settings),in:sessions[si].id); try persist() }
    public func upsertGuide(_ guide:Guide,chartID:ChartID) throws {
        lock.lock();defer{lock.unlock()};guard guide.value.isFinite else{throw DomainError.invalidAxisSettings};guard let(si,ci)=findChartIndices(chartID) else{throw DomainError.unknownChart}
        if guide.orientation == .verticalTime { try upsertTimeGuide(guide,sessionID:sessions[si].id);return }
        let old=sessions[si].charts[ci].guides.first{$0.id==guide.id};guard old != guide else{return}
        if let i=sessions[si].charts[ci].guides.firstIndex(where:{$0.id==guide.id}) {sessions[si].charts[ci].guides[i]=guide} else {sessions[si].charts[ci].guides.append(guide)}
        record(.guide(chartID,id:guide.id,old:old,new:guide),in:sessions[si].id);try persist()
    }
    public func upsertTimeGuide(_ guide:Guide,sessionID:SessionID) throws {
        lock.lock();defer{lock.unlock()};guard guide.orientation == .verticalTime,guide.value.isFinite else{throw DomainError.invalidAxisSettings};guard let si=sessionIndex(sessionID) else{throw DomainError.unknownSession}
        let old=sessions[si].timeGuides.first{$0.id==guide.id};guard old != guide else{return}
        if let i=sessions[si].timeGuides.firstIndex(where:{$0.id==guide.id}){sessions[si].timeGuides[i]=guide}else{sessions[si].timeGuides.append(guide)}
        record(.timeGuide(sessionID,id:guide.id,old:old,new:guide),in:sessionID);try persist()
    }
    public func removeGuide(_ guideID:UUID,chartID:ChartID) throws {
        lock.lock();defer{lock.unlock()};guard let(si,ci)=findChartIndices(chartID) else{throw DomainError.unknownChart}
        if let i=sessions[si].charts[ci].guides.firstIndex(where:{$0.id==guideID}) {let old=sessions[si].charts[ci].guides.remove(at:i);record(.guide(chartID,id:guideID,old:old,new:nil),in:sessions[si].id);try persist();return}
        if sessions[si].timeGuides.contains(where:{$0.id==guideID}) {try removeTimeGuide(guideID,sessionID:sessions[si].id)}
    }
    public func removeTimeGuide(_ guideID:UUID,sessionID:SessionID) throws {
        lock.lock();defer{lock.unlock()};guard let si=sessionIndex(sessionID) else{throw DomainError.unknownSession};guard let i=sessions[si].timeGuides.firstIndex(where:{$0.id==guideID}) else{return};let old=sessions[si].timeGuides.remove(at:i);record(.timeGuide(sessionID,id:guideID,old:old,new:nil),in:sessionID);try persist()
    }
    public func updateTimeline(_ timeline:TimelineState,sessionID:SessionID) throws { lock.lock();defer{lock.unlock()};guard let i=sessionIndex(sessionID) else{throw DomainError.unknownSession};var value=timeline;value.selection=sessions[i].timeline.selection;value.forecast=sessions[i].timeline.forecast;value.clockStoppedAt=sessions[i].timeline.clockStoppedAt;sessions[i].timeline=value;try persist() }
    public func setSelection(_ selection:TimeSelection?,sessionID:SessionID) throws { lock.lock();defer{lock.unlock()};guard let i=sessionIndex(sessionID) else{throw DomainError.unknownSession};if let s=selection { if s.start>s.end {throw DomainError.invalidSelection};if case .bothFollowNow(let duration)=s.mode,(!duration.isFinite || duration<=0){throw DomainError.invalidSelection} };let old=sessions[i].timeline.selection;guard old != selection else{return};sessions[i].timeline.selection=selection;record(.selection(sessionID,old:old,new:selection),in:sessionID);try persist() }
    public func setForecast(_ forecast:ForecastConfiguration?,sessionID:SessionID) throws { lock.lock();defer{lock.unlock()};guard let i=sessionIndex(sessionID) else{throw DomainError.unknownSession};if let f=forecast {guard f.selection.start<=f.selection.end, sessions[i].charts.flatMap(\.streams).contains(where:{$0.id==f.streamID}),sessions[i].charts.contains(where:{$0.guides.contains(where:{$0.id==f.guideID && $0.orientation == .horizontalValue})}) else {throw DomainError.invalidSelection}};let old=sessions[i].timeline.forecast;guard old != forecast else{return};sessions[i].timeline.forecast=forecast;record(.forecast(sessionID,old:old,new:forecast),in:sessionID);try persist() }
    public func setSessionOpen(_ open:Bool,sessionID:SessionID) throws { lock.lock();defer{lock.unlock()};guard let i=sessionIndex(sessionID) else{throw DomainError.unknownSession};sessions[i].isOpen=open;if !open { let active=attachments.values.filter{$0.sessionID==sessionID && $0.active};for a in active { try finishAttachment(a.id,reason:.sessionClosed) }; if let t=targetChartID, sessions[i].charts.contains(where:{$0.id==t}) { targetChartID=nil; fallbackTarget() } };try persist() }

    public func undoActionName(sessionID: SessionID) -> String? {
        lock.lock(); defer { lock.unlock() }
        return undoStacks[sessionID]?.last?.title
    }
    public func redoActionName(sessionID: SessionID) -> String? {
        lock.lock(); defer { lock.unlock() }
        return redoStacks[sessionID]?.last?.title
    }

    public func undo(sessionID:SessionID) throws -> Bool { try replay(sessionID:sessionID,undo:true) }
    public func redo(sessionID:SessionID) throws -> Bool { try replay(sessionID:sessionID,undo:false) }

    private func replay(sessionID:SessionID,undo:Bool) throws -> Bool {
        lock.lock();defer{lock.unlock()};guard let si=sessionIndex(sessionID) else{throw DomainError.unknownSession}
        var source=undo ? undoStacks[sessionID,default:[]] : redoStacks[sessionID,default:[]];guard var action=source.popLast() else{return false}
        if undo { undoStacks[sessionID]=source } else { redoStacks[sessionID]=source }
        switch action {
        case .createdChart(let sid,let cid,let index):
            guard let (chartSession,ci)=findChartIndices(cid),chartSession==si,index>0 else { return restoreAction(action,sessionID:sessionID,undo:undo) }
            let destinationIndex=index-1
            guard destinationIndex < sessions[si].charts.count else { return restoreAction(action,sessionID:sessionID,undo:undo) }
            let chart=sessions[si].charts.remove(at:ci)
            let moved=chart.streams
            sessions[si].charts[destinationIndex].streams.append(contentsOf:moved)
            if targetChartID==cid { fallbackTarget() }
            action = .restoredChart(sessionID:sid,chart:chart,index:index,streamIDs:moved.map(\.id))
        case .restoredChart(let sid,let chartRecord,let index,let ids):
            var chart=chartRecord; chart.streams=[]
            for id in ids { if let location=streamIndices(id),location.0==si,let stream=removeStream(id,at:location) { chart.streams.append(stream) } }
            sessions[si].charts.insert(chart,at:min(index,sessions[si].charts.count))
            action = .createdChart(sessionID:sid,chartID:chart.id,index:index)
        case .movedStream(let id,let from,let to,let fromWasVisible,let toWasVisible,let fromNowVisible,let toNowVisible):
            if let destination=findChartIndices(undo ? from : to),let sourceChart=findChartIndices(undo ? to : from),let stream=removeStream(id,at:sourceChart) {
                sessions[destination.0].charts[destination.1].streams.append(stream)
                if let (fsi,fci)=findChartIndices(from),let (tsi,tci)=findChartIndices(to) {
                    sessions[fsi].charts[fci].isVisible=undo ? fromWasVisible:fromNowVisible
                    sessions[tsi].charts[tci].isVisible=undo ? toWasVisible:toNowVisible
                }
            }
        case .renamedStream(let id,let old,let new): if let (a,b)=streamIndices(id),let ix=sessions[a].charts[b].streams.firstIndex(where:{$0.id==id}) { sessions[a].charts[b].streams[ix].name=undo ? old:new }
        case .settings(let cid,let old,let new): if let(a,b)=findChartIndices(cid){sessions[a].charts[b].settings=undo ? old:new}
        case .guide(let cid,let gid,let old,let new): if let(a,b)=findChartIndices(cid){sessions[a].charts[b].guides.removeAll{$0.id==gid};if let value=undo ? old:new{sessions[a].charts[b].guides.append(value)}}
        case .timeGuide(let sid,let gid,let old,let new): if let i=sessionIndex(sid){sessions[i].timeGuides.removeAll{$0.id==gid};if let value=undo ? old:new{sessions[i].timeGuides.append(value)}}
        case .selection(let sid,let old,let new): if let i=sessionIndex(sid){sessions[i].timeline.selection=undo ? old:new}
        case .forecast(let sid,let old,let new): if let i=sessionIndex(sid){sessions[i].timeline.forecast=undo ? old:new}
        case .sessionTitle(let sid,let old,let new): if let i=sessionIndex(sid){sessions[i].title=undo ? old:new}
        case .reassociation(let association): do { try applyReassociation(association,reverse:undo) } catch { _ = restoreAction(.reassociation(association),sessionID:sessionID,undo:undo); throw error }
        }
        if undo { redoStacks[sessionID,default:[]].append(action) } else { undoStacks[sessionID,default:[]].append(action) }
        if let targetChartID,findChartIndices(targetChartID).map({sessions[$0.0].charts[$0.1].isVisible && sessions[$0.0].isOpen}) != true { fallbackTarget() }
        try persist();return true
    }

    private func restoreAction(_ action:UndoRecord,sessionID:SessionID,undo:Bool)->Bool { if undo {undoStacks[sessionID,default:[]].append(action)} else {redoStacks[sessionID,default:[]].append(action)};return false }

    private func applyReassociation(_ action:ReassociationAction,reverse:Bool) throws {
        let active=attachments[action.attachmentID]?.active == true
        let transfers=action.items.map { item in
            SegmentTransfer(segmentIDs:item.segmentIDs,from:reverse ? item.destinationID:item.sourceID,to:reverse ? item.sourceID:item.destinationID)
        }
        // Do not steal a line if another explicit attachment acquired it after the edit.
        let expectedOwned=reverse ? action.items.map(\.destinationID):action.items.map(\.sourceID)
        let targetIDs=reverse ? action.items.map(\.sourceID):action.items.map(\.destinationID)
        for id in targetIDs where owners[id] != nil && owners[id] != action.attachmentID {
            throw DomainError.streamBusy(findStream(id)?.name ?? id.uuidString)
        }
        if active {
            for id in expectedOwned where owners[id] != action.attachmentID { throw DomainError.streamBusy(findStream(id)?.name ?? id.uuidString) }
        }
        try samples.reassignSegments(transfers)
        let sourceIDs=action.items.map(\.sourceID), destinationIDs=action.items.map(\.destinationID)
        if reverse {
            for id in destinationIDs { owners.removeValue(forKey:id) }
            for (item,sourceID) in zip(action.items,sourceIDs) {
                if let (si,ci)=findChartIndices(item.sourceChartID) {
                    var record=item.sourceRecord
                    let bounds=try samples.bounds(streamID:sourceID);record.sampleCount=try samples.count(streamID:sourceID);record.firstSampleAt=bounds.first;record.lastSampleAt=bounds.last
                    record.state=active ? .live : .ended
                    sessions[si].charts[ci].streams.insert(record,at:min(item.sourceStreamIndex,sessions[si].charts[ci].streams.count))
                }
                if active { owners[sourceID]=action.attachmentID }
            }
            for (chartID,visible) in action.chartVisibility { if let (si,ci)=findChartIndices(chartID){sessions[si].charts[ci].isVisible=visible} }
            if var attachment=attachments[action.attachmentID] { attachment.streamIDs=sourceIDs;attachments[action.attachmentID]=attachment }
        } else {
            for sourceID in sourceIDs {
                if let (si,ci)=streamIndices(sourceID),let index=sessions[si].charts[ci].streams.firstIndex(where:{$0.id==sourceID}) { sessions[si].charts[ci].streams.remove(at:index) }
                owners.removeValue(forKey:sourceID)
            }
            for (chartID,_) in action.chartVisibility { if let (si,ci)=findChartIndices(chartID),sessions[si].charts[ci].streams.isEmpty { sessions[si].charts[ci].isVisible=false;if targetChartID==chartID{fallbackTarget()} } }
            for destinationID in destinationIDs {
                if active { owners[destinationID]=action.attachmentID }
                if let (si,ci)=streamIndices(destinationID),let ix=sessions[si].charts[ci].streams.firstIndex(where:{$0.id==destinationID}) {
                    let bounds=try samples.bounds(streamID:destinationID);sessions[si].charts[ci].streams[ix].sampleCount=try samples.count(streamID:destinationID);sessions[si].charts[ci].streams[ix].firstSampleAt=bounds.first;sessions[si].charts[ci].streams[ix].lastSampleAt=bounds.last;sessions[si].charts[ci].streams[ix].state=active ? .live:.disconnected
                }
            }
            if var attachment=attachments[action.attachmentID] { attachment.streamIDs=destinationIDs;attachments[action.attachmentID]=attachment }
        }
        if lastContinuation?.streamIDs == expectedOwned { lastContinuation?.streamIDs=targetIDs }
    }

    private func record(_ action:UndoRecord,in sessionID:SessionID){var stack=undoStacks[sessionID,default:[]];stack.append(action);if stack.count>200{stack.removeFirst(stack.count-200)};undoStacks[sessionID]=stack;redoStacks[sessionID]=[]}
    private func setTargetInternal(_ id:ChartID,invalidate:Bool){targetChartID=id;touch(id);if invalidate{epoch &+= 1;lastContinuation=nil}}
    private func isUsableTarget(_ id:ChartID?)->Bool{guard let id,let(i,j)=findChartIndices(id) else{return false};return sessions[i].isOpen && sessions[i].charts[j].isVisible}
    private func touch(_ id:ChartID){recency.removeAll{$0==id};recency.insert(id,at:0)}
    private func fallbackTarget(){targetChartID=recency.first(where:{id in guard let(i,j)=findChartIndices(id) else{return false};return sessions[i].isOpen && sessions[i].charts[j].isVisible});epoch &+= 1;lastContinuation=nil}
    private func previousChartIndex(_ sid:SessionID,_ cid:ChartID)->Int?{guard let si=sessionIndex(sid),let ci=sessions[si].charts.firstIndex(where:{$0.id==cid}),ci>0 else{return nil};return ci-1}
    private func removeStream(_ id:StreamID,at pair:(Int,Int))->StreamRecord?{let (a,b)=pair;guard let ix=sessions[a].charts[b].streams.firstIndex(where:{$0.id==id}) else{return nil};return sessions[a].charts[b].streams.remove(at:ix)}
    private func sessionIndex(_ id:SessionID)->Int?{sessions.firstIndex{$0.id==id}}
    private func findChart(_ id:ChartID?)->ChartRecord?{guard let id else{return nil};for s in sessions{if let c=s.charts.first(where:{$0.id==id}){return c}};return nil}
    private func findChartIndices(_ id:ChartID)->(Int,Int)?{for i in sessions.indices{if let j=sessions[i].charts.firstIndex(where:{$0.id==id}){return(i,j)}};return nil}
    private func findSessionIndex(forChart id:ChartID)->Int?{sessions.firstIndex{$0.charts.contains(where:{$0.id==id})}}
    private func streamIndices(_ id:StreamID)->(Int,Int)?{for i in sessions.indices{for j in sessions[i].charts.indices where sessions[i].charts[j].streams.contains(where:{$0.id==id}){return(i,j)}};return nil}
    private func streamLocation(_ id:StreamID)->(Int,Int)?{streamIndices(id)}
    private func descriptor(_ s:StreamRecord)->StreamDescriptor{StreamDescriptor(id:s.id,name:s.name,state:s.state,sampleCount:s.sampleCount,firstSampleAt:s.firstSampleAt,lastSampleAt:s.lastSampleAt,unitHint:s.unitHint)}
    private func findStream(_ id:StreamID)->StreamRecord?{guard let (i,j)=streamIndices(id) else{return nil};return sessions[i].charts[j].streams.first{$0.id==id}}
    private func nextDefaultLineName(sessionIndex:Int)->String { let existing=Set(sessions[sessionIndex].charts.flatMap(\.streams).map(\.name));var n=1;while existing.contains("Line \(n)"){n+=1};return "Line \(n)" }
    private func chartSnapshot(_ c:ChartRecord,target:ChartID?)->ChartSnapshot{ChartSnapshot(id:c.id,title:c.title,streams:c.streams.map(descriptor),settings:c.settings,guides:c.guides,isTarget:c.id==target,isVisible:c.isVisible)}
    private func snapshotRecord(_ s:SessionRecord)->SessionSnapshot{SessionSnapshot(id:s.id,number:s.number,title:s.title,charts:s.charts.map{chartSnapshot($0,target:targetChartID)},timeGuides:s.timeGuides,timeline:s.timeline,isOpen:s.isOpen,rejectedLineCount:s.rejectedLineCount)}
    private func persist() throws { if !terminationSnapshotTaken { restoreOpenSessionIDs=Set(sessions.filter(\.isOpen).map(\.id)) }; let state=PersistedState(sessions:sessions,targetChartID:targetChartID,nextNumber:nextNumber,recency:recency,restoreOpenSessionIDs:restoreOpenSessionIDs);let data=try JSONEncoder().encode(state);try data.write(to:metadataURL,options:.atomic) }
}

private struct Continuation {var epoch:UInt64;var chartID:ChartID;var streamIDs:[StreamID];var active:Bool}
private struct AttachmentRecord {var id:AttachmentID;var owner:UUID;var sessionID:SessionID;var chartID:ChartID;var streamIDs:[StreamID];var active:Bool}
private struct SessionRecord:Codable {var id:SessionID;var number:Int;var title:String;var charts:[ChartRecord];var timeGuides:[Guide];var timeline:TimelineState;var isOpen:Bool;var rejectedLineCount:Int}
private struct ChartRecord:Codable {var id:ChartID;var title:String;var streams:[StreamRecord];var settings:AxisSettings;var guides:[Guide];var isVisible:Bool}
private struct StreamRecord:Codable {var id:StreamID;var name:String;var state:StreamState;var sampleCount:Int64=0;var firstSampleAt:Date?;var lastSampleAt:Date?;var unitHint:String?}
private struct PersistedState:Codable {var sessions:[SessionRecord];var targetChartID:ChartID?;var nextNumber:Int;var recency:[ChartID];var restoreOpenSessionIDs:Set<SessionID>?}
private struct ReassociationItem {var sourceID:StreamID;var destinationID:StreamID;var segmentIDs:[String];var sourceRecord:StreamRecord;var sourceChartID:ChartID;var sourceChartIndex:Int;var sourceStreamIndex:Int;var destinationChartID:ChartID}
private struct ReassociationAction {var sessionID:SessionID;var attachmentID:AttachmentID;var items:[ReassociationItem];var chartVisibility:[ChartID:Bool]}
private enum UndoRecord {case createdChart(sessionID:SessionID,chartID:ChartID,index:Int),restoredChart(sessionID:SessionID,chart:ChartRecord,index:Int,streamIDs:[StreamID]),movedStream(StreamID,from:ChartID,to:ChartID,fromWasVisible:Bool,toWasVisible:Bool,fromNowVisible:Bool,toNowVisible:Bool),renamedStream(StreamID,old:String,new:String),sessionTitle(SessionID,old:String,new:String),settings(ChartID,old:AxisSettings,new:AxisSettings),guide(ChartID,id:UUID,old:Guide?,new:Guide?),timeGuide(SessionID,id:UUID,old:Guide?,new:Guide?),selection(SessionID,old:TimeSelection?,new:TimeSelection?),forecast(SessionID,old:ForecastConfiguration?,new:ForecastConfiguration?),reassociation(ReassociationAction)}

private extension SessionRecord {
    enum CodingKeys: String, CodingKey { case id, number, title, charts, timeGuides, timeline, isOpen, rejectedLineCount }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(SessionID.self, forKey: .id)
        number = try c.decode(Int.self, forKey: .number)
        title = try c.decode(String.self, forKey: .title)
        charts = try c.decode([ChartRecord].self, forKey: .charts)
        timeGuides = try c.decodeIfPresent([Guide].self, forKey: .timeGuides) ?? []
        timeline = try c.decode(TimelineState.self, forKey: .timeline)
        isOpen = try c.decode(Bool.self, forKey: .isOpen)
        rejectedLineCount = try c.decodeIfPresent(Int.self, forKey: .rejectedLineCount) ?? 0
    }
}

private extension UndoRecord {
    var title: String {
        switch self {
        case .createdChart, .restoredChart: return "Create Chart"
        case .movedStream: return "Move Stream"
        case .renamedStream: return "Rename Stream"
        case .sessionTitle: return "Rename Session"
        case .settings: return "Axis Settings"
        case .guide, .timeGuide: return "Guide Edit"
        case .selection: return "Selection"
        case .forecast: return "Linear Forecast"
        case .reassociation: return "Reassociate Streams"
        }
    }
}
