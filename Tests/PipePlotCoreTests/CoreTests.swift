import XCTest
@testable import PipePlotCore

final class CoreTests: XCTestCase {
    func testAxisEditsPreserveIndependentMarksThroughReplayAndCapture() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PipePlotStore(databaseURL: directory.appendingPathComponent("test.sqlite"))
        let ready = try store.registerSampler(intent: .target, sampler: SamplerIntent(columnCount: 2))
        let ids = ready.streams.map(\.id)
        try store.updateStreamStyle(ids[0], colorHex: nil, dotsVisible: true, linesVisible: false)
        func chart() throws -> ChartSnapshot { try XCTUnwrap(store.snapshot(sessionID: ready.sessionID)?.charts.first) }
        var settings = try chart().settings
        settings.unit = "bytes"; settings.numericScale = .binary; settings.includeZero = true
        settings.yScale = .fixed(min: -10, max: 100); settings.referenceGuideID = UUID()
        try store.updateSettings(settings, chartID: ready.chartID)
        try store.append(SampleRow(timestamp: Date(), values: [1, 2], sequence: 1), to: ready.attachmentID)
        for _ in 0..<2 {
            XCTAssertEqual(try chart().streams[0].dotsVisible, true)
            XCTAssertEqual(try chart().streams[0].linesVisible, false)
            XCTAssertTrue(try store.undo(sessionID: ready.sessionID))
            XCTAssertTrue(try store.redo(sessionID: ready.sessionID))
        }
        settings.dotsVisible = true
        try store.updateSettings(settings, chartID: ready.chartID)
        XCTAssertEqual(try chart().streams[0].linesVisible, false)
        XCTAssertEqual(try chart().streams[1].linesVisible, true)
        XCTAssertTrue(try store.undo(sessionID: ready.sessionID))
        XCTAssertEqual(try chart().streams[0].dotsVisible, true)
        XCTAssertEqual(try chart().streams[1].dotsVisible, false)
        XCTAssertTrue(try store.redo(sessionID: ready.sessionID))
        XCTAssertEqual(try chart().streams[0].linesVisible, false)
        XCTAssertEqual(try chart().streams.map(\.sampleCount), [1, 1])
    }

    func testParserSplitRowsAndFinalUnterminatedLine() {
        let parser=InputParser()
        XCTAssertTrue(parser.append(Data(" -1.2e2\t0 ".utf8),timestamp:Date(timeIntervalSince1970:1)).isEmpty)
        let first=parser.append(Data("\n3.5 4.5".utf8),timestamp:Date(timeIntervalSince1970:2))
        XCTAssertEqual(first,[.row(SampleRow(timestamp:Date(timeIntervalSince1970:2),values:[-120,0],sequence:1))])
        XCTAssertEqual(parser.finish(timestamp:Date(timeIntervalSince1970:3)),[.row(SampleRow(timestamp:Date(timeIntervalSince1970:3),values:[3.5,4.5],sequence:2))])
    }
    func testParserRejectsNULOversizeAndWidthAtomically() {
        let p=InputParser(expectedColumnCount:2)
        let fixedTime=Date(timeIntervalSince1970:9)
        let events=p.append(Data("1 2\n3\n4 NaN\n".utf8),timestamp:fixedTime)
        XCTAssertEqual(events.count,3)
        XCTAssertEqual(events[0],.row(SampleRow(timestamp:fixedTime,values:[1,2],sequence:1)))
        XCTAssertEqual(events[1],.rejected(ParseIssue(kind:.wrongColumnCount,lineNumber:2,message:"expected 2 columns, got 1")))
        XCTAssertEqual(events[2],.rejected(ParseIssue(kind:.nonFinite,lineNumber:3,message:"NaN and infinity are not accepted")))
        if case .rejected(let issue)?=p.append(Data([49,0,50,10])).first { XCTAssertEqual(issue.kind,.nulByte) } else { XCTFail("expected NUL rejection") }
        let oversized=InputParser().append(Data(repeating:65,count:InputParser.maximumLineBytes+1)+Data([10]))
        if case .rejected(let issue)?=oversized.first { XCTAssertEqual(issue.kind,.tooLong) } else { XCTFail("expected oversized row rejection") }
    }
    func testAggregatedRejectionCountAndLegacyDecode() throws {
        let encoder=JSONEncoder(),decoder=JSONDecoder()
        let value=InputRejection(kind:.nonFinite,lineNumber:9,message:"bad",rejectedCount:5)
        XCTAssertEqual(try decoder.decode(InputRejection.self,from:encoder.encode(value)),value)
        let legacy=Data("{\"kind\":\"nonFinite\",\"lineNumber\":9,\"message\":\"bad\"}".utf8)
        XCTAssertEqual(try decoder.decode(InputRejection.self,from:legacy).rejectedCount,1)
    }
    func testSQLiteStoresRowsAndBoundsQueries() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        defer{try? FileManager.default.removeItem(at:dir)}
        let store=try SampleStore(databaseURL:dir.appendingPathComponent("samples.sqlite"));let id=UUID()
        try store.append(values:[-2,3],timestamp:Date(timeIntervalSince1970:10),to:[id,UUID()])
        let result=try store.query(streamID:id,limit:10)
        XCTAssertEqual(result.map(\.value),[-2]);XCTAssertEqual(try store.count(streamID:id),1)
        XCTAssertThrowsError(try store.query(streamID:id,limit:50_001))
    }
    func testStatisticsAndForecastUseActualTimes() {
        let t=Date(timeIntervalSince1970:100)
        let samples=(0..<4).map{StoredSample(timestamp:t.addingTimeInterval(Double($0)*2),sequence:UInt64($0),value:Double($0*2))}
        XCTAssertEqual(Analysis.statistics(samples:samples)?.mean,3)
        guard case .crossing(let crossing)=Analysis.linearForecast(samples:samples,guideValue:10) else{return XCTFail("expected crossing")}
        XCTAssertEqual(crossing.timeIntervalSince(t),10,accuracy:1e-8)
    }

    func testConcurrentSamplersDoNotShareAndLatestDisconnectedGroupContinues() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        defer{try? FileManager.default.removeItem(at:dir)}
        let store=try PipePlotStore(databaseURL:dir.appendingPathComponent("state.sqlite"))
        let first=try store.registerSampler(intent:.target,sampler:SamplerIntent(columnCount:2))
        let second=try store.registerSampler(intent:.target,sampler:SamplerIntent(columnCount:2))
        XCTAssertNotEqual(first.streams.map(\.id),second.streams.map(\.id))
        try store.finishAttachment(first.attachmentID,reason:.interrupted)
        // The second registration superseded the continuation slot, so the old producer cannot be guessed.
        let third=try store.registerSampler(intent:.target,sampler:SamplerIntent(columnCount:2))
        XCTAssertNotEqual(first.streams.map(\.id),third.streams.map(\.id))
        try store.finishAttachment(second.attachmentID,reason:.eof)
        try store.finishAttachment(third.attachmentID,reason:.eof)
        let fourth=try store.registerSampler(intent:.target,sampler:SamplerIntent(columnCount:2))
        XCTAssertEqual(third.streams.map(\.id),fourth.streams.map(\.id))
        XCTAssertTrue(fourth.continued)
    }
    func testTargetTouchAndExplicitChartCreationRetainUnambiguousContinuations() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        defer{try? FileManager.default.removeItem(at:dir)}
        let store=try PipePlotStore(databaseURL:dir.appendingPathComponent("state.sqlite"))
        let first=try store.registerSampler(intent:.target,sampler:SamplerIntent(columnCount:1))
        try store.finishAttachment(first.attachmentID,reason:.interrupted)
        _=try store.setTarget(first.chartID)
        let resumed=try store.registerSampler(intent:.target,sampler:SamplerIntent(columnCount:1))
        XCTAssertTrue(resumed.continued)
        try store.finishAttachment(resumed.attachmentID,reason:.interrupted)
        let created=try store.registerSampler(intent:.newChart,sampler:SamplerIntent(columnCount:1))
        try store.finishAttachment(created.attachmentID,reason:.interrupted)
        let again=try store.registerSampler(intent:.target,sampler:SamplerIntent(columnCount:1))
        XCTAssertTrue(again.continued)
        XCTAssertEqual(again.chartID,created.chartID)
    }
    func testDelayedConcurrentRegistrationDoesNotContinueProducerThatFinishedAfterItsStart() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        defer{try? FileManager.default.removeItem(at:dir)}
        let store=try PipePlotStore(databaseURL:dir.appendingPathComponent("state.sqlite"))
        let invocationStart=Date().addingTimeInterval(-30)
        let first=try store.registerSampler(intent:.target,sampler:SamplerIntent(columnCount:1,startedAt:invocationStart))
        try store.finishAttachment(first.attachmentID,reason:.eof)
        let delayedConcurrent=try store.registerSampler(intent:.target,sampler:SamplerIntent(columnCount:1,startedAt:invocationStart.addingTimeInterval(1)))
        XCTAssertFalse(delayedConcurrent.continued)
        XCTAssertNotEqual(delayedConcurrent.streams.map(\.id),first.streams.map(\.id))
        try store.finishAttachment(delayedConcurrent.attachmentID,reason:.eof)
        let laterRerun=try store.registerSampler(intent:.target,sampler:SamplerIntent(columnCount:1,startedAt:Date().addingTimeInterval(1)))
        XCTAssertTrue(laterRerun.continued)
        XCTAssertEqual(laterRerun.streams.map(\.id),delayedConcurrent.streams.map(\.id))
    }
    func testUnitHintInitializesUnsetChartButNeverOverwritesConfiguredUnit() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        defer{try? FileManager.default.removeItem(at:dir)}
        let store=try PipePlotStore(databaseURL:dir.appendingPathComponent("state.sqlite"))
        let first=try store.registerSampler(intent:.target,sampler:SamplerIntent(columnCount:1,unitHint:"MiB"))
        XCTAssertEqual(try store.snapshot(sessionID:first.sessionID)?.charts[0].settings.unit,"MiB")
        let custom=AxisSettings(unit:"GiB")
        try store.updateSettings(custom,chartID:first.chartID)
        try store.finishAttachment(first.attachmentID,reason:.eof)
        _=try store.registerSampler(intent:.chart(chartID:first.chartID,lineNames:[first.streams[0].name]),sampler:SamplerIntent(columnCount:1,unitHint:"bytes"))
        XCTAssertEqual(try store.snapshot(sessionID:first.sessionID)?.charts[0].settings.unit,"GiB")
    }
    func testLatestEndedGroupPerStreamRemainsRepairableAndHistoryIsRetained() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        defer{try? FileManager.default.removeItem(at:dir)}
        let store=try PipePlotStore(databaseURL:dir.appendingPathComponent("state.sqlite"))
        var all:[StreamID]=[]
        for i in 0..<30 {
            let a=try store.registerSampler(intent:.fresh,sampler:SamplerIntent(columnCount:1))
            all.append(a.streams[0].id)
            _=try store.append(SampleRow(values:[Double(i)]),to:a.attachmentID)
            try store.finishAttachment(a.attachmentID,reason:.eof)
        }
        XCTAssertEqual(store.retainedAttachmentCount,30)
        XCTAssertEqual(try all.map{try store.samples.count(streamID:$0)}.reduce(0,+),30)
        for id in all { XCTAssertEqual(store.samplerGroup(containing:id),[id]) }
    }
    func testRepeatedContinuationsOfOneStreamKeepOnlyLatestAttachmentRecord() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        defer{try? FileManager.default.removeItem(at:dir)}
        let store=try PipePlotStore(databaseURL:dir.appendingPathComponent("state.sqlite"))
        var latest:ReadyReply?
        for i in 0..<30 {
            let attachment=try store.registerSampler(intent:.target,sampler:SamplerIntent(columnCount:1))
            if let prior=latest { XCTAssertEqual(attachment.streams.map(\.id),prior.streams.map(\.id)) }
            _=try store.append(SampleRow(values:[Double(i)]),to:attachment.attachmentID)
            try store.finishAttachment(attachment.attachmentID,reason:.eof)
            latest=attachment
        }
        XCTAssertEqual(store.retainedAttachmentCount,1)
        XCTAssertEqual(try store.samples.count(streamID:try XCTUnwrap(latest?.streams[0].id)),30)
    }
    func testLatestEndedGroupRemainsRepairableAndUndoableAfterPruning() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        defer{try? FileManager.default.removeItem(at:dir)}
        let store=try PipePlotStore(databaseURL:dir.appendingPathComponent("state.sqlite"))
        let session=try store.createSession()
        let old=try store.registerSampler(intent:.target,sampler:SamplerIntent(columnCount:2,requestedNames:["a","b"]))
        _=try store.append(SampleRow(values:[1,2]),to:old.attachmentID);try store.finishAttachment(old.attachmentID,reason:.eof)
        let fresh=try store.registerSampler(intent:.fresh,sampler:SamplerIntent(columnCount:2))
        _=try store.append(SampleRow(values:[3,4]),to:fresh.attachmentID);try store.finishAttachment(fresh.attachmentID,reason:.eof)
        XCTAssertEqual(store.samplerGroup(containing:fresh.streams[0].id),fresh.streams.map(\.id))
        try store.reassociateStreams(fresh.streams.map(\.id),to:old.streams.map(\.id))
        XCTAssertEqual(try store.samples.count(streamID:old.streams[0].id),2)
        XCTAssertTrue(try store.undo(sessionID:session.id))
        XCTAssertEqual(try store.samples.count(streamID:fresh.streams[0].id),1)
        XCTAssertEqual(try store.redo(sessionID:session.id),true)
        XCTAssertEqual(try store.samples.count(streamID:old.streams[0].id),2)
    }

    func testExplicitRegistrationUsesSessionMRUAndRejectsAtomically() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        defer{try? FileManager.default.removeItem(at:dir)}
        let store=try PipePlotStore(databaseURL:dir.appendingPathComponent("state.sqlite"))
        let session=try store.createSession()
        let first=session.charts[0].id
        let second=try store.createChart(in:session.id,after:first).id
        _=try store.setTarget(first)
        let ready=try store.registerSampler(intent:.session(sessionID:session.id,lineNames:["named"]),sampler:SamplerIntent(columnCount:1))
        XCTAssertEqual(ready.chartID,first)
        let before=try store.listSessions().count, target=store.currentTarget()
        XCTAssertThrowsError(try store.registerSampler(intent:.newSession,sampler:SamplerIntent(columnCount:2,requestedNames:["same","same"])))
        XCTAssertEqual(try store.listSessions().count,before)
        XCTAssertEqual(store.currentTarget(),target)
        XCTAssertNotEqual(second,first)
    }
    func testColdNewChartUsesOneFreshInitialChart() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        defer{try? FileManager.default.removeItem(at:dir)}
        let db=dir.appendingPathComponent("state.sqlite")
        do {let store=try PipePlotStore(databaseURL:db);_=try store.createSession()}
        let store=try PipePlotStore(databaseURL:db)
        let ready=try store.registerSampler(intent:.newChart,sampler:SamplerIntent(columnCount:1))
        XCTAssertEqual(try store.snapshot(sessionID:ready.sessionID)?.charts.count,1)
    }
    func testFailedMetadataCommitRollsBackEditAndReplayState() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        defer{try? FileManager.default.removeItem(at:dir)}
        let db=dir.appendingPathComponent("state.sqlite"),store=try PipePlotStore(databaseURL:db)
        let session=try store.createSession(),chart=session.charts[0].id
        let start=Date(timeIntervalSince1970:10),selection=TimeSelection(start:start,end:start.addingTimeInterval(5))
        try store.setSelection(selection,sessionID:session.id)
        let metadata=db.appendingPathExtension("metadata.json")
        try FileManager.default.removeItem(at:metadata);try FileManager.default.createDirectory(at:metadata,withIntermediateDirectories:true)
        XCTAssertThrowsError(try store.renameChart(chart,to:"Changed"))
        XCTAssertEqual(try store.snapshot(sessionID:session.id)?.charts[0].title,"Chart 1")
        XCTAssertThrowsError(try store.undo(sessionID:session.id))
        XCTAssertEqual(try store.snapshot(sessionID:session.id)?.timeline.selection,selection)
        XCTAssertEqual(store.undoActionName(sessionID:session.id),"Selection")
    }

    func testUndoCreatedChartMakesCollapsedPredecessorVisible() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        defer{try? FileManager.default.removeItem(at:dir)}
        let store=try PipePlotStore(databaseURL:dir.appendingPathComponent("state.sqlite"))
        let session=try store.createSession(), previous=session.charts[0].id
        _ = try store.createChart(in:session.id,after:previous)
        try store.deleteChart(previous)
        _ = try store.createChart(in:session.id,after:previous)
        XCTAssertFalse(try XCTUnwrap(store.snapshot(sessionID:session.id)?.charts.first{$0.id==previous}).isVisible)
        XCTAssertTrue(try store.undo(sessionID:session.id))
        XCTAssertTrue(try XCTUnwrap(store.snapshot(sessionID:session.id)?.charts.first{$0.id==previous}).isVisible)
    }

    func testLiveOwnerCannotBeTakenByDisconnectedContinuationCandidate() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        defer{try? FileManager.default.removeItem(at:dir)}
        let store=try PipePlotStore(databaseURL:dir.appendingPathComponent("state.sqlite"))
        let old=try store.registerSampler(intent:.target,sampler:SamplerIntent(columnCount:1,requestedNames:["same"]))
        try store.finishAttachment(old.attachmentID,reason:.eof)
        let explicit=try store.registerSampler(intent:.chart(chartID:old.chartID,lineNames:["same"]),sampler:SamplerIntent(columnCount:1))
        let incoming=try store.registerSampler(intent:.target,sampler:SamplerIntent(columnCount:1))
        XCTAssertNotEqual(incoming.streams[0].id,explicit.streams[0].id)
    }

    func testMoveToNewChartIsOneUndoStepAndKeepsLaterProducerVisible() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        defer{try? FileManager.default.removeItem(at:dir)}
        let store=try PipePlotStore(databaseURL:dir.appendingPathComponent("state.sqlite"))
        let session=try store.createSession(), source=session.charts[0].id
        let producer=try store.registerSampler(intent:.chart(chartID:source,lineNames:[]),sampler:SamplerIntent(columnCount:1))
        let made=try store.moveStreamToNewChart(producer.streams[0].id)
        let laterInCreated=try store.registerSampler(intent:.chart(chartID:made.id,lineNames:[]),sampler:SamplerIntent(columnCount:1))
        XCTAssertEqual(store.undoActionName(sessionID:session.id),"Move Stream")
        XCTAssertTrue(try store.undo(sessionID:session.id))
        let later=try store.registerSampler(intent:.chart(chartID:source,lineNames:[]),sampler:SamplerIntent(columnCount:1))
        XCTAssertTrue(try store.redo(sessionID:session.id))
        let snapshot=try XCTUnwrap(store.snapshot(sessionID:session.id))
        XCTAssertTrue(snapshot.charts.first{$0.id==made.id}?.isVisible == true)
        XCTAssertTrue(snapshot.charts.first{$0.id==made.id}?.streams.contains(where:{$0.id==laterInCreated.streams[0].id}) == true)
        XCTAssertTrue(snapshot.charts.first{$0.id==made.id}?.streams.contains(where:{$0.id==producer.streams[0].id}) == true)
        XCTAssertTrue(snapshot.charts.first{$0.id==source}?.streams.contains(where:{$0.id==later.streams[0].id}) == true)
    }

    func testDeletedSessionCanBeRestoredWithoutRestoringLiveAttachment() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        defer{try? FileManager.default.removeItem(at:dir)}
        let store=try PipePlotStore(databaseURL:dir.appendingPathComponent("state.sqlite"))
        let session=try store.createSession(), attachment=try store.registerSampler(intent:.target,sampler:SamplerIntent(columnCount:1))
        try store.deleteSession(sessionID:session.id)
        XCTAssertEqual(try store.listDeletedSessions().map(\.id),[session.id])
        XCTAssertThrowsError(try store.append(SampleRow(values:[3]),to:attachment.attachmentID))
        try store.restoreSession(sessionID:session.id)
        XCTAssertFalse(try XCTUnwrap(store.snapshot(sessionID:session.id)).isDeleted)
        XCTAssertTrue(try store.undo(sessionID:session.id))
        XCTAssertTrue(try XCTUnwrap(store.snapshot(sessionID:session.id)).isDeleted)
    }
    func testDeletedSessionCannotReopenOrRemainAnImplicitTarget() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        defer{try? FileManager.default.removeItem(at:dir)}
        let db=dir.appendingPathComponent("state.sqlite"),store=try PipePlotStore(databaseURL:db)
        let removed=try store.createSession(),remaining=try store.createSession()
        _=try store.setTarget(removed.charts[0].id)
        try store.recordTerminationOpenSessions([removed.id,remaining.id])
        try store.deleteSession(sessionID:removed.id)
        XCTAssertThrowsError(try store.setSessionOpen(true,sessionID:removed.id))
        XCTAssertThrowsError(try store.setTarget(removed.charts[0].id))
        XCTAssertEqual(try store.listSessions().map(\.id),[remaining.id])
        XCTAssertEqual(store.currentTarget(),remaining.charts[0].id)
        XCTAssertEqual(try PipePlotStore(databaseURL:db).previouslyOpenSessionIDs,[remaining.id])
    }
    func testExplicitAttachmentCreatesVisibleChartWhenNamedSessionHasOnlyHiddenCharts() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        defer{try? FileManager.default.removeItem(at:dir)}
        let store=try PipePlotStore(databaseURL:dir.appendingPathComponent("state.sqlite"))
        let named=try store.createSession(),first=named.charts[0].id
        let second=try store.createChart(in:named.id)
        try store.deleteChart(first);try store.deleteChart(second.id)
        let targetSession=try store.createSession(),target=targetSession.charts[0].id
        let attachment=try store.registerSampler(intent:.session(sessionID:named.id,lineNames:["missing"]),sampler:SamplerIntent(columnCount:1))
        XCTAssertNotEqual(attachment.chartID,first)
        XCTAssertTrue(try XCTUnwrap(store.snapshot(sessionID:named.id)?.charts.first{$0.id==attachment.chartID}).isVisible)
        XCTAssertEqual(store.currentTarget(),target)
    }
    func testFailedReassociationCommitRestoresSQLiteSegmentOwnership() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        defer{try? FileManager.default.removeItem(at:dir)}
        let db=dir.appendingPathComponent("state.sqlite"),store=try PipePlotStore(databaseURL:db)
        let old=try store.registerSampler(intent:.target,sampler:SamplerIntent(columnCount:1))
        _=try store.append(SampleRow(values:[1]),to:old.attachmentID);try store.finishAttachment(old.attachmentID,reason:.eof)
        let fresh=try store.registerSampler(intent:.fresh,sampler:SamplerIntent(columnCount:1))
        _=try store.append(SampleRow(values:[2]),to:fresh.attachmentID)
        let metadata=db.appendingPathExtension("metadata.json");try FileManager.default.removeItem(at:metadata);try FileManager.default.createDirectory(at:metadata,withIntermediateDirectories:true)
        XCTAssertThrowsError(try store.reassociateStreams(fresh.streams.map(\.id),to:old.streams.map(\.id)))
        XCTAssertEqual(try store.samples.count(streamID:old.streams[0].id),1)
        XCTAssertEqual(try store.samples.count(streamID:fresh.streams[0].id),1)
    }

    func testUndoCreatedChartKeepsArrivalsAndRedoLeavesLaterLinesAlone() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        defer{try? FileManager.default.removeItem(at:dir)}
        let store=try PipePlotStore(databaseURL:dir.appendingPathComponent("state.sqlite"))
        let session=try store.createSession(title:"Test")
        let prior=session.charts[0].id
        let chart=try store.createChart(in:session.id,after:prior)
        let attachment=try store.registerSampler(intent:.target,sampler:SamplerIntent(columnCount:1))
        let streamID=attachment.streams[0].id
        _=try store.append(SampleRow(values:[1]),to:attachment.attachmentID)
        XCTAssertTrue(try store.undo(sessionID:session.id))
        _=try store.append(SampleRow(values:[2]),to:attachment.attachmentID)
        let unrelated=try store.registerSampler(intent:.chart(chartID:prior,lineNames:[]),sampler:SamplerIntent(columnCount:1))
        XCTAssertTrue(try store.redo(sessionID:session.id))
        let snapshot=try XCTUnwrap(store.snapshot(sessionID:session.id))
        XCTAssertEqual(snapshot.charts.first{$0.id==chart.id}?.streams.map(\.id),[streamID])
        XCTAssertEqual(snapshot.charts.first{$0.id==prior}?.streams.map(\.id),[unrelated.streams[0].id])
        XCTAssertEqual(try store.samples.count(streamID:streamID),2)
        XCTAssertEqual(try store.samples.query(streamID:streamID,limit:10).compactMap(\.segmentID).first,attachment.attachmentID.uuidString.lowercased())
    }

    func testRestoredStoreRetainsSessionNumbersAndClosesSamplers() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        defer{try? FileManager.default.removeItem(at:dir)}
        let db=dir.appendingPathComponent("state.sqlite")
        let sessionID:UUID
        do {
            let store=try PipePlotStore(databaseURL:db);let session=try store.createSession(title:"Persisted")
            sessionID=session.id
            let attachment=try store.registerSampler(intent:.target,sampler:SamplerIntent(columnCount:1))
            _=try store.append(SampleRow(values:[4]),to:attachment.attachmentID)
        }
        let restored=try PipePlotStore(databaseURL:db)
        XCTAssertEqual(restored.previouslyOpenSessionIDs,[sessionID])
        XCTAssertEqual(try restored.snapshot(number:1)?.charts.first?.streams.first?.state,.disconnected)
        XCTAssertEqual(try restored.samples.count(streamID:try XCTUnwrap(restored.snapshot(sessionID:sessionID)?.charts.first?.streams.first?.id)),1)
    }

    func testUndoRedoReplaysNamesSettingsGuidesAndSelections() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        defer{try? FileManager.default.removeItem(at:dir)}
        let store=try PipePlotStore(databaseURL:dir.appendingPathComponent("state.sqlite"))
        let session=try store.createSession(title:"Edits"), chart=session.charts[0].id
        let attachment=try store.registerSampler(intent:.chart(chartID:chart,lineNames:["before"]),sampler:SamplerIntent(columnCount:1))
        let stream=attachment.streams[0].id
        try store.renameStream(stream,to:"after")
        XCTAssertEqual(try store.snapshot(sessionID:session.id)?.charts[0].streams[0].name,"after")
        XCTAssertTrue(try store.undo(sessionID:session.id));XCTAssertEqual(try store.snapshot(sessionID:session.id)?.charts[0].streams[0].name,"before")
        XCTAssertTrue(try store.redo(sessionID:session.id));XCTAssertEqual(try store.snapshot(sessionID:session.id)?.charts[0].streams[0].name,"after")

        let settings=AxisSettings(unit:"MiB",yScale:.fixed(min:-1,max:9),dotsVisible:false,linesVisible:true)
        try store.updateSettings(settings,chartID:chart);XCTAssertTrue(try store.undo(sessionID:session.id));XCTAssertEqual(try store.snapshot(sessionID:session.id)?.charts[0].settings,AxisSettings())
        XCTAssertTrue(try store.redo(sessionID:session.id));XCTAssertEqual(try store.snapshot(sessionID:session.id)?.charts[0].settings,settings)

        let changedMarks=AxisSettings(unit:"MiB",yScale:.fixed(min:-1,max:9),dotsVisible:true,linesVisible:false)
        try store.updateSettings(changedMarks,chartID:chart)
        XCTAssertEqual(try store.snapshot(sessionID:session.id)?.charts[0].streams[0].dotsVisible,true)
        XCTAssertTrue(try store.undo(sessionID:session.id))
        XCTAssertEqual(try store.snapshot(sessionID:session.id)?.charts[0].streams[0].dotsVisible,false)

        let guide=Guide(orientation:.horizontalValue,value:8,label:"limit")
        try store.upsertGuide(guide,chartID:chart);XCTAssertTrue(try store.undo(sessionID:session.id));XCTAssertTrue(try store.snapshot(sessionID:session.id)?.charts[0].guides.isEmpty == true)
        XCTAssertTrue(try store.redo(sessionID:session.id));XCTAssertEqual(try store.snapshot(sessionID:session.id)?.charts[0].guides,[guide])
        let timeGuide=Guide(orientation:.verticalTime,value:15,label:"deploy")
        try store.upsertGuide(timeGuide,chartID:chart)
        XCTAssertEqual(try store.snapshot(sessionID:session.id)?.timeGuides,[timeGuide])
        XCTAssertTrue(try store.undo(sessionID:session.id));XCTAssertTrue(try store.snapshot(sessionID:session.id)?.timeGuides.isEmpty == true)
        XCTAssertTrue(try store.redo(sessionID:session.id));XCTAssertEqual(try store.snapshot(sessionID:session.id)?.timeGuides,[timeGuide])

        let start=Date(timeIntervalSince1970:10),end=Date(timeIntervalSince1970:20)
        let selection=TimeSelection(start:start,end:end,mode:.endFollowsNow,selectedStreamIDs:[stream])
        try store.setSelection(selection,sessionID:session.id);XCTAssertTrue(try store.undo(sessionID:session.id));XCTAssertNil(try store.snapshot(sessionID:session.id)?.timeline.selection)
        XCTAssertTrue(try store.redo(sessionID:session.id));XCTAssertEqual(try store.snapshot(sessionID:session.id)?.timeline.selection,selection)
        let forecast=ForecastConfiguration(streamID:stream,guideID:guide.id,selection:selection)
        try store.setForecast(forecast,sessionID:session.id);XCTAssertTrue(try store.undo(sessionID:session.id));XCTAssertNil(try store.snapshot(sessionID:session.id)?.timeline.forecast)
        XCTAssertTrue(try store.redo(sessionID:session.id));XCTAssertEqual(try store.snapshot(sessionID:session.id)?.timeline.forecast,forecast)
    }

    func testReassociationUndoRedoMovesWholeSegmentsAndLaterArrivals() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        defer{try? FileManager.default.removeItem(at:dir)}
        let store=try PipePlotStore(databaseURL:dir.appendingPathComponent("state.sqlite"))
        let session=try store.createSession(title:"Reassociate")
        let old=try store.registerSampler(intent:.target,sampler:SamplerIntent(columnCount:1))
        _=try store.append(SampleRow(values:[1]),to:old.attachmentID)
        try store.finishAttachment(old.attachmentID,reason:.interrupted)
        let fresh=try store.registerSampler(intent:.fresh,sampler:SamplerIntent(columnCount:1))
        _=try store.append(SampleRow(values:[10]),to:fresh.attachmentID)
        try store.reassociateStreams(fresh.streams.map(\.id),to:old.streams.map(\.id))
        XCTAssertEqual(try store.samples.count(streamID:old.streams[0].id),2)
        XCTAssertEqual(try store.samples.count(streamID:fresh.streams[0].id),0)
        _=try store.append(SampleRow(values:[11]),to:fresh.attachmentID)
        XCTAssertEqual(try store.samples.count(streamID:old.streams[0].id),3)
        XCTAssertTrue(try store.undo(sessionID:session.id))
        XCTAssertEqual(try store.samples.count(streamID:old.streams[0].id),1)
        XCTAssertEqual(try store.samples.count(streamID:fresh.streams[0].id),2)
        let restored = try XCTUnwrap(store.snapshot(sessionID: session.id))
        let restoredOld = try XCTUnwrap(restored.charts.flatMap(\.streams).first(where: { $0.id == old.streams[0].id }))
        let restoredFresh = try XCTUnwrap(restored.charts.flatMap(\.streams).first(where: { $0.id == fresh.streams[0].id }))
        XCTAssertEqual(restoredOld.sampleCount, 1)
        XCTAssertEqual(restoredOld.state, .ended)
        XCTAssertEqual(restoredOld.firstSampleAt, restoredOld.lastSampleAt)
        XCTAssertEqual(restoredFresh.sampleCount, 2)
        XCTAssertEqual(restoredFresh.state, .live)
        _=try store.append(SampleRow(values:[12]),to:fresh.attachmentID)
        XCTAssertTrue(try store.redo(sessionID:session.id))
        XCTAssertEqual(try store.samples.count(streamID:old.streams[0].id),4)
        XCTAssertEqual(try store.samples.count(streamID:fresh.streams[0].id),0)
        XCTAssertEqual(try store.samples.query(streamID:old.streams[0].id,limit:10).map(\.value),[1,10,11,12])
        try store.finishAttachment(fresh.attachmentID,reason:.eof)
    }

    func testReassociationRejectsLiveDestinationBeforeChangingAnything() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        defer{try? FileManager.default.removeItem(at:dir)}
        let store=try PipePlotStore(databaseURL:dir.appendingPathComponent("state.sqlite"))
        _=try store.createSession()
        let first=try store.registerSampler(intent:.target,sampler:SamplerIntent(columnCount:1))
        let second=try store.registerSampler(intent:.target,sampler:SamplerIntent(columnCount:1))
        XCTAssertThrowsError(try store.reassociateStreams(second.streams.map(\.id),to:first.streams.map(\.id)))
        XCTAssertEqual(try store.samples.count(streamID:first.streams[0].id),0)
        XCTAssertEqual(try store.samples.count(streamID:second.streams[0].id),0)
    }
}

