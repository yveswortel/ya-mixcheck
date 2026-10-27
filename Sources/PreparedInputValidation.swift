import Foundation
func validatePreparedInput()throws->[TestOutcome] {
    var results=[TestOutcome]()
    func check(_ name:String,_ ok:Bool,_ detail:String=""){results.append(TestOutcome(name:name,passed:ok,detail:detail))}
    let fm=FileManager.default,dir=fm.temporaryDirectory.appendingPathComponent("ya-input-test-"+UUID().uuidString)
    try fm.createDirectory(at:dir,withIntermediateDirectories:false);defer{try? fm.removeItem(at:dir)}
    let source=dir.appendingPathComponent("local.wav")
    try writeTestAudio(source,samples:(0..<48000*2).map{Float(0.2*sin(Double($0)*0.13))},rate:48000,channels:1)
    let hash=try sha256(source)
    var phases=[String]()
    var prepared:PreparedInput?=try PreparedInput.prepare(source,cancellation:Cancellation(),status:{phases.append($0)})
    let snapshotURL=prepared!.url,copyDir=prepared!.directory
    check("Snapshot is byte-identical",try sha256(snapshotURL)==hash)
    check("Input snapshot is outside source directory",snapshotURL.deletingLastPathComponent() != dir)
    check("Snapshot has local status",prepared!.receipt.cloudStatus=="local")
    check("Preparation reports phases",phases.contains("Bestand beschikbaar maken…") && phases.last=="Bestand analyseren…")
    var analysis:Analysis?=try Analyzer.run(snapshotURL,makePreview:false);analysis!.inputSnapshot=prepared;analysis!.originalSource=source.path
    analysis!.modifiedAt=prepared!.receipt.sourceModifiedAt!;analysis!.byteCount=prepared!.receipt.bytes
    check("Original metadata matches receipt",analysis!.modifiedAt==prepared!.receipt.sourceModifiedAt)
    check("Unchanged original recognized",analysis!.sourceIsUnchanged())
    let savedDate=analysis!.modifiedAt
    try fm.setAttributes([.modificationDate:savedDate.addingTimeInterval(10)],ofItemAtPath:source.path)
    check("Replaced original detected despite intact snapshot",!analysis!.sourceIsUnchanged())
    check("EQ source also detects changed original",!PreviewSource(analysis!).sourceIsUnchanged())
    try fm.setAttributes([.modificationDate:savedDate],ofItemAtPath:source.path)
    prepared=nil
    check("Analysis retains snapshot",fm.fileExists(atPath:snapshotURL.path))
    check("Snapshot analyzes without changed bytes",analysis!.sha256==hash && analysis!.frames==96000)
    analysis=nil
    check("Releasing analysis cleans snapshot",!fm.fileExists(atPath:copyDir.path))
    let before=Set((try fm.contentsOfDirectory(atPath:fm.temporaryDirectory.path)).filter{$0.hasPrefix("ya-mixcheck-input-")})
    let start=ProcessInfo.processInfo.systemUptime
    do{_ = try PreparedInput.prepare(source,cancellation:Cancellation(),timeout:0.3,workerArguments:["--input-worker-stall"]);check("Stalled worker times out",false)}catch{check("Stalled worker times out",ProcessInfo.processInfo.systemUptime-start<3,error.localizedDescription)}
    let token=Cancellation()
    DispatchQueue.global().asyncAfter(deadline:.now()+0.2){token.cancel()}
    let cancelStart=ProcessInfo.processInfo.systemUptime
    do{_ = try PreparedInput.prepare(source,cancellation:token,workerArguments:["--input-worker-stall"]);check("Stalled worker is cancellable",false)}catch{check("Stalled worker is cancellable",ProcessInfo.processInfo.systemUptime-cancelStart<3,error.localizedDescription)}
    do{_ = try PreparedInput.prepare(dir.appendingPathComponent("missing.wav"),cancellation:Cancellation());check("Missing input fails recoverably",false)}catch{check("Missing input fails recoverably",true,error.localizedDescription)}
    let after=Set((try fm.contentsOfDirectory(atPath:fm.temporaryDirectory.path)).filter{$0.hasPrefix("ya-mixcheck-input-")})
    check("Failures and cancellation leave no snapshot directories",before==after)
    let recovery=try PreparedInput.prepare(source,cancellation:Cancellation())
    check("New input succeeds after timeout/cancel",try sha256(recovery.url)==hash)
    check("Original remains unchanged",try sha256(source)==hash)
    let liveDir=dir.appendingPathComponent("ya-mixcheck-input-live")
    let deadDir=dir.appendingPathComponent("ya-mixcheck-input-dead")
    let unknownDir=dir.appendingPathComponent("ya-mixcheck-input-unknown")
    for p in [liveDir,deadDir,unknownDir]{try fm.createDirectory(at:p,withIntermediateDirectories:false)}
    try SnapshotStorage.register(liveDir)
    fm.createFile(atPath:deadDir.appendingPathComponent("owner.lock").path,contents:Data())
    for p in [liveDir,deadDir,unknownDir]{try fm.setAttributes([.modificationDate:Date().addingTimeInterval(-600)],ofItemAtPath:p.path)}
    SnapshotStorage.recover(in:dir)
    check("Recovery removes abandoned leased directory",!fm.fileExists(atPath:deadDir.path))
    check("Recovery preserves active lease",fm.fileExists(atPath:liveDir.path))
    check("Recovery leaves unowned directories alone",fm.fileExists(atPath:unknownDir.path))
    SnapshotStorage.cleanup()
    check("Termination cleanup removes live registered directory",!fm.fileExists(atPath:liveDir.path))
    recovery.remove();recovery.remove()
    check("Explicit cleanup is idempotent with retained object",!fm.fileExists(atPath:recovery.directory.path))
    check("Original remains after explicit cleanup",try sha256(source)==hash)
    return results
}
