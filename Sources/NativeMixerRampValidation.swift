import Foundation
import AVFoundation

// Real Apple mixer PCM, driven offline: no audio device output or user music.
// Uses the production atomic gain state and its per-render scheduling contract.
@MainActor func validateNativeMixerRamps() throws -> [TestOutcome] {
    var results=[TestOutcome]()
    func check(_ name:String,_ pass:Bool,_ detail:String="") {
        results.append(TestOutcome(name:name,passed:pass,detail:detail))
    }
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent("ya-native-ramp-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false)
    defer{try? FileManager.default.removeItem(at:directory)}
    for rate in [44100.0,48000.0,96000.0] {for chunk in [64,127,511,1024] {
        let label="Native mixer \(Int(rate)) Hz / \(chunk) frames"
        let fadeFrames=Int((rate*0.050).rounded()),fileStart=333,total=fadeFrames*5+chunk*20
        let engine=AVAudioEngine(),a=AVAudioPlayerNode(),b=AVAudioPlayerNode(),mixer=AVAudioMixerNode()
        let format=AVAudioFormat(standardFormatWithSampleRate:rate,channels:2)!
        engine.attach(a);engine.attach(b);engine.attach(mixer)
        engine.connect(a,to:mixer,fromBus:0,toBus:0,format:format)
        engine.connect(b,to:mixer,fromBus:0,toBus:1,format:format)
        engine.connect(mixer,to:engine.mainMixerNode,format:format)
        let unit=mixer.auAudioUnit
        guard let ga=unit.parameterTree?.parameter(withID:kMultiChannelMixerParam_Volume,scope:kAudioUnitScope_Input,element:0),
              let gb=unit.parameterTree?.parameter(withID:kMultiChannelMixerParam_Volume,scope:kAudioUnitScope_Input,element:1),
              ga.flags.contains(.flag_CanRamp),gb.flags.contains(.flag_CanRamp),
              let state=qcg_create(rate,0.050) else{throw QCFailure(message:"Native ramp validation could not prepare gain parameters.")}
        let schedule=unit.scheduleParameterBlock,addressA=ga.address,addressB=gb.address
        let observer=unit.token(byAddingRenderObserver:{flags,_,count,_ in
            guard flags.contains(.unitRenderAction_PreRender) else{return}
            var ramp=QCGainRamp();qcg_next(state,count,&ramp)
            if ramp.remainingFrames>0 {
                schedule(AUEventSampleTimeImmediate,ramp.remainingFrames,addressA,ramp.targetA)
                schedule(AUEventSampleTimeImmediate,ramp.remainingFrames,addressB,ramp.targetB)
            }
        })
        defer{engine.stop();unit.removeRenderObserver(observer);qcg_destroy(state)}

        let originalURL=directory.appendingPathComponent("a-\(Int(rate))-\(chunk).wav")
        let previewURL=directory.appendingPathComponent("b-\(Int(rate))-\(chunk).caf")
        func signal(_ frame:Int)->Float {Float(0.2*sin(Double(frame)*0.734)+0.09*cos(Double(frame)*0.197))}
        var pcmA=[Float](repeating:0,count:(total+fileStart)*2),pcmB=pcmA
        for frame in 0..<total+fileStart {
            let value=signal(frame)
            pcmA[frame*2]=value;pcmB[frame*2]=value
            pcmA[frame*2+1]=0.25;pcmB[frame*2+1] = -0.25
        }
        try writeTestAudio(originalURL,samples:pcmA,rate:rate,channels:2)
        try writeTestAudio(previewURL,samples:pcmB,rate:rate,channels:2)
        let fa=try AVAudioFile(forReading:originalURL,commonFormat:.pcmFormatFloat32,interleaved:false)
        let fb=try AVAudioFile(forReading:previewURL,commonFormat:.pcmFormatFloat32,interleaved:false)
        a.scheduleSegment(fa,startingFrame:AVAudioFramePosition(fileStart),frameCount:AVAudioFrameCount(total),at:nil)
        b.scheduleSegment(fb,startingFrame:AVAudioFramePosition(fileStart),frameCount:AVAudioFrameCount(total),at:nil)
        try engine.enableManualRenderingMode(.offline,format:format,maximumFrameCount:1024)
        engine.prepare();ga.value=0;gb.value=0;try engine.start()
        let output=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:1024)!
        // Match production: the graph runs silently before the scheduled player
        // start and fade-in. The Apple mixer initializes its dezipper on its first
        // render; submitting an audible ramp in that first block skips its slope.
        let priming=try engine.renderOffline(AVAudioFrameCount(chunk),to:output)
        check(label+": graph priming is silent",priming == .success && Int(output.frameLength)==chunk &&
              (0..<2).allSatisfy{channel in (0..<chunk).allSatisfy{output.floatChannelData![channel][$0]==0}})
        let start=AVAudioTime(sampleTime:engine.manualRenderingSampleTime,atRate:rate)
        a.play(at:start);b.play(at:start)
        var left=[Float](),right=[Float](),allSuccess=true
        typealias Change=(frame:Int,a:Double,b:Double,targetA:Double,targetB:Double)
        var changes=[Change]()
        func expected(_ frame:Int)->(Double,Double) {
            guard let change=changes.last(where:{$0.frame<=frame}) else{return (0,0)}
            let fraction=max(0,min(1,Double(frame-change.frame)/Double(fadeFrames)))
            return (change.a+(change.targetA-change.a)*fraction,change.b+(change.targetB-change.b)*fraction)
        }
        func target(_ gainA:Float,_ gainB:Float) {
            let before=expected(left.count)
            changes.append((left.count,before.0,before.1,Double(gainA),Double(gainB)))
            qcg_set_targets(state,gainA,gainB)
        }
        func render(_ frames:Int)throws {
            var remaining=frames
            while remaining>0 {
                let count=min(chunk,remaining),status=try engine.renderOffline(AVAudioFrameCount(count),to:output)
                allSuccess = allSuccess && status == .success && Int(output.frameLength)==count
                guard output.frameLength>0 else{throw QCFailure(message:"Native offline ramp validation made no render progress.")}
                for frame in 0..<Int(output.frameLength) {left.append(output.floatChannelData![0][frame]);right.append(output.floatChannelData![1][frame])}
                remaining-=Int(output.frameLength)
            }
        }
        target(1,0);try render(fadeFrames+chunk*2)
        let originalOnly=left.count-1
        target(0,1);try render(max(chunk,Int(Double(fadeFrames)*0.37)))
        let retargetFrame=left.count
        target(1,0);try render(fadeFrames+chunk*2)
        target(0,1);try render(fadeFrames+chunk*2)
        let previewOnly=left.count-1
        target(0,0);let silenceStart=left.count+fadeFrames
        try render(fadeFrames+chunk*2)

        var leftError=0.0,rightError=0.0,derivativeError=0.0
        for frame in left.indices {
            let gains=expected(frame)
            leftError=max(leftError,abs(Double(left[frame])-Double(signal(frame+fileStart))*(gains.0+gains.1)))
            rightError=max(rightError,abs(Double(right[frame])-0.25*(gains.0-gains.1)))
            if frame>0 {
                let before=expected(frame-1)
                let step=0.25*((gains.0-gains.1)-(before.0-before.1))
                derivativeError=max(derivativeError,abs(Double(right[frame]-right[frame-1])-step))
            }
        }
        let tolerance=2e-6
        check(label+": all native render calls complete",allSuccess)
        check(label+": identical file channels stay sample-aligned through crossfades",leftError<tolerance,"Maximum null/model error \(leftError); equal PCM from WAV/CAF, same seek frame \(fileStart).")
        check(label+": real fade endpoints and retarget follow 50ms envelope",rightError<tolerance && right[originalOnly]==0.25 && right[previewOnly] == -0.25,"Maximum envelope error \(rightError); mid-ramp reversal at frame \(retargetFrame).")
        check(label+": no chunk-boundary or retarget discontinuity",derivativeError<tolerance,"Maximum unexpected sample-step error \(derivativeError).")
        check(label+": final fade reaches exact silence before pause",left[silenceStart...].allSatisfy{$0==0} && right[silenceStart...].allSatisfy{$0==0},"Silence from frame \(silenceStart); tests actual PCM, not only parameter values.")
    }}
    return results
}