extension CoreTests {
    func testLinesDefaultAndClockStopsOnlyAfterFinalAttachment() throws {
        XCTAssertTrue(AxisSettings().linesVisible)
        XCTAssertFalse(AxisSettings().dotsVisible)
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        let db=dir.appendingPathComponent("state.sqlite")
        let store=try PipePlotStore(databaseURL:db)
        let first=try store.registerSampler(intent:.target,sampler:SamplerIntent(columnCount:1))
        let second=try store.registerSampler(intent:.target,sampler:SamplerIntent(columnCount:1))
        try store.finishAttachment(first.attachmentID,reason:.clientDisconnected)
        XCTAssertNil(try store.snapshot(sessionID:first.sessionID)?.timeline.clockStoppedAt)
        let before=Date()
        try store.finishAttachment(second.attachmentID,reason:.clientDisconnected)
        let stopped=try XCTUnwrap(store.snapshot(sessionID:first.sessionID)?.timeline.clockStoppedAt)
        XCTAssertGreaterThanOrEqual(stopped,before)
        try store.finishAttachment(second.attachmentID,reason:.error)
        XCTAssertEqual(try store.snapshot(sessionID:first.sessionID)?.timeline.clockStoppedAt,stopped)
        var timeline=try XCTUnwrap(store.snapshot(sessionID:first.sessionID)).timeline
        timeline.clockStoppedAt=nil;timeline.followNow=false
        try store.updateTimeline(timeline,sessionID:first.sessionID)
        XCTAssertEqual(try store.snapshot(sessionID:first.sessionID)?.timeline.clockStoppedAt,stopped)
        let restored=try PipePlotStore(databaseURL:db)
        XCTAssertEqual(try restored.snapshot(sessionID:first.sessionID)?.timeline.clockStoppedAt,stopped)
        _=try store.registerSampler(intent:.target,sampler:SamplerIntent(columnCount:1))
        XCTAssertNil(try store.snapshot(sessionID:first.sessionID)?.timeline.clockStoppedAt)
    }

    func testMetadataUpgradePreservesExistingSessions() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        let db=dir.appendingPathComponent("state.sqlite")
        let store=try PipePlotStore(databaseURL:db)
        let session=try store.createSession(title:"Existing capture")
        let metadata=db.appendingPathExtension("metadata.json")
        var json=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:metadata)) as? [String:Any])
        var sessions=try XCTUnwrap(json["sessions"] as? [[String:Any]])
        sessions[0].removeValue(forKey:"timeGuides")
        json["sessions"]=sessions
        try JSONSerialization.data(withJSONObject:json).write(to:metadata)
        let upgraded=try PipePlotStore(databaseURL:db)
        XCTAssertEqual(try upgraded.snapshot(sessionID:session.id)?.title,"Existing capture")
        try Data("broken".utf8).write(to:metadata)
        XCTAssertThrowsError(try PipePlotStore(databaseURL:db), "Corrupt metadata must never silently create an empty store")
    }
}
