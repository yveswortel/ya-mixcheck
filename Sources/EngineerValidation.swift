import Foundation
import AVFoundation
func validateEngineerMusic(_ url:URL,genre:String)throws->Data {
    let source=try Analyzer.run(url,makePreview:false)
    let input=try AudioInput(url),rate=input.format!.sampleRate,ch=Int(input.format!.channelCount)
    let first=min(Int64(rate*30),input.length/4),count=min(Int64(rate*30),input.length-first)
    try input.seek(first)
    let b=AVAudioPCMBuffer(pcmFormat:input.format!,frameCapacity:8192)!
    var original=[Float]();original.reserveCapacity(Int(count)*ch)
    while original.count<Int(count)*ch {
        let n=min(8192,Int(count)-original.count/ch);try input.read(into:b,frameCount:AVAudioFrameCount(n))
        guard b.frameLength>0 else{throw QCFailure(message:"Onvolledige testpassage")}
        original.append(contentsOf:UnsafeBufferPointer(start:b.floatChannelData![0],count:Int(b.frameLength)*ch))
    }
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent("engineer-test-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:directory)}
    var rows=[[String:Any]]()
    for variant in ["baseline","gain_minus12","compressed_4to1","hardclip_drive12","bass_plus6","air_hollow","local_sub_burst"] {
        var x=original,env=0.0,filters=(0..<ch).map{_ in PreviewBiquad(hz:85,gain:6,rate:rate)}
        if variant=="gain_minus12" {x=x.map{$0*0.25}}
        if variant=="hardclip_drive12" {x=x.map{min(0.7,max(-0.7,$0*4))}}
        if variant=="bass_plus6" {for n in 0..<x.count/ch{for c in 0..<ch{x[n*ch+c]=Float(filters[c].tick(Double(x[n*ch+c])))}}}
        if variant=="compressed_4to1" {
            for n in 0..<x.count/ch{
                let peak=(0..<ch).map{abs(Double(x[n*ch+$0]))}.max()!
                let coefficient=exp(-1/(rate*(peak>env ? 0.0001:0.08)))
                env=coefficient*env+(1-coefficient)*peak
                let gain=env>0.1 ? pow(env/0.1,-0.75):1
                for c in 0..<ch{x[n*ch+c]*=Float(gain)}
            }
        }
        if variant=="air_hollow" {
            for (hz,gain) in [(12000.0,18.0),(350.0,-12.0),(1000.0,-12.0)] {
                var eq=(0..<ch).map{_ in PreviewBiquad(hz:hz,gain:gain,rate:rate)}
                for n in 0..<x.count/ch{for c in 0..<ch{x[n*ch+c]=Float(eq[c].tick(Double(x[n*ch+c])))}}
            }
        }
        if variant=="local_sub_burst" {
            for n in 0..<x.count/ch {
                let t=Double(n)/rate
                if t>=15 && t<15.6 {
                    let ramp=min(1,min((t-15)/0.02,(15.6-t)/0.02))
                    for c in 0..<ch{x[n*ch+c]+=Float(0.8*ramp*sin(2*Double.pi*45*t))}
                }
            }
        }
        let file=directory.appendingPathComponent(variant+".wav");try writeTestAudio(file,samples:x,rate:rate,channels:ch)
        var a=try Analyzer.run(file,makePreview:false)
        let actualHash=a.sha256;a.sha256=source.sha256 // Exclude the source family from reference comparisons, including transformed versions.
        let sections=[ArrangementSection(id:0,start:0,end:a.duration,label:"Voller",change:"Identieke testpassage")]
        let e=JSONEncoder()
        rows.append(["variant":variant,"renderedHash":actualHash,"assessmentFamilyHash":source.sha256,"summary":try JSONSerialization.jsonObject(with:e.encode(summarizeDynamics(a.dynamics))),"localSubEvents":try JSONSerialization.jsonObject(with:e.encode(localSubEvents(a.subSlices))),"recommendations":try JSONSerialization.jsonObject(with:e.encode(mixRecommendations(a,genre:genre,purpose:"Release/master"))),"advice":try JSONSerialization.jsonObject(with:e.encode(listeningAdvice(a,sections:sections,genre:genre,purpose:"Release/master")))])
    }
    return try JSONSerialization.data(withJSONObject:["source":url.lastPathComponent,"startSeconds":Double(first)/rate,"sourceUnchanged":try sha256(url)==source.sha256,"variants":rows],options:[.prettyPrinted,.sortedKeys])
}
