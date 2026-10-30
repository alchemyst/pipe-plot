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
    private var attachmentOrder:[AttachmentID]=[]
    private var owners:[StreamID:AttachmentID]=[:]
    private var undoStacks:[SessionID:[UndoRecord]]=[:]
    private var redoStacks:[SessionID:[UndoRecord]]=[:]
    private var recency:[ChartID]=[]
    private var restoreOpenSessionIDs:Set<SessionID>=[]
    private var terminationSnapshotTaken=false
    private var suppressPersistDepth=0
    private var committedState:MemoryState?

    public init(databaseURL:URL) throws {
        samples=try SampleStore(databaseURL:databaseURL)
        metadataURL=databaseURL.appendingPathExtension("metadata.json")
        if FileManager.default.fileExists(atPath: metadataURL.path) {
            let state = try JSONDecoder().decode(PersistedState.self, from: Data(contentsOf: metadataURL))
            previouslyOpenSessionIDs=(state.restoreOpenSessionIDs ?? Set(state.sessions.filter(\.isOpen).map(\.id))).subtracting(state.sessions.filter(\.isDeleted).map(\.id))
            restoreOpenSessionIDs=previouslyOpenSessionIDs
            sessions=state.sessions; targetChartID=state.targetChartID; nextNumber=state.nextNumber; recency=state.recency
            for i in sessions.indices { sessions[i].isOpen=false; for c in sessions[i].charts.indices { for s in sessions[i].charts[c].streams.indices where sessions[i].charts[c].streams[s].state == .live || sessions[i].charts[c].streams[s].state == .quiet { sessions[i].charts[c].streams[s].state = .disconnected } } }
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
        committedState=memoryState()
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
    public func renameChart(_ chartID:ChartID,to title:String)throws {lock.lock();defer{lock.unlock()};guard let(si,ci)=findChartIndices(chartID)else{throw DomainError.unknownChart};let value=title.trimmingCharacters(in:.whitespacesAndNewlines);guard !value.isEmpty else{throw DomainError.invalidSelection};let old=sessions[si].charts[ci].title;guard old != value else{return};sessions[si].charts[ci].title=value;record(.chartTitle(chartID,old:old,new:value),in:sessions[si].id);try persist()}
    public func reorderChart(_ chartID:ChartID,to index:Int)throws {lock.lock();defer{lock.unlock()};guard let(si,ci)=findChartIndices(chartID),index>=0,index<sessions[si].charts.count else{throw DomainError.unknownChart};guard ci != index else{return};let chart=sessions[si].charts.remove(at:ci);sessions[si].charts.insert(chart,at:index);record(.chartReordered(chartID,from:ci,to:index),in:sessions[si].id);try persist()}
    public func deleteChart(_ chartID:ChartID)throws {lock.lock();defer{lock.unlock()};guard let(si,ci)=findChartIndices(chartID),sessions[si].charts.count>1,sessions[si].charts[ci].isVisible else{throw DomainError.invalidMove};sessions[si].charts[ci].isVisible=false;record(.chartVisibility(chartID,old:true,new:false),in:sessions[si].id);if targetChartID==chartID{fallbackTarget()};try persist()}
    public func restoreChart(_ chartID:ChartID)throws {lock.lock();defer{lock.unlock()};guard let(si,ci)=findChartIndices(chartID),!sessions[si].charts[ci].isVisible else{throw DomainError.unknownChart};sessions[si].charts[ci].isVisible=true;record(.chartVisibility(chartID,old:false,new:true),in:sessions[si].id);try persist()}
    @discardableResult public func setTarget(_ chartID:ChartID) throws -> ChartID {
        lock.lock(); defer{lock.unlock()}; guard let (si,ci)=findChartIndices(chartID), !sessions[si].isDeleted,sessions[si].charts[ci].isVisible, sessions[si].isOpen else { throw DomainError.unknownChart }
        if targetChartID==chartID {touch(chartID);try persist();return chartID}
        setTargetInternal(chartID,invalidate:true); try persist(); return chartID
    }
    public func currentTarget() -> ChartID? { lock.lock(); defer{lock.unlock()}; return targetChartID }
    public func samplerGroup(containing streamID:StreamID)->[StreamID]? {lock.lock();defer{lock.unlock()};let aid=owners[streamID] ?? attachmentOrder.reversed().first(where:{attachments[$0]?.streamIDs.contains(streamID)==true});guard let aid,let a=attachments[aid]else{return nil};return a.streamIDs}
    var retainedAttachmentCount:Int {lock.lock();defer{lock.unlock()};return attachments.count}
    public func sessionID(forNumber number:Int)->SessionID? { lock.lock(); defer{lock.unlock()}; return sessions.first{$0.number==number}?.id }
    public func snapshot(sessionID:SessionID) throws -> SessionSnapshot? { lock.lock(); defer{lock.unlock()}; guard let i=sessionIndex(sessionID) else{return nil}; return snapshotRecord(sessions[i]) }
    public func snapshot(number:Int) throws -> SessionSnapshot? { lock.lock(); defer{lock.unlock()}; guard let s=sessions.first(where:{$0.number==number}) else{return nil}; return snapshotRecord(s) }
    public func listSessions() throws -> [SessionSnapshot] { lock.lock(); defer{lock.unlock()}; return sessions.filter{ !$0.isDeleted }.map(snapshotRecord) }
    public func listDeletedSessions() throws -> [SessionSnapshot] { lock.lock();defer{lock.unlock()};return sessions.filter(\.isDeleted).map(snapshotRecord) }
    public func deleteSession(sessionID:SessionID) throws {
        lock.lock();defer{lock.unlock()};guard let i=sessionIndex(sessionID),!sessions[i].isDeleted else{throw DomainError.unknownSession}
        let wasOpen=sessions[i].isOpen,targetBefore=targetChartID
        for (aid,var a) in attachments where a.sessionID==sessionID && a.active {
            a.active=false;attachments[aid]=a
            for id in a.streamIDs { owners.removeValue(forKey:id);if let(si,ci)=streamIndices(id),let ix=sessions[si].charts[ci].streams.firstIndex(where:{$0.id==id}){sessions[si].charts[ci].streams[ix].state = .disconnected} }
        }
        sessions[i].isOpen=false;sessions[i].isDeleted=true;restoreOpenSessionIDs.remove(sessionID);previouslyOpenSessionIDs.remove(sessionID)
        if sessions[i].timeline.clockStoppedAt == nil { sessions[i].timeline.clockStoppedAt=Date() }
        if let targetChartID,findSessionIndex(forChart:targetChartID)==i{fallbackTarget()}
        if let continuation=lastContinuation,findSessionIndex(forChart:continuation.chartID)==i {lastContinuation=nil;epoch &+= 1}
        record(.sessionDeleted(sessionID,wasOpen:wasOpen,targetBefore:targetBefore,targetAfter:targetChartID),in:sessionID);try persist()
    }
    public func restoreSession(sessionID:SessionID) throws {
        lock.lock();defer{lock.unlock()};guard let i=sessionIndex(sessionID),sessions[i].isDeleted else{throw DomainError.unknownSession};let targetBefore=targetChartID
        sessions[i].isDeleted=false;sessions[i].isOpen=true
        if let chart=sessions[i].charts.first(where:\.isVisible){setTargetInternal(chart.id,invalidate:true)}
        record(.sessionRestored(sessionID,targetBefore:targetBefore,targetAfter:targetChartID),in:sessionID);try persist()
    }
    public func renameSession(_ sessionID:SessionID,to title:String) throws { lock.lock();defer{lock.unlock()};guard let i=sessionIndex(sessionID) else{throw DomainError.unknownSession};let value=title.trimmingCharacters(in:.whitespacesAndNewlines);guard !value.isEmpty else{throw DomainError.invalidSelection};let old=sessions[i].title;guard old != value else{return};sessions[i].title=value;record(.sessionTitle(sessionID,old:old,new:value),in:sessionID);try persist() }
    /// Call from application-termination handling before per-window close callbacks run.
    public func recordTerminationOpenSessions(_ ids:Set<SessionID>) throws { lock.lock();defer{lock.unlock()};restoreOpenSessionIDs=Set(ids.filter{id in sessionIndex(id).map{!sessions[$0].isDeleted} ?? false});terminationSnapshotTaken=true;try persist() }

    @discardableResult public func registerSampler(intent:SinkIntent, sampler:SamplerIntent, owner:UUID=UUID()) throws -> ReadyReply {
        lock.lock(); defer{lock.unlock()}
        suppressPersistDepth += 1
        defer { suppressPersistDepth -= 1 }
        // Registration may create a session/chart before name binding completes. Keep the
        // operation atomic across validation and persistence failures.
        let oldSessions=sessions, oldTarget=targetChartID, oldNext=nextNumber, oldEpoch=epoch
        let oldContinuation=lastContinuation, oldAttachments=attachments, oldOwners=owners,oldAttachmentOrder=attachmentOrder
        let oldUndo=undoStacks, oldRedo=redoStacks, oldRecency=recency
        do {
        guard sampler.columnCount>0, sampler.requestedNames.map({$0.count==sampler.columnCount}) ?? true else { throw DomainError.invalidColumnCount }
        var chartID:ChartID; var explicitNames=sampler.requestedNames ?? []
        switch intent {
        case .newSession:
            let new=try createSession(title:nil); chartID=new.charts[0].id
        case .newChart:
            if !isUsableTarget(targetChartID) { let s=try createSession(); chartID=s.charts[0].id }
            else if let t=targetChartID, let si=findSessionIndex(forChart:t) { chartID=try createChart(in:sessions[si].id,after:t).id }
            else { throw DomainError.noDestination }
        case .session(let sid,let names):
            guard let si=sessionIndex(sid),!sessions[si].isDeleted else { throw DomainError.unknownSession }
            sessions[si].isOpen=true
            if sessions[si].charts.isEmpty { let c=ChartRecord(id:UUID(),title:"Chart 1",streams:[],settings:AxisSettings(),guides:[],isVisible:true); sessions[si].charts=[c] }
            let recent=recency.first(where:{ id in findChartIndices(id).map{$0.0==si && sessions[$0.0].charts[$0.1].isVisible} ?? false })
            if let recent { chartID=recent }
            else if !names.isEmpty,let existing=names.first(where:{name in sessions[si].charts.flatMap(\.streams).contains(where:{$0.name==name})}),let location=streamIndices(sessions[si].charts.flatMap(\.streams).first(where:{$0.name==existing})!.id) { chartID=sessions[si].charts[location.1].id }
            else {let index=sessions[si].charts.count,id=UUID(),chart=ChartRecord(id:id,title:"Chart \(index+1)",streams:[],settings:AxisSettings(),guides:[],isVisible:true);sessions[si].charts.append(chart);record(.createdChart(sessionID:sid,chartID:id,index:index),in:sid);chartID=id}
            if !names.isEmpty { explicitNames=names }
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
                else { let id=UUID();resolved.append(StreamRecord(id:id,name:name,state:.live,unitHint:sampler.unitHint,colorHex:stableColor(id),dotsVisible:sessions[si].charts[ci].settings.dotsVisible,linesVisible:sessions[si].charts[ci].settings.linesVisible)) }
            }
            for var line in resolved { line.state = .live; if line.unitHint == nil { line.unitHint=sampler.unitHint };if line.colorHex == nil{line.colorHex=stableColor(line.id)};if line.dotsVisible == nil{line.dotsVisible=sessions[si].charts[ci].settings.dotsVisible};if line.linesVisible == nil{line.linesVisible=sessions[si].charts[ci].settings.linesVisible}; streamIDs.append(line.id); descriptors.append(descriptor(line)); if streamLocation(line.id)==nil { sessions[si].charts[ci].streams.append(line) } else if let (li,lj)=streamIndices(line.id),let ix=sessions[li].charts[lj].streams.firstIndex(where:{$0.id==line.id}) { sessions[li].charts[lj].streams[ix]=line } }
        } else if intent == .target, let previous=lastContinuation, previous.epoch==epoch, previous.chartID==chartID, previous.streamIDs.count==sampler.columnCount, !previous.active, (sampler.startedAt == nil || previous.finishedAt.map { sampler.startedAt! > $0 } == true), previous.streamIDs.allSatisfy({owners[$0] == nil && (sampler.unitHint == nil || findStream($0)?.unitHint == sampler.unitHint)}) {
            streamIDs=previous.streamIDs; continued=true
            for id in streamIDs { guard let (li,lj)=streamIndices(id),let ix=sessions[li].charts[lj].streams.firstIndex(where:{$0.id==id}) else { throw DomainError.unknownStream };if sessions[li].charts[lj].streams[ix].unitHint == nil{sessions[li].charts[lj].streams[ix].unitHint=sampler.unitHint};sessions[li].charts[lj].streams[ix].state = .live; descriptors.append(descriptor(sessions[li].charts[lj].streams[ix])) }
        } else {
            for col in 0..<sampler.columnCount { let name=(sampler.requestedNames?.indices.contains(col) == true ? sampler.requestedNames![col] : nextDefaultLineName(sessionIndex:si)); let id=UUID();let line=StreamRecord(id:id,name:name,state:.live,unitHint:sampler.unitHint,colorHex:stableColor(id),dotsVisible:sessions[si].charts[ci].settings.dotsVisible,linesVisible:sessions[si].charts[ci].settings.linesVisible); sessions[si].charts[ci].streams.append(line); streamIDs.append(line.id); descriptors.append(descriptor(line)) }
        }
        let aid=UUID(); let attach=AttachmentRecord(id:aid,owner:owner,sessionID:sessions[si].id,chartID:chartID,streamIDs:streamIDs,active:true)
        attachments[aid]=attach;attachmentOrder.append(aid); for id in streamIDs { owners[id]=aid }
        if sessions[si].charts[ci].settings.unit == nil,let unit=sampler.unitHint {sessions[si].charts[ci].settings.unit=unit}
        sessions[si].timeline.clockStoppedAt = nil
        lastContinuation=Continuation(epoch:epoch,chartID:chartID,streamIDs:streamIDs,active:true,finishedAt:nil)
        pruneAttachments()
        touch(chartID); try persistSnapshot()
        return ReadyReply(sessionID:sessions[si].id,chartID:chartID,attachmentID:aid,streams:descriptors,continued:continued)
        } catch {
            sessions=oldSessions; targetChartID=oldTarget; nextNumber=oldNext; epoch=oldEpoch
            lastContinuation=oldContinuation; attachments=oldAttachments; owners=oldOwners;attachmentOrder=oldAttachmentOrder
            undoStacks=oldUndo; redoStacks=oldRedo; recency=oldRecency
            // Restore the on-disk snapshot too: createSession/createChart may have persisted
            // during this compound operation before a later binding check failed.
            try? persistSnapshot()
            throw error
        }
    }

    @discardableResult public func append(_ row:SampleRow,to attachmentID:AttachmentID) throws -> [UInt64] {
        lock.lock(); defer{lock.unlock()}; guard let attachment=attachments[attachmentID], attachment.active else { throw DomainError.unknownStream }
        guard row.values.count==attachment.streamIDs.count, row.values.allSatisfy(\.isFinite) else { throw DomainError.invalidColumnCount }
        let seqs=try samples.append(values:row.values,timestamp:row.timestamp,to:attachment.streamIDs,segmentID:attachmentID.uuidString.lowercased())
        for id in attachment.streamIDs { if let (si,ci)=streamIndices(id), let idx=sessions[si].charts[ci].streams.firstIndex(where:{$0.id==id}) { var s=sessions[si].charts[ci].streams[idx]; s.sampleCount += 1; if s.firstSampleAt == nil {s.firstSampleAt=row.timestamp}; s.lastSampleAt=row.timestamp; s.state = .live; sessions[si].charts[ci].streams[idx]=s } }
        // Raw samples already committed in SQLite; a metadata write failure must not
        // pretend the in-memory sample or producer is absent.
        committedState=memoryState()
        try persist(); return seqs
    }
    public func finishAttachment(_ attachmentID:AttachmentID, reason:FinishReason) throws {
        lock.lock(); defer{lock.unlock()}; guard var a=attachments[attachmentID], a.active else{return}; a.active=false; attachments[attachmentID]=a
        for id in a.streamIDs { if owners[id]==attachmentID { owners.removeValue(forKey:id) }; if let (si,ci)=streamIndices(id),let ix=sessions[si].charts[ci].streams.firstIndex(where:{$0.id==id}) { sessions[si].charts[ci].streams[ix].state = reason == .error ? .errored : (reason == .clientDisconnected ? .disconnected : .ended) } }
        if lastContinuation?.streamIDs == a.streamIDs { lastContinuation?.active=false;lastContinuation?.finishedAt=Date() }
        if !attachments.values.contains(where: { $0.sessionID == a.sessionID && $0.active }), let i = sessionIndex(a.sessionID) {
            sessions[i].timeline.clockStoppedAt = Date()
        }
        // EOF/interruption is an external lifecycle fact; do not roll it back if the
        // metadata snapshot cannot be written.
        pruneAttachments()
        committedState=memoryState()
        try persist()
    }
    public func recordRejectedInput(_ rejection:InputRejection,to attachmentID:AttachmentID) throws {
        lock.lock();defer{lock.unlock()};guard let attachment=attachments[attachmentID],let i=sessionIndex(attachment.sessionID) else{throw DomainError.unknownStream}
        sessions[i].rejectedLineCount += Int(rejection.rejectedCount);try persist()
    }

    public func moveStream(_ streamID:StreamID,to chartID:ChartID) throws {
        lock.lock(); defer{lock.unlock()}; guard let (si,ci)=findChartIndices(chartID), let (oi,oj)=streamIndices(streamID) else { throw DomainError.unknownStream }
        guard si == oi, !(si==oi && ci==oj), sessions[si].charts[ci].isVisible else { throw DomainError.invalidMove }
        let sourceWasVisible=sessions[oi].charts[oj].isVisible, destinationWasVisible=sessions[si].charts[ci].isVisible
        var stream=sessions[oi].charts[oj].streams.remove(at:sessions[oi].charts[oj].streams.firstIndex{$0.id==streamID}!)
        if stream.colorHex == nil { stream.colorHex=stableColor(streamID) }
        if stream.dotsVisible == nil { stream.dotsVisible=sessions[oi].charts[oj].settings.dotsVisible }
        if stream.linesVisible == nil { stream.linesVisible=sessions[oi].charts[oj].settings.linesVisible }
        sessions[si].charts[ci].streams.append(stream)
        if sessions[oi].charts[oj].streams.isEmpty { sessions[oi].charts[oj].isVisible=false; if targetChartID==sessions[oi].charts[oj].id { fallbackTarget() } }
        record(.movedStream(streamID,from:sessions[oi].charts[oj].id,to:chartID,fromWasVisible:sourceWasVisible,toWasVisible:destinationWasVisible,fromNowVisible:sessions[oi].charts[oj].isVisible,toNowVisible:sessions[si].charts[ci].isVisible),in:sessions[oi].id)
        try persist()
    }
    /// Creates a chart immediately after the stream's current chart and moves the stream
    /// as one undoable model action. The app-wide target is preserved unless source collapse
    /// requires its normal fallback.
    @discardableResult public func moveStreamToNewChart(_ streamID:StreamID,after afterChartID:ChartID?=nil) throws -> ChartSnapshot {
        lock.lock(); defer{lock.unlock()}
        guard let (si,sourceIndex)=streamIndices(streamID), let sourcePosition=sessions[si].charts[sourceIndex].streams.firstIndex(where:{$0.id==streamID}) else { throw DomainError.unknownStream }
        let sourceID=sessions[si].charts[sourceIndex].id
        let insertionAnchor=afterChartID.flatMap{aid in sessions[si].charts.firstIndex(where:{$0.id==aid})} ?? sourceIndex
        let chartIndex=insertionAnchor+1, id=UUID()
        var chart=ChartRecord(id:id,title:"Chart \(sessions[si].charts.count+1)",streams:[],settings:AxisSettings(),guides:[],isVisible:true)
        let oldTarget=targetChartID, wasVisible=sessions[si].charts[sourceIndex].isVisible
        var stream=sessions[si].charts[sourceIndex].streams.remove(at:sourcePosition)
        if stream.colorHex == nil { stream.colorHex=stableColor(streamID) }
        if stream.dotsVisible == nil { stream.dotsVisible=sessions[si].charts[sourceIndex].settings.dotsVisible }
        if stream.linesVisible == nil { stream.linesVisible=sessions[si].charts[sourceIndex].settings.linesVisible }
        chart.streams.append(stream)
        sessions[si].charts.insert(chart,at:chartIndex)
        if sessions[si].charts[sourceIndex].streams.isEmpty {
            sessions[si].charts[sourceIndex].isVisible=false
            if targetChartID==sourceID { fallbackTarget() }
        }
        record(.moveToNewChart(streamID,from:sourceID,chart:chart,index:chartIndex,streamIndex:sourcePosition,sourceWasVisible:wasVisible,targetBefore:oldTarget,targetAfter:targetChartID),in:sessions[si].id)
        try persist()
        return chartSnapshot(sessions[si].charts[chartIndex],target:targetChartID)
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
        var endedGroup=false
        for id in sourceStreamIDs {
            guard let aid=owners[id],attachments[aid]?.active==true else {
                guard findStream(id)?.state == .ended else { throw DomainError.streamBusy(findStream(id)?.name ?? id.uuidString) }
                endedGroup=true; continue
            }
            if let attachmentID, attachmentID != aid { throw DomainError.invalidMove }
            attachmentID=aid
        }
        if endedGroup {
            guard attachmentID == nil, sourceStreamIDs.allSatisfy({findStream($0)?.state == .ended}),
                  let ended=attachments.values.first(where:{ !$0.active && Set($0.streamIDs)==Set(sourceStreamIDs) }) else { throw DomainError.invalidMove }
            attachmentID=ended.id
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
        do {try persist()} catch {try? rollbackReassociationSamples(action,currentlyReversed:false);throw error}
    }
    public func renameStream(_ streamID:StreamID,to name:String) throws {
        lock.lock(); defer{lock.unlock()}; guard let (si,ci)=streamIndices(streamID),let ix=sessions[si].charts[ci].streams.firstIndex(where:{$0.id==streamID}) else{throw DomainError.unknownStream}
        let old=sessions[si].charts[ci].streams[ix].name;guard old != name else{return}
        if sessions[si].charts.flatMap(\.streams).contains(where:{$0.id != streamID && $0.name==name}) { throw DomainError.duplicateName(name) }
        sessions[si].charts[ci].streams[ix].name=name
        record(.renamedStream(streamID,old:old,new:name),in:sessions[si].id); try persist()
    }
    public func updateSettings(_ settings:AxisSettings,chartID:ChartID) throws { lock.lock();defer{lock.unlock()}; guard let(si,ci)=findChartIndices(chartID) else{throw DomainError.unknownChart};if case .fixed(let min,let max)=settings.yScale,(!min.isFinite || !max.isFinite || min>=max){throw DomainError.invalidAxisSettings};let old=sessions[si].charts[ci].settings;guard old != settings else{return};let styles=sessions[si].charts[ci].streams.map{StreamStyleSnapshot(id:$0.id,color:$0.colorHex,dots:$0.dotsVisible,lines:$0.linesVisible)};sessions[si].charts[ci].settings=settings;for ix in sessions[si].charts[ci].streams.indices{sessions[si].charts[ci].streams[ix].dotsVisible=settings.dotsVisible;sessions[si].charts[ci].streams[ix].linesVisible=settings.linesVisible}; record(.settings(chartID,old:old,new:settings,oldStyles:styles),in:sessions[si].id); try persist() }
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
    public func updateTimeline(_ timeline:TimelineState,sessionID:SessionID) throws { lock.lock();defer{lock.unlock()};guard let i=sessionIndex(sessionID) else{throw DomainError.unknownSession};var value=timeline;value.selection=sessions[i].timeline.selection;value.forecast=sessions[i].timeline.forecast;value.forecasts=sessions[i].timeline.forecasts;value.clockStoppedAt=sessions[i].timeline.clockStoppedAt;sessions[i].timeline=value;try persist() }
    public func setSelection(_ selection:TimeSelection?,sessionID:SessionID) throws { lock.lock();defer{lock.unlock()};guard let i=sessionIndex(sessionID) else{throw DomainError.unknownSession};if let s=selection { if s.start>s.end {throw DomainError.invalidSelection};if case .bothFollowNow(let duration)=s.mode,(!duration.isFinite || duration<=0){throw DomainError.invalidSelection} };let old=sessions[i].timeline.selection;guard old != selection else{return};sessions[i].timeline.selection=selection;record(.selection(sessionID,old:old,new:selection),in:sessionID);try persist() }
    public func setForecast(_ forecast:ForecastConfiguration?,sessionID:SessionID) throws { lock.lock();defer{lock.unlock()};guard let i=sessionIndex(sessionID) else{throw DomainError.unknownSession};if let f=forecast {guard f.selection.start<=f.selection.end, sessions[i].charts.flatMap(\.streams).contains(where:{$0.id==f.streamID}),sessions[i].charts.contains(where:{$0.guides.contains(where:{$0.id==f.guideID && $0.orientation == .horizontalValue})}) else {throw DomainError.invalidSelection}};let old=sessions[i].timeline.forecast;guard old != forecast else{return};sessions[i].timeline.forecast=forecast;record(.forecast(sessionID,old:old,new:forecast),in:sessionID);try persist() }
    public func setForecasts(_ forecasts:[ForecastConfiguration],sessionID:SessionID)throws {lock.lock();defer{lock.unlock()};guard let i=sessionIndex(sessionID)else{throw DomainError.unknownSession};for f in forecasts{guard f.selection.start<=f.selection.end,sessions[i].charts.flatMap(\.streams).contains(where:{$0.id==f.streamID}),sessions[i].charts.contains(where:{$0.guides.contains(where:{$0.id==f.guideID && $0.orientation == .horizontalValue})}) else{throw DomainError.invalidSelection}};let old=sessions[i].timeline.forecasts ?? sessions[i].timeline.forecast.map{[$0]} ?? [];guard old != forecasts else{return};sessions[i].timeline.forecasts=forecasts;sessions[i].timeline.forecast=forecasts.first;record(.forecasts(sessionID,old:old,new:forecasts),in:sessionID);try persist()}
    public func updateStreamStyle(_ id:StreamID,colorHex:String?,dotsVisible:Bool?,linesVisible:Bool?)throws {lock.lock();defer{lock.unlock()};guard let(si,ci)=streamIndices(id),let ix=sessions[si].charts[ci].streams.firstIndex(where:{$0.id==id})else{throw DomainError.unknownStream};let old=sessions[si].charts[ci].streams[ix];let color=colorHex ?? old.colorHex,dots=dotsVisible ?? old.dotsVisible,lines=linesVisible ?? old.linesVisible;guard color != old.colorHex || dots != old.dotsVisible || lines != old.linesVisible else{return};sessions[si].charts[ci].streams[ix].colorHex=color;sessions[si].charts[ci].streams[ix].dotsVisible=dots;sessions[si].charts[ci].streams[ix].linesVisible=lines;record(.streamStyle(id,oldColor:old.colorHex,newColor:color,oldDots:old.dotsVisible,newDots:dots,oldLines:old.linesVisible,newLines:lines),in:sessions[si].id);try persist()}
    public func setSessionOpen(_ open:Bool,sessionID:SessionID) throws { lock.lock();defer{lock.unlock()};guard let i=sessionIndex(sessionID),!sessions[i].isDeleted || !open else{throw DomainError.unknownSession};sessions[i].isOpen=open;if !open { let active=attachments.values.filter{$0.sessionID==sessionID && $0.active};for a in active { try finishAttachment(a.id,reason:.sessionClosed) }; if let t=targetChartID, sessions[i].charts.contains(where:{$0.id==t}) { targetChartID=nil; fallbackTarget() } };try persist() }

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
            sessions[si].charts[destinationIndex].isVisible=true
            sessions[si].charts[destinationIndex].streams.append(contentsOf:moved)
            if targetChartID==cid { fallbackTarget() }
            action = .restoredChart(sessionID:sid,chart:chart,index:index,streamIDs:moved.map(\.id))
        case .restoredChart(let sid,let chartRecord,let index,let ids):
            var chart=chartRecord; chart.streams=[]
            for id in ids { if let location=streamIndices(id),location.0==si,let stream=removeStream(id,at:location) { chart.streams.append(stream) } }
            if let existing=findChartIndices(chart.id), existing.0==si {
                sessions[si].charts[existing.1].streams.append(contentsOf:chart.streams)
                sessions[si].charts[existing.1].isVisible=true
            } else { sessions[si].charts.insert(chart,at:min(index,sessions[si].charts.count)) }
            action = .createdChart(sessionID:sid,chartID:chart.id,index:index)
        case .movedStream(let id,let from,let to,let fromWasVisible,let toWasVisible,let fromNowVisible,let toNowVisible):
            if let destination=findChartIndices(undo ? from : to),let sourceChart=findChartIndices(undo ? to : from),let stream=removeStream(id,at:sourceChart) {
                sessions[destination.0].charts[destination.1].streams.append(stream)
                if let (fsi,fci)=findChartIndices(from) { sessions[fsi].charts[fci].isVisible=(undo ? fromWasVisible:fromNowVisible) || !sessions[fsi].charts[fci].streams.isEmpty }
                if let (tsi,tci)=findChartIndices(to) { sessions[tsi].charts[tci].isVisible=(undo ? toWasVisible:toNowVisible) || !sessions[tsi].charts[tci].streams.isEmpty }
            }
        case .moveToNewChart(let id,let from,let chartRecord,let index,let streamIndex,let sourceWasVisible,let targetBefore,let targetAfter):
            let chartID=chartRecord.id
            if undo {
                if let source=findChartIndices(from), let current=streamIndices(id), let stream=removeStream(id,at:current) {
                    sessions[source.0].charts[source.1].streams.insert(stream,at:min(streamIndex,sessions[source.0].charts[source.1].streams.count))
                    if sourceWasVisible || !sessions[source.0].charts[source.1].streams.isEmpty { sessions[source.0].charts[source.1].isVisible=true }
                }
                if let target=findChartIndices(chartID),sessions[target.0].charts[target.1].streams.isEmpty { sessions[target.0].charts.remove(at:target.1) }
                if targetChartID==targetAfter { targetChartID=targetBefore }
            } else {
                if let source=findChartIndices(from) {
                    if findChartIndices(chartID)==nil {var restored=chartRecord;restored.streams=[];sessions[source.0].charts.insert(restored,at:min(index,sessions[source.0].charts.count))}
                    if let current=streamIndices(id),let stream=removeStream(id,at:current),let dest=findChartIndices(chartID) { sessions[dest.0].charts[dest.1].streams.append(stream);sessions[dest.0].charts[dest.1].isVisible=true }
                    if let nowSource=findChartIndices(from),sessions[nowSource.0].charts[nowSource.1].streams.isEmpty { sessions[nowSource.0].charts[nowSource.1].isVisible=false;if targetChartID==from{fallbackTarget()} }
                }
            }
        case .renamedStream(let id,let old,let new): if let (a,b)=streamIndices(id),let ix=sessions[a].charts[b].streams.firstIndex(where:{$0.id==id}) { sessions[a].charts[b].streams[ix].name=undo ? old:new }
        case .settings(let cid,let old,let new,let oldStyles): if let(a,b)=findChartIndices(cid){let value=undo ? old:new;sessions[a].charts[b].settings=value;for ix in sessions[a].charts[b].streams.indices{let id=sessions[a].charts[b].streams[ix].id;if undo,let style=oldStyles.first(where:{$0.id==id}){sessions[a].charts[b].streams[ix].colorHex=style.color;sessions[a].charts[b].streams[ix].dotsVisible=style.dots;sessions[a].charts[b].streams[ix].linesVisible=style.lines}else{sessions[a].charts[b].streams[ix].dotsVisible=value.dotsVisible;sessions[a].charts[b].streams[ix].linesVisible=value.linesVisible}}}
        case .guide(let cid,let gid,let old,let new): if let(a,b)=findChartIndices(cid){sessions[a].charts[b].guides.removeAll{$0.id==gid};if let value=undo ? old:new{sessions[a].charts[b].guides.append(value)}}
        case .timeGuide(let sid,let gid,let old,let new): if let i=sessionIndex(sid){sessions[i].timeGuides.removeAll{$0.id==gid};if let value=undo ? old:new{sessions[i].timeGuides.append(value)}}
        case .selection(let sid,let old,let new): if let i=sessionIndex(sid){sessions[i].timeline.selection=undo ? old:new}
        case .forecast(let sid,let old,let new): if let i=sessionIndex(sid){sessions[i].timeline.forecast=undo ? old:new}
        case .forecasts(let sid,let old,let new):if let i=sessionIndex(sid){let value=undo ? old:new;sessions[i].timeline.forecasts=value;sessions[i].timeline.forecast=value.first}
        case .streamStyle(let id,let oldColor,let newColor,let oldDots,let newDots,let oldLines,let newLines):if let(a,b)=streamIndices(id),let ix=sessions[a].charts[b].streams.firstIndex(where:{$0.id==id}){sessions[a].charts[b].streams[ix].colorHex=undo ? oldColor:newColor;sessions[a].charts[b].streams[ix].dotsVisible=undo ? oldDots:newDots;sessions[a].charts[b].streams[ix].linesVisible=undo ? oldLines:newLines}
        case .sessionTitle(let sid,let old,let new): if let i=sessionIndex(sid){sessions[i].title=undo ? old:new}
        case .chartTitle(let id,let old,let new):if let(a,b)=findChartIndices(id){sessions[a].charts[b].title=undo ? old:new}
        case .chartReordered(let id,let from,let to):if let(a,b)=findChartIndices(id){let chart=sessions[a].charts.remove(at:b);sessions[a].charts.insert(chart,at:min(undo ? from:to,sessions[a].charts.count))}
        case .chartDeleted(let sid,let chart,index:let chartIndex):if let i=sessionIndex(sid){if undo{sessions[i].charts.insert(chart,at:min(chartIndex,sessions[i].charts.count))}else if let ci=sessions[i].charts.firstIndex(where:{$0.id==chart.id}),sessions[i].charts[ci].streams.isEmpty{sessions[i].charts.remove(at:ci)}}
        case .chartVisibility(let id,let old,let new):if let(a,b)=findChartIndices(id){sessions[a].charts[b].isVisible=undo ? old:new;if !(undo ? old:new),targetChartID==id{fallbackTarget()}}
        case .sessionDeleted(let sid,let wasOpen,let targetBefore,let targetAfter): if let i=sessionIndex(sid){sessions[i].isDeleted = !undo;sessions[i].isOpen = undo ? wasOpen:false;if undo {if targetChartID==targetAfter,let prior=targetBefore,isUsableTarget(prior){setTargetInternal(prior,invalidate:true)}} else if targetChartID.flatMap(findSessionIndex(forChart:)) == i {fallbackTarget()}}
        case .sessionRestored(let sid,let targetBefore,let targetAfter):if let i=sessionIndex(sid){sessions[i].isDeleted=undo;sessions[i].isOpen = !undo;if undo {if targetChartID==targetAfter,let prior=targetBefore,isUsableTarget(prior){setTargetInternal(prior,invalidate:true)}}else if let chart=sessions[i].charts.first(where:\.isVisible){setTargetInternal(chart.id,invalidate:true)}}
        case .reassociation(let association): do { try applyReassociation(association,reverse:undo) } catch { _ = restoreAction(.reassociation(association),sessionID:sessionID,undo:undo); throw error }
        }
        if undo { redoStacks[sessionID,default:[]].append(action) } else { undoStacks[sessionID,default:[]].append(action) }
        if let targetChartID,findChartIndices(targetChartID).map({sessions[$0.0].charts[$0.1].isVisible && sessions[$0.0].isOpen}) != true { fallbackTarget() }
        do {try persist()} catch {if case .reassociation(let association)=action {try? rollbackReassociationSamples(association,currentlyReversed:undo)};throw error};return true
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
            for id in destinationIDs where owners[id] != nil && owners[id] != action.attachmentID {
                throw DomainError.streamBusy(findStream(id)?.name ?? id.uuidString)
            }
            for id in destinationIDs where owners[id] == action.attachmentID { owners.removeValue(forKey:id) }
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
    private func rollbackReassociationSamples(_ action:ReassociationAction,currentlyReversed:Bool)throws {let transfers=action.items.map{item in SegmentTransfer(segmentIDs:item.segmentIDs,from:currentlyReversed ? item.sourceID:item.destinationID,to:currentlyReversed ? item.destinationID:item.sourceID)};try samples.reassignSegments(transfers)}

    private func record(_ action:UndoRecord,in sessionID:SessionID){var stack=undoStacks[sessionID,default:[]];stack.append(action);if stack.count>200{stack.removeFirst(stack.count-200)};undoStacks[sessionID]=stack;redoStacks[sessionID]=[]}
    private func pruneAttachments(){
        var keep=Set(attachments.values.filter(\.active).map(\.id))
        if let continuation=lastContinuation,let id=attachmentOrder.reversed().first(where:{attachments[$0]?.streamIDs==continuation.streamIDs}){keep.insert(id)}
        // Keep the newest producer record touching each stream. That retains the latest
        // ended group for every line, while repeated continuations over the same lines
        // collapse to one record. Raw samples and segment identities remain in SQLite.
        var seenStreams=Set<StreamID>()
        for id in attachmentOrder.reversed(){guard let attachment=attachments[id]else{continue};let newlyLatest=attachment.streamIDs.contains{seenStreams.insert($0).inserted};if newlyLatest{keep.insert(id)}}
        for stack in Array(undoStacks.values)+Array(redoStacks.values){for action in stack{if case .reassociation(let association)=action{keep.insert(association.attachmentID)}}}
        attachments=attachments.filter{keep.contains($0.key)}
        attachmentOrder.removeAll{!keep.contains($0)}
    }
    private func setTargetInternal(_ id:ChartID,invalidate:Bool){targetChartID=id;touch(id);if invalidate{epoch &+= 1;lastContinuation=nil}}
    private func isUsableTarget(_ id:ChartID?)->Bool{guard let id,let(i,j)=findChartIndices(id) else{return false};return !sessions[i].isDeleted && sessions[i].isOpen && sessions[i].charts[j].isVisible}
    private func touch(_ id:ChartID){recency.removeAll{$0==id};recency.insert(id,at:0)}
    private func fallbackTarget(){targetChartID=recency.first(where:{id in guard let(i,j)=findChartIndices(id) else{return false};return !sessions[i].isDeleted && sessions[i].isOpen && sessions[i].charts[j].isVisible});epoch &+= 1;lastContinuation=nil}
    private func previousChartIndex(_ sid:SessionID,_ cid:ChartID)->Int?{guard let si=sessionIndex(sid),let ci=sessions[si].charts.firstIndex(where:{$0.id==cid}),ci>0 else{return nil};return ci-1}
    private func removeStream(_ id:StreamID,at pair:(Int,Int))->StreamRecord?{let (a,b)=pair;guard let ix=sessions[a].charts[b].streams.firstIndex(where:{$0.id==id}) else{return nil};return sessions[a].charts[b].streams.remove(at:ix)}
    private func sessionIndex(_ id:SessionID)->Int?{sessions.firstIndex{$0.id==id}}
    private func findChart(_ id:ChartID?)->ChartRecord?{guard let id else{return nil};for s in sessions{if let c=s.charts.first(where:{$0.id==id}){return c}};return nil}
    private func findChartIndices(_ id:ChartID)->(Int,Int)?{for i in sessions.indices{if let j=sessions[i].charts.firstIndex(where:{$0.id==id}){return(i,j)}};return nil}
    private func findSessionIndex(forChart id:ChartID)->Int?{sessions.firstIndex{$0.charts.contains(where:{$0.id==id})}}
    private func streamIndices(_ id:StreamID)->(Int,Int)?{for i in sessions.indices{for j in sessions[i].charts.indices where sessions[i].charts[j].streams.contains(where:{$0.id==id}){return(i,j)}};return nil}
    private func streamLocation(_ id:StreamID)->(Int,Int)?{streamIndices(id)}
    private func descriptor(_ s:StreamRecord)->StreamDescriptor{StreamDescriptor(id:s.id,name:s.name,state:s.state,sampleCount:s.sampleCount,firstSampleAt:s.firstSampleAt,lastSampleAt:s.lastSampleAt,unitHint:s.unitHint,colorHex:s.colorHex,dotsVisible:s.dotsVisible,linesVisible:s.linesVisible)}
    private func stableColor(_ id:UUID)->String {let h=id.uuidString.utf8.reduce(UInt64(1469598103934665603)){($0 ^ UInt64($1)) &* 1099511628211};let palette=["#38A3D1","#D97932","#438A57","#B459AD","#CF5562","#8B78CB","#35978C","#B28A23"];return palette[Int(h % UInt64(palette.count))]}
    private func findStream(_ id:StreamID)->StreamRecord?{guard let (i,j)=streamIndices(id) else{return nil};return sessions[i].charts[j].streams.first{$0.id==id}}
    private func nextDefaultLineName(sessionIndex:Int)->String { let existing=Set(sessions[sessionIndex].charts.flatMap(\.streams).map(\.name));var n=1;while existing.contains("Line \(n)"){n+=1};return "Line \(n)" }
    private func chartSnapshot(_ c:ChartRecord,target:ChartID?)->ChartSnapshot{ChartSnapshot(id:c.id,title:c.title,streams:c.streams.map(descriptor),settings:c.settings,guides:c.guides,isTarget:c.id==target,isVisible:c.isVisible)}
    private func snapshotRecord(_ s:SessionRecord)->SessionSnapshot{SessionSnapshot(id:s.id,number:s.number,title:s.title,charts:s.charts.map{chartSnapshot($0,target:targetChartID)},timeGuides:s.timeGuides,timeline:s.timeline,isOpen:s.isOpen,rejectedLineCount:s.rejectedLineCount,isDeleted:s.isDeleted)}
    private func persist() throws {guard suppressPersistDepth==0 else{return};try persistSnapshot()}
    private func persistSnapshot()throws {let before=committedState ?? memoryState();do{if !terminationSnapshotTaken { restoreOpenSessionIDs=Set(sessions.filter(\.isOpen).map(\.id)) }; let state=PersistedState(sessions:sessions,targetChartID:targetChartID,nextNumber:nextNumber,recency:recency,restoreOpenSessionIDs:restoreOpenSessionIDs);let data=try JSONEncoder().encode(state);try data.write(to:metadataURL,options:.atomic);committedState=memoryState()}catch{restoreMemoryState(before);throw error}}
    private func memoryState()->MemoryState {MemoryState(previouslyOpenSessionIDs:previouslyOpenSessionIDs,sessions:sessions,targetChartID:targetChartID,nextNumber:nextNumber,epoch:epoch,lastContinuation:lastContinuation,attachments:attachments,owners:owners,attachmentOrder:attachmentOrder,undoStacks:undoStacks,redoStacks:redoStacks,recency:recency,restoreOpenSessionIDs:restoreOpenSessionIDs,terminationSnapshotTaken:terminationSnapshotTaken)}
    private func restoreMemoryState(_ s:MemoryState){previouslyOpenSessionIDs=s.previouslyOpenSessionIDs;sessions=s.sessions;targetChartID=s.targetChartID;nextNumber=s.nextNumber;epoch=s.epoch;lastContinuation=s.lastContinuation;attachments=s.attachments;owners=s.owners;attachmentOrder=s.attachmentOrder;undoStacks=s.undoStacks;redoStacks=s.redoStacks;recency=s.recency;restoreOpenSessionIDs=s.restoreOpenSessionIDs;terminationSnapshotTaken=s.terminationSnapshotTaken}
}

