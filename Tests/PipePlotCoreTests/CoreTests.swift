import XCTest
@testable import PipePlotCore

final class CoreTests: XCTestCase {
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
        XCTAssertEqual(p.append(Data([49,0,50,10])).first.map { if case .rejected(let issue)=$0{return issue.kind};return nil },.nulByte)
        let oversized=InputParser().append(Data(repeating:65,count:InputParser.maximumLineBytes+1)+Data([10]))
        XCTAssertEqual(oversized.first.map { if case .rejected(let issue)=$0{return issue.kind};return nil },.tooLong)
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

        let guide=Guide(orientation:.horizontalValue,value:8,label:"limit")
        try store.upsertGuide(guide,chartID:chart);XCTAssertTrue(try store.undo(sessionID:session.id));XCTAssertTrue(try store.snapshot(sessionID:session.id)?.charts[0].guides.isEmpty == true)
        XCTAssertTrue(try store.redo(sessionID:session.id));XCTAssertEqual(try store.snapshot(sessionID:session.id)?.charts[0].guides,[guide])

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
