import Foundation
import AVFoundation

func validateReviewLifecycle()throws->[TestOutcome] {
    var results=[TestOutcome]()
    func check(_ name:String,_ ok:Bool,_ detail:String="") {
        results.append(TestOutcome(name:"Review lifecycle: "+name,passed:ok,detail:detail))
    }
    let fm=FileManager.default,root=fm.temporaryDirectory.appendingPathComponent("ya-review-test-"+UUID().uuidString)
    try fm.createDirectory(at:root,withIntermediateDirectories:false)
    defer{try? fm.removeItem(at:root)}
    // Real reopened PCM while an additional writer reference is intentionally retained.
    // This would expose relying on ARC release instead of close() on macOS 15+.
    for rate in [44100.0,48000,96000] {for channels in [1,2] {
        let url=root.appendingPathComponent("\(Int(rate))-\(channels).caf")
        let format=AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:rate,channels:AVAudioChannelCount(channels),interleaved:true)!
        var writer:AVAudioFile?=try AVAudioFile(forWriting:url,settings:format.settings,commonFormat:.pcmFormatFloat32,interleaved:true)
        let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:1031)!
        buffer.frameLength=1031
        for i in 0..<(1031*channels){buffer.floatChannelData![0][i]=Float(i%37)/100}
        for _ in 0..<3{try writer!.write(from:buffer)}
        if #available(macOS 15.0, *) {
            let retained=writer!
            closeAudioWriter(&writer)
            check("writer explicitly closed \(rate)/\(channels)",!retained.isOpen && writer==nil)
            withExtendedLifetime(retained) {
                do {let reopened=try AVAudioFile(forReading:url);check("header finalized with retained writer \(rate)/\(channels)",reopened.length==3093)}
                catch{check("header finalized with retained writer \(rate)/\(channels)",false,error.localizedDescription)}
            }
        } else {closeAudioWriter(&writer)}
        let reader=try AVAudioFile(forReading:url,commonFormat:.pcmFormatFloat32,interleaved:true)
        let read=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:3093)!
        try reader.read(into:read)
        let exact=read.frameLength==3093 && (0..<(3093*channels)).allSatisfy{read.floatChannelData![0][$0]==buffer.floatChannelData![0][$0%(1031*channels)]}
        check("all finalized samples readable \(rate)/\(channels)",exact)
        closeAudioWriter(&writer) // idempotent
    }}
    // Compare optimized feature selection with the previous full scan at fractional
    // boundaries, including unsorted input and a slice overlapping a section edge.
    let features=(0..<1000).map{i in DynamicsSlice(start:Double(i)/10,duration:i==99 ? 0.1015:0.1,rms:-20,crest:8,onset:4)}
    for input in [features,Array(features.reversed()),[]] {
        let index=DynamicsSliceIndex(input)
        for range in [(0.0,8.0),(0.05,10.0),(10,18),(-1,0),(100,200),(25,20),(0,9.9995)] {
            let expected=input.filter{$0.start>=range.0 && $0.start+$0.duration<=range.1+0.001}
            check("indexed time selection matches scan \(input.count)/\(range)",index.within(start:range.0,end:range.1).map{$0.start}==expected.map{$0.start})
        }
    }
    // Feature selection benchmark only, not whole-app speed: 60 minutes of 100ms
    // features queried by disjoint 8s windows. Verify all memberships as well.
    let long=(0..<36000).map{i in DynamicsSlice(start:Double(i)/10,duration:0.1,rms:-20,crest:8,onset:4)}
    let indexed=DynamicsSliceIndex(long)
    let startScan=ProcessInfo.processInfo.systemUptime
    let scanCounts=stride(from:0.0,to:3600,by:8).map{start in long.filter{$0.start>=start && $0.start+$0.duration<=start+8.001}.count}
    let scanSeconds=ProcessInfo.processInfo.systemUptime-startScan
    let startIndex=ProcessInfo.processInfo.systemUptime
    let indexedCounts=stride(from:0.0,to:3600,by:8).map{indexed.within(start:$0,end:$0+8).count}
    let indexSeconds=ProcessInfo.processInfo.systemUptime-startIndex
    check("60 minute feature selection preserves every window",scanCounts==indexedCounts && scanCounts.reduce(0,+)==36000,"Selection only: full scan \(scanSeconds) s; index \(indexSeconds) s. Not overall app latency.")
    let old=Date().addingTimeInterval(-600)
    for prefix in ["ya-mixcheck-input-","ya-mixcheck-decode-","YA-MixCheck-EQ-"] {
        let live=root.appendingPathComponent(prefix+"live"),dead=root.appendingPathComponent(prefix+"dead"),recent=root.appendingPathComponent(prefix+"recent"),unknown=root.appendingPathComponent(prefix+"unknown")
        for dir in [live,dead,recent,unknown]{try fm.createDirectory(at:dir,withIntermediateDirectories:false)}
        try SnapshotStorage.register(live)
        for dir in [dead,recent]{fm.createFile(atPath:dir.appendingPathComponent("owner.lock").path,contents:Data())}
        for dir in [live,dead,unknown]{try fm.setAttributes([.modificationDate:old],ofItemAtPath:dir.path)}
        SnapshotStorage.recover(in:root)
        check("abandoned artifact recovered \(prefix)",!fm.fileExists(atPath:dead.path))
        check("live lease protected \(prefix)",fm.fileExists(atPath:live.path))
        check("recent registration window protected \(prefix)",fm.fileExists(atPath:recent.path))
        check("unregistered legacy artifact not guessed \(prefix)",fm.fileExists(atPath:unknown.path))
        SnapshotStorage.remove(live);SnapshotStorage.remove(live)
        check("registered cleanup idempotent \(prefix)",!fm.fileExists(atPath:live.path))
    }
    let outside=root.appendingPathComponent("unrelated")
    try fm.createDirectory(at:outside,withIntermediateDirectories:false)
    try Data("keep".utf8).write(to:outside.appendingPathComponent("owner.lock"))
    let link=root.appendingPathComponent("YA-MixCheck-EQ-link")
    try fm.createSymbolicLink(at:link,withDestinationURL:outside)
    try fm.setAttributes([.modificationDate:old],ofItemAtPath:outside.path)
    SnapshotStorage.recover(in:root)
    check("recovery leaves unrelated and symlink targets intact",fm.fileExists(atPath:outside.appendingPathComponent("owner.lock").path))
    // A failed unlink must retain ownership so an explicit retry can complete.
    let parent=root.appendingPathComponent("blocked-parent"),blocked=parent.appendingPathComponent("cache")
    try fm.createDirectory(at:blocked,withIntermediateDirectories:true)
    try SnapshotStorage.register(blocked)
    try fm.setAttributes([.posixPermissions:0o500],ofItemAtPath:parent.path)
    SnapshotStorage.remove(blocked)
    let retryNeeded=fm.fileExists(atPath:blocked.path)
    try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:parent.path)
    SnapshotStorage.remove(blocked)
    check("cleanup retries retained lease after permission failure",retryNeeded && !fm.fileExists(atPath:blocked.path))
    // Result copies share ownership; dropping a superseded result cannot delete
    // files while another consumer still owns that same result.
    let source=root.appendingPathComponent("source.wav")
    try writeTestAudio(source,samples:(0..<48000).map{Float(0.1*sin(Double($0)*0.17))},rate:48000,channels:1)
    let a=try Analyzer.run(source,makePreview:false),hash=try sha256(source)
    var preview:EQPreviewResult?=try renderEQPreview(PreviewSource(a),bands:[PreviewBand(hz:350,gain:1)],cancellation:Cancellation(),progress:{_ in})
    let previewURL=preview!.url
    var retained=preview;preview=nil
    withExtendedLifetime(retained){check("retained EQ owner keeps artifact",fm.fileExists(atPath:previewURL.path))}
    retained=nil
    check("last EQ owner releases artifact",!fm.fileExists(atPath:previewURL.path))
    check("source untouched by lifecycle",try sha256(source)==hash)
    return results
}
