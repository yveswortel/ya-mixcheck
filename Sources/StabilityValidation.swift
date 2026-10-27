import Foundation
import Darwin

// Integration tests use the production Session and native preparation helper.
// No audio device is opened and every source is generated in a scratch directory.
@MainActor func validateSessionStability() throws -> [TestOutcome] {
    let fm=FileManager.default,root=fm.temporaryDirectory.appendingPathComponent("ya-session-stress-"+UUID().uuidString)
    try fm.createDirectory(at:root,withIntermediateDirectories:false)
    defer{try? fm.removeItem(at:root)}
    let a=root.appendingPathComponent("A.wav"),b=root.appendingPathComponent("B.wav"),bad=root.appendingPathComponent("invalid.wav")
    for (url,hz) in [(a,80.0),(b,997.0)] {
        try writeTestAudio(url,samples:(0..<48000*12*2).map{Float(0.1*sin(2*Double.pi*hz*Double($0/2)/48000))},rate:48000,channels:2)
    }
    try Data("invalid audio".utf8).write(to:bad)
    let hashA=try sha256(a),hashB=try sha256(b)
    let s=Session(),oldGenre=s.genre,oldPurpose=s.purpose
    defer{s.cleanup();UserDefaults.standard.set(oldGenre,forKey:"genre");UserDefaults.standard.set(oldPurpose,forKey:"purpose")}
    var out=[TestOutcome]()
    func check(_ name:String,_ passed:Bool,_ detail:String=""){out.append(TestOutcome(name:"Session stress: "+name,passed:passed,detail:detail))}
    func drain()throws {
        let end=Date().addingTimeInterval(30)
        while (s.busy || s.engineerComputing) && Date()<end{RunLoop.current.run(until:Date().addingTimeInterval(0.005))}
        guard !s.busy,!s.engineerComputing else{throw QCFailure(message:"Session stress worker exceeded 30 seconds")}
    }
    var ticks=0,maxGap=0.0,last=ProcessInfo.processInfo.systemUptime
    let timer=Timer.scheduledTimer(withTimeInterval:0.01,repeats:true){_ in
        let now=ProcessInfo.processInfo.systemUptime;maxGap=max(maxGap,now-last);last=now;ticks+=1
    }
    defer{timer.invalidate()}
    for iteration in 1...6 {
        s.load(a)
        s.load(b) // A pending load must not replace its token with a second source.
        try drain()
        check("busy load cannot replace active source \(iteration)",s.result?.sha256==hashA && s.result?.originalSource==a.path)
        let previous=s.result!.inputSnapshot!.directory
        for n in 0..<30 {s.genre=n%2==0 ? "EDM/house":"Pop/R&B";s.purpose=n%2==0 ? "Release/master":"Mix voor mastering"}
        try drain()
        let expected=mixRecommendations(s.result!,genre:s.genre,purpose:s.purpose)
        check("last context wins after rapid edits \(iteration)",s.recommendations.map{$0.id}==expected.map{$0.id})
        s.load(b,reference:true);try drain()
        check("reference and source remain distinct \(iteration)",s.result?.sha256==hashA && s.reference?.sha256==hashB)
        for _ in 0..<10{s.switchSource()}
        check("rapid A/B stays stopped and returns to A \(iteration)",!s.usingReference && !s.playing && !s.transport.isConfigured)
        s.load(bad,reference:true);try drain()
        check("bad reference keeps valid A \(iteration)",s.result?.sha256==hashA && s.reference==nil && !s.message.isEmpty)
        s.load(b);s.cancellation.cancel();try drain()
        check("cancelled new A never restores old result \(iteration)",s.result==nil && s.reference==nil && !s.playing)
        check("superseded snapshot released \(iteration)",!fm.fileExists(atPath:previous.path))
        s.load(b);try drain()
        check("valid file recovers after cancel \(iteration)",s.result?.sha256==hashB && s.message.isEmpty)
        s.load(bad);try drain()
        check("bad main source leaves no stale analysis \(iteration)",s.result==nil && s.recommendations.isEmpty && !s.playing && !s.message.isEmpty)
    }
    try fm.setAttributes([.posixPermissions:0],ofItemAtPath:a.path)
    s.load(a);try drain()
    check("unreadable source fails recoverably",s.result==nil && !s.message.isEmpty)
    try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:a.path)
    s.load(a);try drain()
    check("permission restored accepts original",s.result?.sha256==hashA)
    // Finish the worker while its main-queue completion is held back by this test.
    s.load(b)
    let gate=DispatchSemaphore(value:0);s.queue.async{gate.signal()}
    guard gate.wait(timeout:.now()+20) == .success else{throw QCFailure(message:"Closing-load regression did not finish its worker")}
    s.cleanup()
    try drain()
    check("close during queued completion cannot publish",s.result==nil && s.eqPreview==nil && !s.playing)
    check("source bytes unchanged",try sha256(a)==hashA && sha256(b)==hashB)
    // The intentional worker barrier above is not a UI-responsiveness sample.
    check("main runloop serviced during repeated native work",ticks>50,"ticks=\(ticks); max interval (includes deliberate barrier)=\(maxGap)s")
    return out
}

