import Foundation
func validateNewChecks() throws->[TestOutcome] {
    var results=[TestOutcome]()
    func check(_ n:String,_ ok:Bool){results.append(TestOutcome(name:n,passed:ok,detail:""))}
    func detect(_ x:[Float],rate:Int,chunk:Int=8192)->[AudioAnomaly]{
        let d=DiscontinuityDetector(rate:Double(rate),channels:1)
        x.withUnsafeBufferPointer{p in var i=0;while i<x.count{let n=min(chunk,x.count-i);d.push(p.baseAddress!+i,frames:n);i+=n}}
        return d.events
    }
    for rate in [44100,48000,96000,192000] {
        let tone=(0..<rate*2).map{Float(0.2*sin(2*Double.pi*440*Double($0)/Double(rate)))}
        check("\(rate): clean sinus no click/dropout",detect(tone,rate:rate).isEmpty)
        var impulse=tone;impulse[rate]+=0.7
        let a=detect(impulse,rate:rate),b=detect(impulse,rate:rate,chunk:127)
        check("\(rate): isolated impulse localized",a.contains{$0.kind=="click" && $0.startFrame==rate})
        check("\(rate): anomaly chunk invariance",a.map{"\($0.kind):\($0.startFrame):\($0.endFrame):\($0.channel)"}==b.map{"\($0.kind):\($0.startFrame):\($0.endFrame):\($0.channel)"})
        var gap=tone;for i in rate..<rate+rate/10{gap[i]=0}
        check("\(rate): internal 100ms dropout",detect(gap,rate:rate).contains{$0.kind=="silence"})
        var tail=tone;for i in rate..<rate*2{tail[i]=0}
        check("\(rate): trailing silence not a dropout",!detect(tail,rate:rate).contains{$0.kind=="silence"})
        var fade=tone;for i in rate/2..<rate{fade[i]*=Float(rate-i)/Float(rate/2)};for i in rate..<rate*2{fade[i]=0}
        check("\(rate): fade-out no dropout",!detect(fade,rate:rate).contains{$0.kind=="silence"})
        // A percussion-like exponential burst should not match an isolated impulse.
        let drum=(0..<rate).map{n in Float(0.8*exp(-Double(n)/Double(rate)*18)*sin(2*Double.pi*80*Double(n)/Double(rate)))}
        check("\(rate): decaying kick no click",!detect(drum,rate:rate).contains{$0.kind=="click"})
    }
    let dir=FileManager.default.temporaryDirectory.appendingPathComponent("eq-test-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:dir)}
    let url=dir.appendingPathComponent("source.wav")
    let x=(0..<48000*4).map{n in Float(0.1*sin(2*Double.pi*350*Double(n)/48000)+0.02*sin(2*Double.pi*5000*Double(n)/48000))}
    try writeTestAudio(url,samples:x,rate:48000,channels:1)
    let source=try Analyzer.run(url,makePreview:false),hash=try sha256(url)
    let preview=try renderEQPreview(PreviewSource(source),bands:[PreviewBand(hz:350,gain:3)],cancellation:Cancellation(),progress:{_ in});defer{preview.remove()}
    let rendered=try Analyzer.run(preview.url,makePreview:false)
    check("EQ preview preserves source SHA",try sha256(url)==hash)
    check("EQ preview preserves frame count",source.frames==rendered.frames)
    check("EQ preview changes audio spectrum",abs((rendered.integrated ?? 0)-(source.integrated ?? 0))>1)
    check("EQ preview matches loudness when headroom allows",abs((rendered.integrated ?? 0)+preview.gainDB-(source.integrated ?? 0)-source.previewGainDB)<0.05)
    check("EQ preview headroom",(rendered.truePeakEstimate ?? 0)+preview.gainDB <= -0.999)
    var boundary=source;boundary.overrangeSamples=0
    boundary.truePeakEstimate=1;check("No TP warning at +1 dBTP",!boundary.secondOpinion(purpose:"Release/master").contains{$0.id=="truepeak"})
    boundary.truePeakEstimate=1.01;check("TP warning above +1 dBTP",boundary.secondOpinion(purpose:"Release/master").contains{$0.id=="truepeak"})
    return results
}
