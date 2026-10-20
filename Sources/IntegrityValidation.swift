import Foundation
func validateIntegrity() throws -> [TestOutcome] {
    var results=[TestOutcome]()
    func check(_ name:String,_ ok:Bool,_ detail:String="") {results.append(TestOutcome(name:name,passed:ok,detail:detail))}
    func plateau(_ x:[Float],bits:Int=0,chunk:Int=127) throws -> (samples:Int64,low:Int64,runs:Int64,timeline:[Int64]) {
        guard let q=qc_create(48000,1,Int64(x.count)) else{throw QCFailure(message:"Fixture init")};defer{qc_destroy(q)}
        qc_set_pcm_bits(q,Int32(bits))
        try x.withUnsafeBufferPointer { p in
            var at=0
            while at<x.count {let n=min(chunk,x.count-at);guard qc_push(q,p.baseAddress!+at,Int32(n))==0 else{throw QCFailure(message:"Fixture push")};at+=n}
        }
        guard qc_finish(q)==0 else{throw QCFailure(message:"Fixture finish")}
        return (qc_flat_samples(q),qc_low_flat_samples(q),qc_flat_runs(q),Array(UnsafeBufferPointer(start:qc_timeline(q,0),count:Int(QC_WAVE))))
    }
    func clipped(_ ceiling:Double,_ bits:Int=0)->[Float] {
        (0..<48000).map {n in
            var v=max(-ceiling,min(ceiling,1.5*sin(2*Double.pi*220*Double(n)/48000)))
            if bits>0 {let scale=pow(2,Double(bits-1));v=(v*scale).rounded()/scale}
            return Float(v)
        }
    }
    for ceiling in [0.7,0.5,0.25,0.05] {
        for bits in [0,16,24] {
            let a=try plateau(clipped(ceiling,bits),bits:bits)
            check("Lower clipping ceiling \(ceiling), PCM bits \(bits)",a.low>1000 && a.runs>100 && a.timeline.reduce(0,+)==a.samples)
        }
    }
    var outlier=clipped(0.25);outlier[20000]=0.99
    let a=try plateau(outlier,chunk:1),b=try plateau(outlier,chunk:8192)
    check("Lower clipping survives unrelated high peak and chunk boundaries",a.low>1000 && a.samples==b.samples && a.runs==b.runs && a.timeline==b.timeline)
    let many=(0..<600).flatMap{_ in [Float](arrayLiteral:0,0.25,0.25,0.25,0)}
    let m=try plateau(many)
    check("Lower clipping full timeline beyond event cap",m.runs==600 && m.low==1800 && m.timeline.reduce(0,+)==1800)
    for bits in [16,24] {
        for freq in [10.0,50,1000] {
            let scale=pow(2,Double(bits-1))
            let clean=(0..<48000).map{n in Float((0.05*sin(2*Double.pi*freq*Double(n)/48000)*scale).rounded()/scale)}
            let c=try plateau(clean,bits:bits)
            check("Clean quantized sine \(freq) Hz / \(bits) bit no lower clipping",c.low==0)
        }
    }
    let dc=try plateau([Float](repeating:0.25,count:1000)+[Float](repeating:0,count:1000))
    check("Constant DC at file start not a resolved low plateau",dc.low==0)
    let end=try plateau([0,0.1]+[Float](repeating:0.25,count:1000))
    check("EOF plateau without exit is not invented",end.low==0)
    let nearZero=try plateau([0]+[Float](repeating:0.00001,count:100)+[0])
    check("Near silence not low plateau evidence",nearZero.low==0)
    check("Balance equal stereo green",channelBalanceVerdict([-15,-15]).level == .green)
    check("Balance moderate deliberate panning remains green",channelBalanceVerdict([-15,-19]).level == .green)
    check("Balance 6 dB listen, 30 dB strong risk",channelBalanceVerdict([-15,-21]).level == .orange && channelBalanceVerdict([-15,-45]).level == .red)
    check("Balance 60 dB channel difference detected",channelBalanceVerdict([-13.5,-73.5]).level == .red)
    check("Balance missing left/right detected",channelBalanceVerdict([nil,-15]).level == .red && channelBalanceVerdict([-15,nil]).level == .red)
    check("Balance mono silence quiet short neutral",channelBalanceVerdict([-15],channels:1).level == .unavailable && channelBalanceVerdict([nil,nil]).level == .unavailable && channelBalanceVerdict([-70,-130]).level == .unavailable && channelBalanceVerdict([-15,nil],seconds:0.1).level == .unavailable)
    let dir=FileManager.default.temporaryDirectory.appendingPathComponent("ya-integrity-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:dir)}
    for bits in [16,24] {
        let url=dir.appendingPathComponent("clip-\(bits).wav")
        try writeTestAudio(url,samples:clipped(0.25),rate:48000,channels:1,bits:bits,floating:false)
        let measured=try Analyzer.run(url,makePreview:false)
        check("Real PCM\(bits) lower clipping decode and advice",measured.clipping.lowLevelFlatSamples>1000 && measured.secondOpinion(purpose:"Mix voor mastering").contains{$0.id=="ceiling" && $0.category=="Luistercontrole"})
    }
    for rate in [176400,192000] {
        let url=dir.appendingPathComponent("peak-\(rate).wav")
        let x=(0..<rate).map{Float(1.1*sin(Double.pi*0.5*Double($0)+Double.pi/4))}
        try writeTestAudio(url,samples:x,rate:Double(rate),channels:1)
        let measured=try Analyzer.run(url,makePreview:false)
        let json=try JSONSerialization.jsonObject(with:measured.json()) as! [String:Any]
        let status=json["measurementStatus"] as! [String:String]
        let interpolated=rate==176400
        check("\(rate) interpolation value/status/JSON/advice aligned",(json["truePeakInterpolationFactor"] as? Int)==(interpolated ? 2:1) && status["truePeakEstimate"]==(interpolated ? "provisional_interpolated_estimate":"sample_peak_only_no_interpolation") && measured.secondOpinion(purpose:"Release/master").contains{$0.id=="truepeak"}==(interpolated && measured.truePeakEstimate!>1) && (interpolated ? measured.truePeakEstimate!>measured.samplePeak!+2:abs(measured.truePeakEstimate!-measured.samplePeak!)<1e-6))
    }
    let left=dir.appendingPathComponent("left-only.wav")
    let l=(0..<48000).flatMap{n in [Float(0.2*sin(2*Double.pi*440*Double(n)/48000)),Float(0)]}
    try writeTestAudio(left,samples:l,rate:48000,channels:2)
    let lr=try Analyzer.run(left,makePreview:false)
    check("Silent channel reaches JSON and action card",lr.stereoAssessment["channelBalance"]?.level == .red && lr.secondOpinion(purpose:"Release/master").contains{$0.id=="channel-balance"} && (try? lr.json()) != nil)
    return results
}
