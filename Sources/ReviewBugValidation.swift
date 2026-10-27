import Foundation
func validateReviewBugs() throws->[TestOutcome] {
    var out=[TestOutcome]()
    func check(_ name:String,_ pass:Bool,_ detail:String=""){out.append(TestOutcome(name:"Review fixes: "+name,passed:pass,detail:detail))}
    check("missing tone library explicit",ToneLibrary.load(nil).loadIssue != nil)
    check("malformed dynamics library explicit",DynamicsLibrary.load(Data("oops".utf8)).loadIssue != nil)
    check("unsupported tone version explicit",ToneLibrary.load(Data("{\"version\":\"99\",\"method\":\"test\",\"references\":[]}".utf8)).loadIssue != nil)
    check("unsupported dynamics version explicit",DynamicsLibrary.load(Data("{\"version\":\"99\",\"references\":[]}".utf8)).loadIssue != nil)
    check("bundled libraries load",ToneLibrary.shared.loadIssue==nil && DynamicsLibrary.shared.loadIssue==nil && ToneLibrary.shared.references.count>=5 && DynamicsLibrary.shared.references.count>=5)
    let slices=(0..<12).map{i in ToneSlice(start:Double(i*2),duration:2,rms:i<6 ? -25:-15,bands:(0..<8).map{b in Double((i<6 && b==3) ? -22:-35)},lowContrast:0,lowMono:0)}
    let quiet=assessTone(slices,genre:"test",hash:"",quiet:true)
    let expected=summarizeTone(slices,quiet:true)
    check("quiet assessment selects same quiet population as references",quiet.summary.bands==expected.bands && quiet.summary.seconds==12)
    for rate in [44100,48000,88200,96000,176400,192000] {
        for frequency in [15.0,22.0] {
            let n=rate*4,q=qc_create(Int32(rate),1,Int64(n))!
            defer{qc_destroy(q)}
            var pos=0
            while pos<n {
                let count=min(8192,n-pos)
                let x=(0..<count).map{Float(0.3*sin(2*Double.pi*frequency*Double(pos+$0)/Double(rate)))}
                let status=x.withUnsafeBufferPointer{qc_push(q,$0.baseAddress!,Int32(count))}
                guard status==0 else{throw QCFailure(message:"Spectrum fixture failed")};pos+=count
            }
            _=qc_finish(q)
            let low=qc_low_bands(q)!, total=(0..<5).reduce(0.0){$0+low[$1]}
            check("\(rate) Hz / \(frequency) Hz spectral energy",abs(total-0.045)<0.0001)
            let leak=frequency==15 ? low[1]:low[0]
            check("\(rate) Hz / \(frequency) Hz boundary leakage",leak/0.045<0.001,"Leakage \(10*log10(max(1e-30,leak/0.045))) dB relative to tone")
        }
    }
    return out
}

