import Foundation
import AVFoundation

struct TestOutcome: Codable { var name:String; var passed:Bool; var detail:String }
func runValidation() throws -> [TestOutcome] {
    var results=[TestOutcome]()
    func check(_ name:String,_ ok:Bool,_ detail:String="") { results.append(TestOutcome(name:name,passed:ok,detail:detail)) }
    func tone(rate:Int,seconds:Double,channels:Int=2,amplitude:Double=0.1,frequency:Double=1000,anti:Bool=false) -> [Float] {
        (0..<Int(Double(rate)*seconds)*channels).map { i in Float(amplitude*sin(2*Double.pi*frequency*Double(i/channels)/Double(rate))*(anti && i%channels==1 ? -1:1)) }
    }
    func measure(_ samples:[Float],rate:Int=48000,channels:Int=2,chunk:Int=4096) throws -> [Double] {
        guard let q=qc_create(Int32(rate),Int32(channels),Int64(samples.count/channels)) else {throw QCFailure(message:"Test init failed")};defer{qc_destroy(q)}
        try samples.withUnsafeBufferPointer { p in var pos=0;while pos<samples.count/channels {let n=min(chunk,samples.count/channels-pos);guard qc_push(q,p.baseAddress!+pos*channels,Int32(n))==0 else{throw QCFailure(message:"Test push failed")};pos+=n} }
        guard qc_finish(q)==0 else{throw QCFailure(message:"Test finalization failed")}
        return (0..<Int(QC_METRICS)).map { qc_value(q,Int32($0)) }
    }
    let i=Int(QC_I),pk=Int(QC_PEAK),corr=Int(QC_CORR),mono=Int(QC_MONO)
    for rate in [44100,48000,88200,96000,176400,192000] {
        let s=tone(rate:rate,seconds:3.2), m=try measure(s,rate:rate)
        check("\(rate): stereo 1 kHz integrated",abs(m[i] + 20)<0.1,"\(m[i]) LUFS; analytic sine baseline, not official fixture")
        check("\(rate): raw RMS",abs(m[Int(QC_RMS_L)]+23.0103)<0.001)
        check("\(rate): identical stereo",abs(m[corr]-1)<0.0001 && abs(m[mono])<0.0001)
        check("\(rate): finite true-peak estimate",m[Int(QC_TP)].isFinite && m[Int(QC_TP)]>=m[pk]-0.001)
    }
    let s=tone(rate:48000,seconds:3.2)
    let a=try measure(s,chunk:1),b=try measure(s,chunk:127),c=try measure(s,chunk:8192)
    check("Chunk invariance 1/127/8192",zip(a,b).allSatisfy{($0.isNaN && $1.isNaN)||abs($0-$1)<0.000001} && zip(b,c).allSatisfy{($0.isNaN && $1.isNaN)||abs($0-$1)<0.000001})
    let anti=try measure(tone(rate:48000,seconds:3.2,anti:true))
    check("Antiphase: correlation and complete mono loss",abs(anti[corr]+1)<0.000001 && anti[mono] == -.infinity)
    var leftOnly=s;for j in stride(from:1,to:leftOnly.count,by:2){leftOnly[j]=0}
    let left=try measure(leftOnly)
    check("One-sided: mono ratio",abs(left[mono]+3.0103)<0.0001 && left[corr].isNaN)
    check("One-sided: energy loudness",abs(left[i]-(a[i]-3.0103))<0.001)
    let silence=try measure([Float](repeating:0,count:48000*2*4))
    check("Silence is unavailable, not 0 LUFS",silence[i].isNaN && silence[pk].isNaN && silence[corr].isNaN && silence[Int(QC_LRA)].isNaN)
    let tiny=try measure(tone(rate:48000,seconds:0.1))
    check("Short file has no I/M/S/LRA",[QC_I,QC_M,QC_S,QC_LRA].allSatisfy{tiny[Int($0)].isNaN})
    let quiet=try measure(tone(rate:48000,seconds:1,amplitude:0.00001))
    check("Absolute loudness gate",quiet[i].isNaN)
    let q=qc_create(48000,2,100)!
    var over=[Float](repeating:0,count:200);over[20]=1.2;over[22]=1.3;over[101] = -1.1
    let push=over.withUnsafeBufferPointer{qc_push(q,$0.baseAddress,100)};_ = qc_finish(q)
    check("Overrange exact sample intervals",push==0 && qc_over_samples(q)==3 && qc_event_count(q)==2 && qc_events(q)![0].start==10 && qc_events(q)![0].end==11 && qc_events(q)![1].channel==1)
    qc_destroy(q)
    let invalid=qc_create(48000,1,1)!;var nan=Float.nan
    check("NaN rejected",qc_push(invalid,&nan,1)==2);qc_destroy(invalid)
    let bad=qc_create(48000,1,10)!;var zero:Float=0;_ = qc_push(bad,&zero,1)
    check("Truncated input rejected",qc_finish(bad) != 0);qc_destroy(bad)
    // 12 kHz phase-shifted sine has an intersample peak above its sample peak.
    var shifted=[Float]()
    for n in 0..<96000 { let phase = Double.pi * 0.5 * Double(n) + Double.pi / 4.0; let v=Float(0.8*sin(phase)); shifted.append(v); shifted.append(v) }
    let inter=try measure(shifted)
    check("Intersample estimate detects hidden peak",inter[Int(QC_TP)]>inter[pk]+2 && abs(inter[Int(QC_TP)]-20*log10(0.8))<0.4,"TP \(inter[Int(QC_TP)]) SP \(inter[pk])")
    let dir=FileManager.default.temporaryDirectory.appendingPathComponent("ya-mixcheck-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:dir)}
    let url=dir.appendingPathComponent("stereo.wav")
    try writeTestAudio(url,samples:s,rate:48000,channels:2)
    let report=try Analyzer.run(url)
    check("Decoder + DSP integration",report.frames==153600 && abs((report.integrated ?? 0)+20)<0.1)
    check("JSON serialization",(try? report.json()) != nil)
    check("Source identity stable",try sha256(url)==report.sha256)
    let token=Cancellation();token.cancel()
    do{_ = try Analyzer.run(url,cancellation:token);check("Cancellation",false)}catch{check("Cancellation",true)}
    for (suffix,bits) in [("wav",16),("wav",24),("aiff",24)] {
        let audio=dir.appendingPathComponent("pcm-\(bits).\(suffix)")
        try writeTestAudio(audio,samples:s,rate:48000,channels:2,bits:bits,floating:false)
        let decoded=try Analyzer.run(audio)
        check("Decoder \(suffix) PCM\(bits)",decoded.frames==153600 && decoded.bitDepth==bits && abs((decoded.integrated ?? 0)+20)<0.1)
    }
    let monoURL=dir.appendingPathComponent("mono.wav")
    let monoSamples=tone(rate:48000,seconds:3.2,channels:1)
    try writeTestAudio(monoURL,samples:monoSamples,rate:48000,channels:1)
    let monoReport=try Analyzer.run(monoURL)
    check("Mono has no stereo diagnosis",monoReport.channels==1 && monoReport.correlation==nil && monoReport.monoLoss==nil && abs((monoReport.integrated ?? 0)+23.0103)<0.1)
    let midToken=Cancellation()
    do {_ = try Analyzer.run(url,cancellation:midToken,progress:{p in if p>0.1 { midToken.cancel() }});check("Mid-analysis cancellation",false)}catch{check("Mid-analysis cancellation",true)}
    let spectrumQ=qc_create(48000,2,Int64(s.count/2))!
    _ = s.withUnsafeBufferPointer {qc_push(spectrumQ,$0.baseAddress,Int32(s.count/2))};_ = qc_finish(spectrumQ)
    var spectralEnergy=0.0
    for j in 0..<Int(QC_BANDS) { let lo=20*pow(1000.0,Double(j)/Double(QC_BANDS));let hi=20*pow(1000.0,Double(j+1)/Double(QC_BANDS));spectralEnergy += qc_spectrum(spectrumQ)![j]*(hi-lo) }
    check("Spectrum energy conservation, 1 kHz",abs(spectralEnergy-0.005)<0.000001,"\(spectralEnergy)")
    qc_destroy(spectrumQ)
    // Plateau/rail tests are independent of loudness. Exercise event bounds and chunk edges.
    func clipping(_ x:[Float],bits:Int=16,chunk:Int=1) -> (Int64,Int64,Int64,Int64,Int,Int64) {
        let q=qc_create(48000,1,Int64(x.count))!;defer{qc_destroy(q)}
        qc_set_pcm_bits(q,Int32(bits))
        x.withUnsafeBufferPointer { p in var at=0;while at<x.count{let n=min(chunk,x.count-at);_ = qc_push(q,p.baseAddress!+at,Int32(n));at+=n} }
        _ = qc_finish(q)
        return(qc_rail_samples(q),qc_flat_samples(q),qc_flat_longest(q),qc_flat_runs(q),Int(qc_flat_event_count(q)),qc_flat_event_count(q)>0 ? qc_flat_events(q)![0].end : -1)
    }
    let rail=Float(32767)/32768
    let ceiling=[Float](repeating:rail,count:10)+[0]+[Float](repeating:-1,count:7)
    let clipA=clipping(ceiling),clipB=clipping(ceiling,chunk:127)
    check("PCM16 asymmetric rails and plateau evidence",clipA.0==17 && clipA.1==17 && clipA.2==10 && clipA.3==2 && clipA.5==9)
    check("Plateau chunk invariance",clipA.0==clipB.0 && clipA.1==clipB.1 && clipA.2==clipB.2 && clipA.3==clipB.3 && clipA.5==clipB.5)
    let subCeiling=clipping([0.9,0.9,0.9,0,0.9,0.9],bits:0)
    check("Float below-fullscale plateau without invented PCM rails",subCeiling.0==0 && subCeiling.1==3 && subCeiling.3==1)
    let clean=clipping(tone(rate:48000,seconds:0.1,channels:1,amplitude:1,frequency:50))
    check("Full-scale bass sine not called flat clipping",clean.1==0 && clean.3==0)
    let many=clipping((0..<600).flatMap{_ in [Float](arrayLiteral:0.9,0.9,0.9,0)},bits:0,chunk:127)
    check("Plateau event cap retains complete counts",many.1==1800 && many.3==600 && many.4==512)
    func timeline(_ x:[Float],chunk:Int) -> [[Int64]] {
        let q=qc_create(48000,1,Int64(x.count))!;defer{qc_destroy(q)};qc_set_pcm_bits(q,16)
        x.withUnsafeBufferPointer { p in var at=0;while at<x.count{let n=min(chunk,x.count-at);_ = qc_push(q,p.baseAddress!+at,Int32(n));at+=n} }
        _ = qc_finish(q)
        return (0..<3).map{Array(UnsafeBufferPointer(start:qc_timeline(q,Int32($0)),count:Int(QC_WAVE)))}
    }
    var distributed=[Float](repeating:0,count:48000)
    for k in 0..<600 {for j in 0..<3 {distributed[k*4+j]=rail}}
    for k in 30000..<36000 {distributed[k] = -1}
    distributed[45000]=1.25
    let timeA=timeline(distributed,chunk:1),timeB=timeline(distributed,chunk:8192)
    check("Full timeline survives 512-event cap including late clipping",timeA[0][1400]>0 && timeA[1][1400]>0 && timeA[2][1920]==1)
    check("Timeline sample totals conserved including plateau starts",timeA[0].reduce(0,+)==7800 && timeA[1].reduce(0,+)==7801 && timeA[2].reduce(0,+)==1)
    check("Timeline invariant across decode chunks",timeA==timeB)
    check("Timeline leaves clean midsection unmarked",timeA.allSatisfy{$0[1000]==0})
    let clippedURL=dir.appendingPathComponent("clipped16.wav")
    try writeTestAudio(clippedURL,samples:ceiling,rate:48000,channels:1,bits:16,floating:false)
    let clippedReport=try Analyzer.run(clippedURL)
    check("PCM clipping integration despite zero overrange",clippedReport.overrangeSamples==0 && clippedReport.clipping.railSamples==17 && clippedReport.clipping.longestFlatFrames==10)
    check("Low energy and high loudness have no error verdict",report.secondOpinion(purpose:"Release/master").filter{["low","loudness"].contains($0.id)}.allSatisfy{$0.category=="Context, geen fout"})
    check("Clipping advice never claims audible damage",clippedReport.secondOpinion(purpose:"Release/master").first{$0.id=="ceiling"}?.category=="Luistercontrole")
    let brokenMP3=dir.appendingPathComponent("invalid.mp3");try Data("not an MP3".utf8).write(to:brokenMP3)
    do{_ = try Analyzer.run(brokenMP3);check("Malformed MP3 rejected",false)}catch{check("Malformed MP3 rejected",true)}
    let segmentedURL=dir.appendingPathComponent("two-levels.wav")
    try writeTestAudio(segmentedURL,samples:tone(rate:48000,seconds:2,amplitude:0.05)+tone(rate:48000,seconds:2,amplitude:0.2),rate:48000,channels:2)
    let segment=try Analyzer.run(segmentedURL,startSeconds:2,durationSeconds:1,makePreview:false)
    check("Passage measures selected level, not full track",abs((segment.integrated ?? 0)+13.9794)<0.1 && segment.frames==48000 && segment.windowStartFrame==96000 && segment.sourceFrames==192000)
    check("Passage avoids temporary preview copy",segment.decodedAudio==nil)
    let segmentChunk=try Analyzer.run(segmentedURL,chunkSize:127,startSeconds:2,durationSeconds:1,makePreview:false)
    check("Passage chunk invariant",segment.integrated==segmentChunk.integrated && segment.samplePeak==segmentChunk.samplePeak)
    do{_ = try Analyzer.run(segmentedURL,startSeconds:10,durationSeconds:1);check("Out-of-file passage rejected",false)}catch{check("Out-of-file passage rejected",true)}
    do{_ = try Analyzer.run(segmentedURL,startSeconds:0,durationSeconds:.nan);check("NaN passage rejected",false)}catch{check("NaN passage rejected",true)}
    var sparse=report
    sparse.clipping.flatRuns=13;sparse.clipping.flatSamples=42;sparse.clipping.longestFlatFrames=4;sparse.clipping.railSamples=0
    check("Sparse quantization plateaus do not create action card",!sparse.secondOpinion(purpose:"Release/master").contains{$0.id=="ceiling"})
    var dense=report
    dense.clipping.railSamples=dense.clipping.totalSamples/5;dense.clipping.longestFlatFrames=480;dense.clipping.flatRuns=200
    check("Heavy hard clipping still creates strong evidence card",dense.secondOpinion(purpose:"Release/master").contains{$0.title=="Sterke aanwijzingen voor hard begrenzen"})
    var lossy=report;lossy.codec="MP3 / minimp3 float";lossy.overrangeSamples=20;lossy.truePeakEstimate=2;lossy.samplePeak=1
    let cards=lossy.secondOpinion(purpose:"Release/master")
    check("Decoded overs not duplicated by truepeak card",cards.contains{$0.id=="overrange"} && !cards.contains{$0.id=="truepeak"})
    var loud=report;loud.integrated = -5;loud.truePeakEstimate=4
    var quietRef=report;quietRef.integrated = -12;quietRef.truePeakEstimate = -0.5
    let gains=comparisonGains(loud,quietRef,levelA:-8,levelB:-14)
    check("Passage gains preserve loudness difference",abs((-8+gains.0)-(-14+gains.1))<1e-12)
    check("Comparison headroom and attenuation only",gains.0<=0 && gains.1<=0 && 4+gains.0<=(-1) && -0.5+gains.1<=(-1))
    let sameBands=relativeLowBands(report,report)
    check("Identical low-band comparison has zero delta",sameBands.compactMap{$0}.allSatisfy{abs($0)<1e-12})
    results += try validateReports(report)
    results += validateDesktopFileSelection()
    results += try validateIntegrity()
    results += validateStereoPolicy()
    results += try validateTonal()
    results += try validateNewChecks()
    results += validateDynamics()
    results += validateRecommendations()
    results += validateLoudnessReview()
    results += validateAdviceContext()
    results += validateSubBalance()
    results += try validateEQPreviewPolicy()
    results += try validateEQPreviewAlignment()
    results += validatePreviewGain()
    results += try validateReviewBugs()
    results += try validateReviewLifecycle()
    results += validateGapBoundaries()
    results += validateReferenceIdentity()
    return results
}
func writeTestAudio(_ url:URL,samples:[Float],rate:Double,channels:Int,bits:Int=32,floating:Bool=true,formatID:AudioFormatID=kAudioFormatLinearPCM) throws {
    guard !FileManager.default.fileExists(atPath:url.path) else { throw QCFailure(message:"Testbestand bestaat al; niets overschreven.") }
    let settings:[String:Any]=[AVFormatIDKey:formatID,AVSampleRateKey:rate,AVNumberOfChannelsKey:channels,AVLinearPCMBitDepthKey:bits,AVLinearPCMIsFloatKey:floating,AVLinearPCMIsNonInterleaved:false]
    let f=try AVAudioFile(forWriting:url,settings:settings,commonFormat:.pcmFormatFloat32,interleaved:true)
    let b=AVAudioPCMBuffer(pcmFormat:f.processingFormat,frameCapacity:AVAudioFrameCount(samples.count/channels))!
    b.frameLength=b.frameCapacity
    samples.withUnsafeBufferPointer{b.floatChannelData![0].update(from:$0.baseAddress!,count:samples.count)}
    try f.write(from:b)
}
