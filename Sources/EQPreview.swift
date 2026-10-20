import Foundation
import AVFoundation

struct PreviewBand:Codable {var hz:Double;var gain:Double}
func previewBands(_ assessment:ToneAssessment)->[PreviewBand] {
    guard assessment.referenceCount>=5,assessment.summary.seconds>=8 else{return []}
    let centers=[35.0,85,175,350,1000,5000]
    return assessment.bands.prefix(6).compactMap{b in
        guard let v=b.value,let lo=b.lower,let hi=b.upper else{return nil}
        let correction=v<lo ? lo-v:(v>hi ? hi-v:0)
        guard abs(correction)>0.25 else{return nil}
        return PreviewBand(hz:centers[b.id],gain:max(-3,min(3,correction*0.7)))
    }
}
struct PreviewBiquad {
    var b0:Double,b1:Double,b2:Double,a1:Double,a2:Double
    var z1=0.0,z2=0.0
    init(hz:Double,gain:Double,rate:Double) {
        let a=pow(10,gain/40),w=2*Double.pi*hz/rate,alpha=sin(w)/(2*0.8),d=1+alpha/a
        b0=(1+alpha*a)/d;b1=(-2*cos(w))/d;b2=(1-alpha*a)/d;a1=b1;a2=(1-alpha/a)/d
    }
    mutating func tick(_ x:Double)->Double {let y=b0*x+z1;z1=b1*x-a1*y+z2;z2=b2*x-a2*y;return y}
}
struct EQPreviewResult {
    let directory:URL,url:URL,gainDB:Double,matchingDB:Double,bands:[PreviewBand]
    func remove(){try? FileManager.default.removeItem(at:directory)}
}
struct PreviewSource:Sendable {
    let url:URL,playbackURL:URL,sampleRate:Double,channels:Int,integrated:Double?,previewGainDB:Double,modifiedAt:Date,byteCount:Int64
    init(_ a:Analysis){url=a.url;playbackURL=a.playbackURL;sampleRate=a.sampleRate;channels=a.channels;integrated=a.integrated;previewGainDB=a.previewGainDB;modifiedAt=a.modifiedAt;byteCount=a.byteCount}
    func sourceIsUnchanged()->Bool {
        guard let a=try? FileManager.default.attributesOfItem(atPath:url.path) else{return false}
        return (a[.modificationDate] as? Date)==modifiedAt && (a[.size] as? NSNumber)?.int64Value==byteCount
    }
}
func renderEQPreview(_ source:PreviewSource,bands:[PreviewBand],cancellation:Cancellation,progress:(Double)->Void)throws->EQPreviewResult {
    guard source.sourceIsUnchanged(),!bands.isEmpty else{throw QCFailure(message:"Geen geldige previewcorrectie beschikbaar.")}
    let dir=FileManager.default.temporaryDirectory.appendingPathComponent("YA-MixCheck-EQ-"+UUID().uuidString,isDirectory:true)
    try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
    var success=false;defer{if !success{try? FileManager.default.removeItem(at:dir)}}
    let output=dir.appendingPathComponent("preview.caf")
    let input=try AudioInput(source.playbackURL),format=input.format!
    guard let meter=qcp_create(Int32(source.sampleRate),Int32(source.channels)) else{throw QCFailure(message:"Previewmeter kon niet starten.")}
    defer{qcp_destroy(meter)}
    var filters=(0..<source.channels).map{_ in bands.map{PreviewBiquad(hz:$0.hz,gain:$0.gain,rate:source.sampleRate)}}
    // Bounded chunk memory and float output; no clipping or change to the source file.
    do {
        let writer=try AVAudioFile(forWriting:output,settings:[AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:source.sampleRate,AVNumberOfChannelsKey:source.channels,AVLinearPCMBitDepthKey:32,AVLinearPCMIsFloatKey:true,AVLinearPCMIsNonInterleaved:false],commonFormat:.pcmFormatFloat32,interleaved:true)
        let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:8192)!
        var frames:Int64=0
        while frames<input.length {
            try cancellation.check();try input.read(into:buffer,frameCount:AVAudioFrameCount(min(8192,input.length-frames)))
            guard buffer.frameLength>0,let p=buffer.floatChannelData?[0] else{throw QCFailure(message:"Preview kon niet volledig worden gelezen.")}
            for n in 0..<Int(buffer.frameLength){for c in 0..<source.channels {
                var x=Double(p[n*source.channels+c]);for i in filters[c].indices{x=filters[c][i].tick(x)}
                guard x.isFinite else{throw QCFailure(message:"Ongeldige EQ-preview; afspelen geblokkeerd.")};p[n*source.channels+c]=Float(x)
            }}
            guard qcp_push(meter,p,Int32(buffer.frameLength))==0 else{throw QCFailure(message:"Previewmeting mislukt.")}
            try writer.write(from:buffer);frames+=Int64(buffer.frameLength);progress(Double(frames)/Double(input.length))
        }
        try input.finish(atEnd:true)
    }
    try cancellation.check()
    var integrated=Double.nan,peakDB=Double.nan
    guard qcp_finish(meter,&integrated,&peakDB)==0,!peakDB.isNaN else{throw QCFailure(message:"Previewmeting onvolledig.")}
    let previewGain = -max(0,peakDB+1)
    guard source.sourceIsUnchanged() else{throw QCFailure(message:"Bron gewijzigd tijdens EQ-preview.")}
    let matching=(source.integrated ?? 0)-(integrated.isFinite ? integrated:0)
    // Additional attenuation is always allowed; never boost above reconstructed headroom.
    let gain=min(matching+source.previewGainDB,previewGain)
    success=true
    return EQPreviewResult(directory:dir,url:output,gainDB:gain,matchingDB:matching,bands:bands)
}

// Read-only source validation; preview is deleted after reporting.
func validatePreviewFile(_ url:URL,genre:String)throws->Data {
    let original=try Analyzer.run(url);defer{original.decodedAudio?.remove()}
    let review=assessTone(original.toneSlices,genre:genre,hash:original.sha256)
    let bands=previewBands(review)
    guard !bands.isEmpty else{return Data("{\"status\":\"no_correction\"}".utf8)}
    let preview=try renderEQPreview(PreviewSource(original),bands:bands,cancellation:Cancellation(),progress:{_ in});defer{preview.remove()}
    let measured=try Analyzer.run(preview.url,makePreview:false)
    let assessment=assessTone(measured.toneSlices,genre:genre,hash:original.sha256)
    func distance(_ a:ToneAssessment)->Double {
        a.bands.prefix(6).reduce(0){total,b in
            guard let v=b.value,let lo=b.lower,let hi=b.upper else{return total}
            return total+max(0,max(lo-v,v-hi))
        }
    }
    let player=try AVAudioPlayer(contentsOf:preview.url)
    let prepared=player.prepareToPlay() // Never plays sound during automated validation.
    let object:[String:Any]=["source":url.lastPathComponent,"sourceUnchanged":try sha256(url)==original.sha256,
        "sameFrames":original.frames==measured.frames,"playbackPrepared":prepared,
        "filters":try JSONSerialization.jsonObject(with:JSONEncoder().encode(bands)),
        "beforeOutsideDistanceDB":distance(review),"afterOutsideDistanceDB":distance(assessment),
        "loudnessMatchErrorLU":(measured.integrated ?? 0)+preview.matchingDB-(original.integrated ?? 0),
        "previewPeakAfterGainDB":(measured.truePeakEstimate ?? 0)+preview.gainDB]
    return try JSONSerialization.data(withJSONObject:object,options:[.prettyPrinted,.sortedKeys])
}
