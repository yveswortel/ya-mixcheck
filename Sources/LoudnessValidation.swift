import Foundation
import AVFoundation

func validateLoudnessReview()->[TestOutcome] {
    var out=[TestOutcome]()
    func check(_ name:String,_ ok:Bool){out.append(TestOutcome(name:"Loudness context: "+name,passed:ok,detail:"Conservative level-policy fixture; no perceptual quality claim"))}
    let regular=TrackDynamics(referenceCount:8,summary:DynamicsSummary(density:-10,punch:6,movement:4,seconds:120),metrics:[
        DynamicsMetric(id:"density",name:"",value:-10,lower:-13,median:-10,upper:-7,label:""),
        DynamicsMetric(id:"punch",name:"",value:6,lower:3,median:6,upper:9,label:""),
        DynamicsMetric(id:"movement",name:"",value:4,lower:2,median:4,upper:7,label:"")])
    func review(_ i:Double? = -27,_ st:Double? = -24,_ p:Double? = -20,lra:Double?=4,duration:Double=180,d:TrackDynamics?=nil,purpose:String="Release/master")->LoudnessReview {
        assessLoudness(integrated:i,shortTermMax:st,peak:p,lra:lra,duration:duration,dynamics:d ?? regular,purpose:purpose)
    }
    check("clear gain attenuation gives optional export hint",review().reason=="low_export_with_headroom")
    for i in [-5.0,-9,-12,-14,-16,-18,-20] {
        check("ordinary master \(i) LUFS stays neutral",review(i,i+2,-1).state == .neutral)
    }
    check("premaster never coloured for low LUFS",review(purpose:"Mix voor mastering").state == .neutral)
    check("loud chorus protects quiet intro",review(-24,-12,-1).state == .neutral)
    check("large intro/chorus contrast protected",review(-30,-22,-16).reason=="arrangement_contrast_allowed")
    check("wide LRA protected",review(lra:14).state == .neutral)
    var moving=regular;moving.metrics[2].value=14
    check("wide movement protected",review(d:moving).state == .neutral)
    check("short clips neutral",review(duration:20).state == .neutral)
    var short=regular;short.summary.seconds=8
    check("too little active audio neutral",review(d:short).state == .neutral)
    var unknown=regular;unknown.referenceCount=0
    check("unknown genre neutral",review(d:unknown).state == .neutral)
    check("missing loudness neutral",review(nil).state == .neutral)
    check("missing loud passage neutral",review(-27,nil).state == .neutral)
    check("nonfinite level neutral",review(-Double.infinity).state == .neutral)
    check("nonfinite peak neutral",review(-27,-24,.nan).state == .neutral)
    check("small headroom not export-gain hint",review(-27,-24,-5).state == .neutral)
    check("peak ceiling alone never transient diagnosis",review(-24,-21,-1).state == .neutral)
    var peaky=regular;peaky.metrics[0].value = -20;peaky.metrics[1].value=15
    check("large combined transient pattern asks to listen",review(-24,-21,-1,d:peaky).reason=="low_level_with_prominent_attacks")
    peaky.metrics[1].value=6
    check("open density alone protected",review(-24,-21,-1,d:peaky).state == .neutral)
    peaky.metrics[0].value = -10;peaky.metrics[1].value=15
    check("high punch alone protected",review(-24,-21,-1,d:peaky).state == .neutral)
    var invalid=regular;invalid.metrics[0].lower=nil
    check("missing distribution neutral",review(d:invalid).state == .neutral)
    return out
}

// Reproducible audio-level controls on a real master; only temporary files are written.
func validateLoudnessMusic(_ url:URL,genre:String)throws->Data {
    let source=try Analyzer.run(url,makePreview:false)
    let input=try AudioInput(url),rate=input.format!.sampleRate,ch=Int(input.format!.channelCount)
    let count=min(Int64(rate*65),input.length),first=min(Int64(rate*30),input.length-count)
    guard count>=Int64(rate*60) else{throw QCFailure(message:"Deze niveautest vereist minstens 60 seconden audio.")}
    try input.seek(first)
    let b=AVAudioPCMBuffer(pcmFormat:input.format!,frameCapacity:8192)!
    var original=[Float]();original.reserveCapacity(Int(count)*ch)
    while original.count<Int(count)*ch {
        let n=min(8192,Int(count)-original.count/ch);try input.read(into:b,frameCount:AVAudioFrameCount(n))
        guard b.frameLength>0 else{throw QCFailure(message:"Onvolledige testpassage")}
        original.append(contentsOf:UnsafeBufferPointer(start:b.floatChannelData![0],count:Int(b.frameLength)*ch))
    }
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent("loudness-test-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:directory)}
    var rows=[[String:Any]]()
    for variant in ["baseline","gain_minus6","gain_minus24","quiet_intro","sparse_attacks"] {
        var samples=original
        if variant=="gain_minus6" || variant=="gain_minus24" {
            let gain=Float(pow(10,(variant=="gain_minus6" ? -6.0:-24.0)/20));samples=samples.map{$0*gain}
        }
        if variant=="quiet_intro" {
            for n in 0..<samples.count/ch {
                let t=Double(n)/rate
                let gain=Float(pow(10,(-30*max(0,min(1,(45-t)/3)))/20))
                for c in 0..<ch{samples[n*ch+c]*=gain}
            }
        }
        if variant=="sparse_attacks" {
            samples=samples.map{$0*Float(pow(10,-24.0/20))}
            for n in 0..<samples.count/ch {
                let t=Double(n)/rate,phase=t.truncatingRemainder(dividingBy:0.8)
                if phase<0.002 {
                    let pulse=Float(0.85*sin(Double.pi*phase/0.002)*sin(2*Double.pi*2000*t))
                    for c in 0..<ch{samples[n*ch+c]+=pulse}
                }
            }
        }
        let file=directory.appendingPathComponent(variant+".wav");try writeTestAudio(file,samples:samples,rate:rate,channels:ch)
        var a=try Analyzer.run(file,makePreview:false)
        a.referenceIdentity=ReferenceIdentity(hash:source.assessmentHash,title:url.lastPathComponent,method:"test-source-family")
        let d=trackDynamics(a,genre:genre),review=a.loudnessReview(purpose:"Release/master",dynamics:d)
        let premaster=a.loudnessReview(purpose:"Mix voor mastering",dynamics:d)
        let expected=variant=="gain_minus24" ? "low_export_with_headroom":variant=="sparse_attacks" ? "low_level_with_prominent_attacks":"neutral"
        let passed=(expected=="neutral" ? review.state == .neutral:review.reason==expected) && premaster.state == .neutral
        let encoder=JSONEncoder()
        rows.append(["variant":variant,"expected":expected,"passed":passed,
                     "integrated":a.integrated as Any,"shortTermMax":a.shortTermMax as Any,"peak":a.truePeakEstimate as Any,"lra":a.lra as Any,
                     "dynamics":try JSONSerialization.jsonObject(with:encoder.encode(d)),
                     "assessment":try JSONSerialization.jsonObject(with:encoder.encode(review))])
    }
    let unchanged=try sha256(url)==source.sha256
    return try JSONSerialization.data(withJSONObject:["source":url.lastPathComponent,"sourceUnchanged":unchanged,
        "passed":unchanged && rows.allSatisfy{($0["passed"] as? Bool)==true},"variants":rows],options:[.prettyPrinted,.sortedKeys])
}
