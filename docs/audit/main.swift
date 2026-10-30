import Foundation
let auditDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("pipeplot-audit-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: auditDirectory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: auditDirectory) }
func fresh() throws -> PipePlotStore { try PipePlotStore(databaseURL: auditDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")) }
do {
 let s=try fresh();let a=try s.registerSampler(intent:.target,sampler:SamplerIntent(columnCount:1));try s.finishAttachment(a.attachmentID,reason:.eof)
 let b=try s.registerSampler(intent:.session(sessionID:a.sessionID,lineNames:[a.streams[0].name]),sampler:SamplerIntent(columnCount:1))
 let c=try s.registerSampler(intent:.target,sampler:SamplerIntent(columnCount:1))
 print("LIVE_OWNER_HIJACK",b.streams[0].id==c.streams[0].id,"continued",c.continued)
}
do {
 let s=try fresh();let se=try s.createSession();let c1=se.charts[0].id;let c2=try s.createChart(in:se.id).id;_ = try s.setTarget(c1)
 let r=try s.registerSampler(intent:.session(sessionID:se.id,lineNames:["new"]),sampler:SamplerIntent(columnCount:1))
 print("EXPLICIT_USES_LAST_NOT_MRU",r.chartID==c2)
}
do {
 let s=try fresh();let se=try s.createSession();let c1=se.charts[0].id;let c2=try s.createChart(in:se.id).id
 let a=try s.registerSampler(intent:.chart(chartID:c1,lineNames:[]),sampler:SamplerIntent(columnCount:1));try s.moveStream(a.streams[0].id,to:c2);_ = try s.undo(sessionID:se.id)
 let later=try s.registerSampler(intent:.chart(chartID:c1,lineNames:["later"]),sampler:SamplerIntent(columnCount:1));_ = try s.redo(sessionID:se.id)
 let snap=try s.snapshot(sessionID:se.id)!;let chart=snap.charts.first{$0.id==c1}!
 print("REDO_HIDES_LATER_PRODUCER",!chart.isVisible && chart.streams.contains{$0.id==later.streams[0].id})
}
do {
 let s=try fresh();let a=try s.registerSampler(intent:.target,sampler:SamplerIntent(columnCount:1));let before=try s.listSessions().count
 do { _ = try s.registerSampler(intent:.newSession,sampler:SamplerIntent(columnCount:2,requestedNames:["same","same"])) } catch { }
 print("REJECTED_REQUEST_CREATED_SESSION",try s.listSessions().count-before,"CHANGED_TARGET",s.currentTarget() != a.chartID)
}
do {
 let s=try fresh();let a=try s.registerSampler(intent:.target,sampler:SamplerIntent(columnCount:1,unitHint:"MiB"));let snap=try s.snapshot(sessionID:a.sessionID)!
 print("UNIT_HINT_NOT_APPLIED",snap.charts[0].settings.unit == nil)
}