// Process-isolated fault probe. The Python driver owns its source, TMPDIR,
// output and any disposable volume. This is never selected by normal GUI use.
func runStabilityProbe(mode:String,source:URL,output:URL)throws {
    let fm=FileManager.default
    guard let directory=ProcessInfo.processInfo.environment["YA_MIXCHECK_STABILITY_TMP"] else{throw QCFailure(message:"Stability probe requires its isolated scratch directory")}
    var isDirectory:ObjCBool=false
    guard fm.fileExists(atPath:directory,isDirectory:&isDirectory),isDirectory.boolValue else{throw QCFailure(message:"Stability scratch directory missing")}
    SnapshotStorage.validationRoot=URL(fileURLWithPath:directory,isDirectory:true)
    defer{SnapshotStorage.validationRoot=nil}
    func save(_ object:[String:Any])throws {
        try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys,.prettyPrinted]).write(to:output,options:.atomic)
    }
    let root=SnapshotStorage.temporaryDirectory
    if mode=="recover" {SnapshotStorage.recover(in:source);try save(["ok":true]);return}
    if mode=="coordinate" {
        var error:NSError?
        NSFileCoordinator().coordinate(writingItemAt:source,options:[],error:&error){_ in
            try? save(["locked":true,"pid":getpid()]);Thread.sleep(forTimeInterval:60)
        }
        if let error{throw error};return
    }
    let before=Set((try? fm.contentsOfDirectory(atPath:root.path)) ?? [])
    let start=ProcessInfo.processInfo.systemUptime
    var state:[String:Any]=["mode":mode,"temporaryRoot":root.path,"pid":getpid()]
    do {
        switch mode {
        case "prepare","hold":
            let input=try PreparedInput.prepare(source,cancellation:Cancellation(),timeout:5)
            state["snapshot"]=input.directory.path;state["bytes"]=input.receipt.bytes
            if mode=="hold" {state["held"]=true;try save(state);withExtendedLifetime(input){Thread.sleep(forTimeInterval:60)}}
            input.remove()
        case "decode":
            let a=try Analyzer.run(source);state["frames"]=a.frames;a.decodedAudio?.remove()
        case "eq":
            let a=try Analyzer.run(source,makePreview:false)
            let preview=try renderEQPreview(PreviewSource(a),bands:[PreviewBand(hz:350,gain:2)],cancellation:Cancellation(),progress:{_ in})
            preview.remove()
        default: throw QCFailure(message:"Unknown stability probe mode")
        }
        state["ok"]=true
    } catch {
        let e=error as NSError;state["ok"]=false;state["error"]=e.localizedDescription;state["domain"]=e.domain;state["code"]=e.code
    }
    SnapshotStorage.cleanup()
    let after=Set((try? fm.contentsOfDirectory(atPath:root.path)) ?? [])
    state["newTemporaryEntries"]=Array(after.subtracting(before)).sorted()
    state["seconds"]=ProcessInfo.processInfo.systemUptime-start
    try save(state)
}
