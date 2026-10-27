import Foundation

// Real temporary renders, but no audio-device playback. Synthetic tone metadata
// makes the correction deterministic; these tests exercise cache ownership.
@MainActor func validateEQPreviewCache() throws->[TestOutcome] {
    var out=[TestOutcome]()
    func check(_ name:String,_ pass:Bool,_ detail:String=""){out.append(TestOutcome(name:"EQ cache: "+name,passed:pass,detail:detail))}
    let fm=FileManager.default,dir=fm.temporaryDirectory.appendingPathComponent("ya-eq-cache-test-"+UUID().uuidString)
    try fm.createDirectory(at:dir,withIntermediateDirectories:false)
    defer{try? fm.removeItem(at:dir)}
    let source=dir.appendingPathComponent("original.wav"),ref=dir.appendingPathComponent("reference.wav")
    let samples=(0..<48000*12*2).map{Float(0.1*sin(2*Double.pi*80*Double($0/2)/48000))}
    try writeTestAudio(source,samples:samples,rate:48000,channels:2)
    try fm.copyItem(at:source,to:ref)
    let sourceHash=try sha256(source),refHash=try sha256(ref)
    var a=try Analyzer.run(source,makePreview:false)
    a.toneSlices=(0..<6).map{i in ToneSlice(start:Double(i*2),duration:2,rms:-20,bands:[-1,-80,-90,-90,-90,-90,-90,-90],lowContrast:0,lowMono:0)}
    let s=Session(),oldGenre=s.genre,oldPurpose=s.purpose
    let oldOverrides=UserDefaults.standard.object(forKey:"referenceIdentityOverrides")
    defer{s.cleanup();UserDefaults.standard.set(oldGenre,forKey:"genre");UserDefaults.standard.set(oldPurpose,forKey:"purpose");UserDefaults.standard.set(oldOverrides,forKey:"referenceIdentityOverrides")}
    func finishWork()throws {
        let end=Date().addingTimeInterval(30)
        while s.busy && Date()<end {RunLoop.current.run(until:Date().addingTimeInterval(0.005))}
        guard !s.busy else{throw QCFailure(message:"EQ cache test worker timed out")}
    }
    func rendered()throws->EQPreviewResult {
        s.toggleEQ();try finishWork()
        guard let p=s.eqPreview else{throw QCFailure(message:"EQ cache fixture render failed: "+s.message)}
        return p
    }
    s.result=a;s.genre="EDM/house"
    let first=try rendered(),firstHash=try sha256(first.url),bands=first.bands
    check("first render published and enabled",s.eqEnabled && !bands.isEmpty)
    s.toggleEQ();s.toggleEQ()
    check("original/EQ toggles reuse exact artifact",s.eqPreview === first && s.eqEnabled && !s.busy)
    s.stop();s.seek(4);s.tonalLoud=true;s.selectedSection=0;s.manualBounds=[4,8]
    s.purpose="Mix voor mastering"
    check("stop seek chart and purpose preserve render",try s.eqPreview === first && sha256(first.url)==firstHash)
    s.comparisonMode="Passages"
    check("passage mode retains render but disables whole-track EQ",s.eqPreview === first && !s.eqEnabled)
    s.toggleEQ()
    check("cached EQ returns to whole-track matching without rendering",s.eqPreview === first && s.eqEnabled && !s.busy && s.comparisonMode=="Hele nummer")
    s.passageLength=3;s.measurePassages();try finishWork()
    check("measuring passages preserves cached render",s.passageA != nil && s.eqPreview === first && !s.eqEnabled)
    s.comparisonMode="Hele nummer";s.toggleEQ()
    s.load(ref,reference:true)
    check("reference load does not discard A preview",s.busy && s.eqPreview === first)
    try finishWork()
    check("reference ready reuses finalized preview",try s.reference != nil && s.eqPreview === first && sha256(first.url)==firstHash,"Reference: \(s.reference != nil); cached: \(s.eqPreview === first); message: \(s.message)")
    s.switchSource();s.switchSource()
    check("A/B switching preserves A render",!s.usingReference && s.eqPreview === first)
    s.load(dir.appendingPathComponent("missing.wav"),reference:true);try finishWork()
    check("failed B import retains A render",s.reference==nil && s.eqPreview === first && s.result != nil)
    s.genre="Alternative/indie"
    check("identical corrections across genres reuse render",s.eqPlan.bands==bands && s.eqPreview === first,"Before: \(bands); after: \(s.eqPlan.bands)")
    s.setReferenceIdentity("none")
    check("unchanged correction after identity edit reuses render",s.eqPreview === first)
    s.genre="Trap/hiphop"
    check("genre with different corrections releases cached render",s.eqPlan.bands != bands && s.eqPreview==nil && !fm.fileExists(atPath:first.url.path))
    s.genre="EDM/house"
    let beforeToneChange=try rendered()
    // Use the same audio identity with different measured tone evidence, to
    // verify that matching is based on the resulting coefficients, not genre alone.
    var changed=a
    changed.toneSlices=(0..<6).map{i in ToneSlice(start:Double(i*2),duration:2,rms:-20,bands:[-90,-90,-90,-90,-1,-90,-90,-90],lowContrast:0,lowMono:0)}
    s.result=changed
    check("changed corrections discard old render and file",s.eqPlan.bands != bands && s.eqPreview==nil && !fm.fileExists(atPath:beforeToneChange.url.path))
    let second=try rendered()
    try fm.removeItem(at:second.url)
    let rebuilt=try rendered()
    check("missing temporary artifact is rebuilt",rebuilt.url != second.url && fm.fileExists(atPath:rebuilt.url.path))
    var sameBytesNewPath=changed;sameBytesNewPath.source=ref.path
    s.result=sameBytesNewPath
    check("different source path invalidates even with same audio hash",s.eqPreview==nil && !fm.fileExists(atPath:rebuilt.url.path))
    s.result=a;s.genre="EDM/house"
    let beforeCancel=try rendered()
    let gate=DispatchSemaphore(value:0);s.queue.async{_ = gate.wait(timeout:.now()+10)}
    s.load(ref,reference:true);s.cancellation.cancel();gate.signal();try finishWork()
    check("cancelled B import preserves A render",s.eqPreview === beforeCancel && s.reference==nil)
    s.load(source)
    check("new A import releases previous render",s.eqPreview==nil && !fm.fileExists(atPath:beforeCancel.url.path))
    s.cancellation.cancel();try finishWork()
    s.result=a;s.genre="EDM/house"
    let renderGate=DispatchSemaphore(value:0);s.queue.async{_ = renderGate.wait(timeout:.now()+10)}
    s.toggleEQ();s.genre="Anders/onbekend";renderGate.signal();try finishWork()
    check("changed plan rejects in-flight completion",s.eqPreview==nil && !s.eqEnabled && s.message=="Preview geannuleerd.")
    s.genre="EDM/house"
    let final=try rendered();s.cleanup()
    check("cleanup releases last render",s.eqPreview==nil && !fm.fileExists(atPath:final.url.path))
    check("original and reference bytes unchanged",try sha256(source)==sourceHash && sha256(ref)==refHash)
    return out
}