private struct Continuation {var epoch:UInt64;var chartID:ChartID;var streamIDs:[StreamID];var active:Bool;var finishedAt:Date?}
private struct MemoryState {var previouslyOpenSessionIDs:Set<SessionID>;var sessions:[SessionRecord];var targetChartID:ChartID?;var nextNumber:Int;var epoch:UInt64;var lastContinuation:Continuation?;var attachments:[AttachmentID:AttachmentRecord];var owners:[StreamID:AttachmentID];var attachmentOrder:[AttachmentID];var undoStacks:[SessionID:[UndoRecord]];var redoStacks:[SessionID:[UndoRecord]];var recency:[ChartID];var restoreOpenSessionIDs:Set<SessionID>;var terminationSnapshotTaken:Bool}
private struct AttachmentRecord {var id:AttachmentID;var owner:UUID;var sessionID:SessionID;var chartID:ChartID;var streamIDs:[StreamID];var active:Bool}
private struct SessionRecord:Codable {var id:SessionID;var number:Int;var title:String;var charts:[ChartRecord];var timeGuides:[Guide];var timeline:TimelineState;var isOpen:Bool;var rejectedLineCount:Int;var isDeleted:Bool=false}
private struct ChartRecord:Codable {var id:ChartID;var title:String;var streams:[StreamRecord];var settings:AxisSettings;var guides:[Guide];var isVisible:Bool}
private struct StreamRecord:Codable {var id:StreamID;var name:String;var state:StreamState;var sampleCount:Int64=0;var firstSampleAt:Date?;var lastSampleAt:Date?;var unitHint:String?;var colorHex:String?;var dotsVisible:Bool?;var linesVisible:Bool?}
private struct PersistedState:Codable {var sessions:[SessionRecord];var targetChartID:ChartID?;var nextNumber:Int;var recency:[ChartID];var restoreOpenSessionIDs:Set<SessionID>?}
private struct ReassociationItem {var sourceID:StreamID;var destinationID:StreamID;var segmentIDs:[String];var sourceRecord:StreamRecord;var sourceChartID:ChartID;var sourceChartIndex:Int;var sourceStreamIndex:Int;var destinationChartID:ChartID}
private struct ReassociationAction {var sessionID:SessionID;var attachmentID:AttachmentID;var items:[ReassociationItem];var chartVisibility:[ChartID:Bool]}
private struct StreamStyleSnapshot {var id:StreamID;var color:String?;var dots:Bool?;var lines:Bool?}
private enum UndoRecord {case createdChart(sessionID:SessionID,chartID:ChartID,index:Int),restoredChart(sessionID:SessionID,chart:ChartRecord,index:Int,streamIDs:[StreamID]),movedStream(StreamID,from:ChartID,to:ChartID,fromWasVisible:Bool,toWasVisible:Bool,fromNowVisible:Bool,toNowVisible:Bool),moveToNewChart(StreamID,from:ChartID,chart:ChartRecord,index:Int,streamIndex:Int,sourceWasVisible:Bool,targetBefore:ChartID?,targetAfter:ChartID?),renamedStream(StreamID,old:String,new:String),sessionTitle(SessionID,old:String,new:String),chartTitle(ChartID,old:String,new:String),chartReordered(ChartID,from:Int,to:Int),chartDeleted(SessionID,chart:ChartRecord,index:Int),chartVisibility(ChartID,old:Bool,new:Bool),sessionDeleted(SessionID,wasOpen:Bool,targetBefore:ChartID?,targetAfter:ChartID?),sessionRestored(SessionID,targetBefore:ChartID?,targetAfter:ChartID?),settings(ChartID,old:AxisSettings,new:AxisSettings,oldStyles:[StreamStyleSnapshot]),guide(ChartID,id:UUID,old:Guide?,new:Guide?),timeGuide(SessionID,id:UUID,old:Guide?,new:Guide?),selection(SessionID,old:TimeSelection?,new:TimeSelection?),forecast(SessionID,old:ForecastConfiguration?,new:ForecastConfiguration?),forecasts(SessionID,old:[ForecastConfiguration],new:[ForecastConfiguration]),streamStyle(StreamID,oldColor:String?,newColor:String?,oldDots:Bool?,newDots:Bool?,oldLines:Bool?,newLines:Bool?),reassociation(ReassociationAction)}

private extension SessionRecord {
    enum CodingKeys: String, CodingKey { case id, number, title, charts, timeGuides, timeline, isOpen, rejectedLineCount, isDeleted }
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
        isDeleted = try c.decodeIfPresent(Bool.self, forKey: .isDeleted) ?? false
    }
}

private extension UndoRecord {
    var title: String {
        switch self {
        case .createdChart, .restoredChart: return "Create Chart"
        case .movedStream, .moveToNewChart: return "Move Stream"
        case .renamedStream: return "Rename Stream"
        case .sessionTitle: return "Rename Session"
        case .chartTitle: return "Rename Chart"
        case .chartReordered: return "Reorder Chart"
        case .chartDeleted: return "Delete Chart"
        case .chartVisibility: return "Delete Chart"
        case .sessionDeleted: return "Delete Session"
        case .sessionRestored: return "Restore Session"
        case .settings: return "Axis Settings"
        case .guide, .timeGuide: return "Guide Edit"
        case .selection: return "Selection"
        case .forecast: return "Linear Forecast"
        case .forecasts: return "Linear Forecasts"
        case .streamStyle: return "Stream Style"
        case .reassociation: return "Reassociate Streams"
        }
    }
}