@MainActor func validateSessionRegression(_ url:URL)throws->Data {
    let a=try Analyzer.run(url,makePreview:false)
    defer{a.decodedAudio?.remove()}
    let s=Session(),oldGenre=s.genre,oldPurpose=s.purpose
    defer{s.cleanup();UserDefaults.standard.set(oldGenre,forKey:"genre");UserDefaults.standard.set(oldPurpose,forKey:"purpose")}
    var results=[TestOutcome]()
    func check(_ name:String,_ pass:Bool,_ detail:String=""){results.append(TestOutcome(name:name,passed:pass,detail:detail))}
    let begin=Date()
    s.result=a;s.genre="EDM/house";s.genre="Pop/R&B";s.purpose="Mix voor mastering"
    let setterTime=Date().timeIntervalSince(begin)
    check("Advice scheduling does not calculate synchronously",setterTime<0.2,"\(setterTime) seconds")
    check("Pending advice is not shown as no concerns",s.engineerComputing && s.recommendations.isEmpty)
    let deadline=Date().addingTimeInterval(30)
    var ticks=0
    while s.engineerComputing && Date()<deadline {RunLoop.current.run(until:Date().addingTimeInterval(0.01));ticks+=1}
    let expected=mixRecommendations(a,genre:"Pop/R&B",purpose:"Mix voor mastering")
    check("Latest context wins after rapid changes",!s.engineerComputing && s.recommendations.map{$0.id}==expected.map{$0.id})
    check("Main runloop remains available during advice",ticks>0,"\(ticks) runloop opportunities")
    s.genre="Trap/hiphop";s.result=nil
    RunLoop.current.run(until:Date().addingTimeInterval(0.3))
    check("Clearing input discards stale background results",!s.engineerComputing && s.recommendations.isEmpty && s.dynamicsReview==nil)
    // Cancellation must win even if worker completion is already queued on main.
    s.result=a;s.passageLength=min(3,a.duration);s.passageAStart=0;s.passageBStart=0
    s.measurePassages();s.cancellation.cancel()
    let cancelDeadline=Date().addingTimeInterval(30)
    while s.busy && Date()<cancelDeadline {RunLoop.current.run(until:Date().addingTimeInterval(0.01))}
    check("Cancelled passage never publishes",!s.busy && s.passageA==nil && s.passageB==nil)
    s.measurePassages();s.passageAStart=1
    let staleDeadline=Date().addingTimeInterval(30)
    while s.busy && Date()<staleDeadline {RunLoop.current.run(until:Date().addingTimeInterval(0.01))}
    check("Changed passage range rejects queued completion",!s.busy && s.passageA==nil && s.passageB==nil)

    // Exercise playback verification without opening an audio device. Missing or
    // deliberately invalid disposable sources make even a failed guard silent.
    let fm=FileManager.default,playbackDir=fm.temporaryDirectory.appendingPathComponent("ya-playback-test-"+UUID().uuidString)
    try fm.createDirectory(at:playbackDir,withIntermediateDirectories:false)
    defer{try? fm.removeItem(at:playbackDir)}
    var missing=a;missing.source=playbackDir.appendingPathComponent("missing.wav").path
    missing.inputSnapshot=nil;missing.originalSource=nil;missing.decodedAudio=nil
    let sentinel="Existing footer remains stable"
    func resetPlayback(_ fixture:Analysis) {
        s.stop();s.busy=false;s.comparisonMode="Hele nummer";s.usingReference=false
        s.result=fixture;s.message=sentinel
    }
    func holdPlaybackQueue()->DispatchSemaphore {
        let gate=DispatchSemaphore(value:0)
        s.queue.async{_ = gate.wait(timeout:.now()+10)}
        return gate
    }
    func drainPlaybackWorker()throws {
        let drained=DispatchSemaphore(value:0);s.queue.async{drained.signal()}
        guard drained.wait(timeout:.now()+5) == .success else{throw QCFailure(message:"Playback regression worker did not drain within 5 seconds.")}
    }
    func drainPlaybackMain()throws {
        var drained=false;DispatchQueue.main.async{drained=true}
        let deadline=Date().addingTimeInterval(5)
        while !drained && Date()<deadline{RunLoop.current.run(until:Date().addingTimeInterval(0.005))}
        guard drained else{throw QCFailure(message:"Playback regression main queue did not drain within 5 seconds.")}
    }
    resetPlayback(missing)
    let analysisToken=s.cancellation,firstGate=holdPlaybackQueue()
    s.play()
    check("Playback verification preserves results layout and analysis cancellation",s.playbackChecking && !s.busy && !s.playing && s.message==sentinel && s.cancellation === analysisToken)
    s.play()
    check("Second space cancels pending playback",!s.playbackChecking && !s.playing && !s.transport.isConfigured && s.message==sentinel)
    firstGate.signal();try drainPlaybackWorker();try drainPlaybackMain()
    check("Cancelled verification does not publish an error or player",!s.playbackChecking && !s.playing && !s.transport.isConfigured && s.message==sentinel)

    resetPlayback(missing);s.play();try drainPlaybackWorker()
    s.stop();try drainPlaybackMain()
    check("Stop invalidates verification already queued on main",!s.playbackChecking && !s.playing && !s.transport.isConfigured && s.message==sentinel)

    resetPlayback(missing);s.play();try drainPlaybackWorker();s.stop()
    let newerGate=holdPlaybackQueue();s.play();try drainPlaybackMain()
    check("Old completion cannot clear a newer pending playback",s.playbackChecking && !s.busy && !s.playing && s.message==sentinel && s.cancellation === analysisToken)
    s.stop();newerGate.signal();try drainPlaybackWorker();try drainPlaybackMain()

    resetPlayback(missing);s.play();try drainPlaybackWorker()
    var other=missing;other.source += ".other";other.sha256 += "-other";s.result=other
    try drainPlaybackMain()
    check("Changed source identity rejects pending playback",!s.playbackChecking && !s.playing && !s.transport.isConfigured && s.message==sentinel)

    resetPlayback(missing);s.play();try drainPlaybackWorker();s.busy=true
    try drainPlaybackMain()
    check("Global operation blocks pending playback without changing its state",s.busy && !s.playbackChecking && !s.playing && !s.transport.isConfigured && s.message==sentinel)
    s.busy=false

    // An intact local snapshot must not authorize an altered or deleted original.
    // These are generated bytes, never the supplied music fixture or its snapshot.
    let original=playbackDir.appendingPathComponent("original.wav")
    let snapshotDir=playbackDir.appendingPathComponent("snapshot",isDirectory:true)
    try fm.createDirectory(at:snapshotDir,withIntermediateDirectories:false)
    let snapshotURL=snapshotDir.appendingPathComponent("snapshot.wav")
    try Data(repeating:0x51,count:64).write(to:original)
    try fm.copyItem(at:original,to:snapshotURL)
    let attrs=try fm.attributesOfItem(atPath:original.path)
    let originalDate=attrs[.modificationDate] as! Date
    let snapshot=PreparedInput(directory:snapshotDir,url:snapshotURL,original:original,receipt:InputReceipt(bytes:64,cloudStatus:"local",sourceModifiedAt:originalDate))
    var snapshotted=missing;snapshotted.source=snapshotURL.path;snapshotted.originalSource=original.path;snapshotted.inputSnapshot=snapshot
    try fm.setAttributes([.modificationDate:originalDate.addingTimeInterval(10)],ofItemAtPath:original.path)
    resetPlayback(snapshotted);s.play();try drainPlaybackWorker();try drainPlaybackMain()
    check("Changed original refuses playback despite intact snapshot",snapshot.snapshotIsIntact() && !s.playbackChecking && !s.playing && !s.transport.isConfigured && s.message.contains("Origineel gewijzigd"))
    try fm.removeItem(at:original)
    resetPlayback(snapshotted);s.play();try drainPlaybackWorker();try drainPlaybackMain()
    check("Missing original refuses playback despite intact snapshot",snapshot.snapshotIsIntact() && !s.playbackChecking && !s.playing && !s.transport.isConfigured && s.message.contains("Origineel gewijzigd"))

    // Chart filters are display choices; preview correction and its availability
    // must stay based on all the audio. Construct a clear, long enough imbalance.
    var tonalFixture=a;tonalFixture.sha256="eq-plan-fixture-"+a.sha256;tonalFixture.referenceIdentity=nil
    tonalFixture.frames=Int64(24*a.sampleRate)
    tonalFixture.toneSlices=(0..<12).map{i in ToneSlice(start:Double(i*2),duration:2,rms:i<6 ? -25:-15,bands:[-1,-80,-90,-90,-90,-90,-90,-90],lowContrast:0,lowMono:0)}
    resetPlayback(tonalFixture);s.genre="EDM/house";s.tonalLoud=false;s.selectedSection = -1;s.manualBounds=nil
    func planKey(_ plan:EQPreviewPlan)throws->String {
        let e=JSONEncoder();e.outputFormatting=[.sortedKeys]
        return String(decoding:try e.encode(plan.bands),as:UTF8.self)+plan.context+(plan.unavailableReason ?? "")
    }
    let wholePlan=s.eqPlan,wholeKey=try planKey(wholePlan)
    check("Whole-track EQ plan fixture has supported correction",!wholePlan.bands.isEmpty && wholePlan.unavailableReason==nil)
    s.tonalLoud=true
    check("Louder chart toggle preserves EQ plan and availability",try planKey(s.eqPlan)==wholeKey)
    s.manualBounds=[8,16];s.selectedSection=0
    let sectionPlanKey=try planKey(s.eqPlan)
    check("Selected section does not shrink or alter EQ preview basis",s.selectedToneSlices.count==4 && sectionPlanKey==wholeKey)
    s.manualBounds=[4,12,20];s.selectedSection=2;s.tonalLoud=false
    check("Edited passage boundaries preserve whole-track EQ plan",try planKey(s.eqPlan)==wholeKey)
    s.genre="Anders/onbekend"
    check("Genre without references invalidates cached EQ availability",s.eqPlan.bands.isEmpty && s.eqPlan.unavailableReason != nil)

    // Exercise loudness matching/headroom using owned metadata only; no playback.
    let previewDir=playbackDir.appendingPathComponent("owned-preview",isDirectory:true)
    try fm.createDirectory(at:previewDir,withIntermediateDirectories:false)
    var gainSource=a;gainSource.integrated = -14;gainSource.truePeakEstimate=2
    var gainReference=a;gainReference.integrated = -11;gainReference.truePeakEstimate=1
    s.result=gainSource;s.reference=gainReference;s.comparisonMode="Hele nummer"
    var attenuateOnly=true,headroomSafe=true,previewMatched=true,referenceMatched=true
    for matching in [-12.0,-3,0,3,12] {for ceilingGain in [-18.0,-6,0] {
        s.eqPreview=EQPreviewResult(directory:previewDir,url:previewDir.appendingPathComponent("not-played.caf"),gainDB:ceilingGain,matchingDB:matching,bands:[])
        let gains=s.pairedPlaybackGains
        attenuateOnly = attenuateOnly && gains.original<=0 && gains.preview<=0 && gains.reference<=0
        headroomSafe = headroomSafe && gains.original<=gainSource.previewGainDB && gains.preview<=ceilingGain && gains.reference<=gainReference.previewGainDB
        previewMatched = previewMatched && abs((-14+gains.original)-(-14-matching+gains.preview))<1e-10
        referenceMatched = referenceMatched && abs((-14+gains.original)-(-11+gains.reference))<1e-10
    }}
    check("Paired preview gains never require player gain above unity",attenuateOnly)
    check("Original preview and reference retain their headroom limits",headroomSafe)
    check("Original and preview remain loudness matched after extra attenuation",previewMatched)
    check("Reference shares EQ headroom attenuation and remains level matched",referenceMatched)
    s.eqPreview=nil;s.reference=nil
    let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
    return try encoder.encode(results)
}
