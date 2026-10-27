import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio
import Darwin

// A small channel boundary makes transport sequencing testable without emitting sound.
@MainActor protocol PreviewPlaybackChannel:AnyObject {
    var engineGraph:PreviewEngineGraph? {get}
    var currentTime:TimeInterval {get set}
    var duration:TimeInterval {get}
    var deviceCurrentTime:TimeInterval {get}
    var isPlaying:Bool {get}
    var volume:Float {get set}
    var sampleRate:Double {get}
    var numberOfChannels:Int {get}
    func prepareToPlay()->Bool
    func play(atTime:TimeInterval)->Bool
    func pause()
    func stop()
    func setVolume(_ volume:Float,fadeDuration:TimeInterval)
}
extension PreviewPlaybackChannel {var engineGraph:PreviewEngineGraph?{nil}}
extension AVAudioPlayer:PreviewPlaybackChannel {
    var sampleRate:Double {format.sampleRate}
}

// Both versions remain running on the same device clock. EQ comparison changes
// their gains, never their file positions. Only deliberate transport gestures
// have short fades; analysis, source files and exported reports are untouched.
@MainActor final class PreviewTransport {
    typealias Schedule=(_ delay:TimeInterval,_ action:@escaping @MainActor ()->Void)->Void
    private let makeChannel:((URL)throws->PreviewPlaybackChannel)?
    private let schedule:Schedule
    private let fadeDuration:TimeInterval=0.050
    private let startLead:TimeInterval=0.030
    private var original:PreviewPlaybackChannel?
    private var preview:PreviewPlaybackChannel?
    private var originalURL:URL?
    private var previewURL:URL?
    private var originalGain:Float=1
    private var previewGain:Float=1
    private var previewEnabled=false
    private var generation:UInt64=0
    private var wantsPlayback=false
    private var heldTime:TimeInterval=0
    private(set) var isTransitioning=false
    var onFailure:((String)->Void)?

    init(makeChannel:((URL)throws->PreviewPlaybackChannel)?=nil,
         schedule:@escaping Schedule={delay,action in DispatchQueue.main.asyncAfter(deadline:.now()+delay){action()}}) {
        self.makeChannel=makeChannel;self.schedule=schedule
    }
    var isConfigured:Bool {original != nil}
    var isPlaying:Bool {wantsPlayback && (isTransitioning || original?.isPlaying==true)}
    var currentTime:TimeInterval {
        guard let original else{return heldTime}
        if isTransitioning || !wantsPlayback{return heldTime}
        return original.isPlaying ? original.currentTime:original.duration
    }

    func configure(originalURL:URL,previewURL:URL?,originalGain:Float,previewGain:Float,previewEnabled:Bool)throws {
        guard originalGain.isFinite,previewGain.isFinite,originalGain>=0,previewGain>=0 else{throw QCFailure(message:"Ongeldige luistergain.")}
        if self.originalURL==originalURL,self.previewURL==previewURL,original != nil {
            self.originalGain=min(1,originalGain);self.previewGain=min(1,previewGain)
            setPreviewEnabled(previewEnabled)
            return
        }
        let graph=makeChannel==nil ? try PreviewEngineGraph():nil
        let factory=makeChannel ?? {try graph!.makeChannel($0)}
        let a=try factory(originalURL),b=try previewURL.map{try factory($0)}
        guard a.duration>0,a.sampleRate>0 else{throw QCFailure(message:"Geen afspeelbare audio.")}
        if let b {
            guard a.sampleRate==b.sampleRate,a.numberOfChannels==b.numberOfChannels,
                  abs(a.duration-b.duration)<=1.1/a.sampleRate else{throw QCFailure(message:"EQ-preview heeft een andere tijdlijn. Maak de preview opnieuw.")}
        }
        a.volume=0;b?.volume=0
        guard a.prepareToPlay(),b?.prepareToPlay() ?? true else{throw QCFailure(message:"Playback kon niet worden voorbereid.")}
        stop()
        original=a;preview=b;self.originalURL=originalURL;self.previewURL=previewURL
        self.originalGain=min(1,originalGain);self.previewGain=min(1,previewGain)
        self.previewEnabled=previewEnabled && b != nil;heldTime=0
    }
    private var channels:[PreviewPlaybackChannel] {[original,preview].compactMap{$0}}
    private var fadeWait:TimeInterval{fadeDuration+(original?.engineGraph?.fadeSettleMargin ?? 0)}
    private func clamp(_ time:TimeInterval)->TimeInterval {max(0,min(time.isFinite ? time:0,original?.duration ?? 0))}
    private func setPositions(_ time:TimeInterval){for p in channels{p.currentTime=time}}
    private func fadeToSelection() {
        if let graph=original?.engineGraph {
            graph.setGains(previewEnabled ? 0:originalGain,previewEnabled ? previewGain:0)
        } else {
            original?.setVolume(previewEnabled ? 0:originalGain,fadeDuration:fadeDuration)
            preview?.setVolume(previewEnabled ? previewGain:0,fadeDuration:fadeDuration)
        }
    }
    private func fadeToSilence(){if let graph=original?.engineGraph{graph.setGains(0,0)}else{for p in channels{p.setVolume(0,fadeDuration:fadeDuration)}}}
    func setPreviewEnabled(_ enabled:Bool) {
        previewEnabled=enabled && preview != nil
        if wantsPlayback && !isTransitioning {fadeToSelection()}
    }

    func play(at time:TimeInterval)throws {
        guard let original else{throw QCFailure(message:"Open eerst een audiobestand.")}
        let bounded=clamp(time),target=bounded>=original.duration ? 0:bounded
        generation &+= 1;let token=generation
        heldTime=target;wantsPlayback=true;isTransitioning=true
        if channels.contains(where:{$0.isPlaying}) {
            fadeToSilence()
            schedule(fadeWait){[weak self] in
                guard let self,self.generation==token else{return}
                for p in self.channels{p.pause()}
                do{try self.startPair(at:target,token:token)}catch{self.failed(error)}
            }
        } else {
            do{try startPair(at:target,token:token)}
            catch{failed(error);throw error}
        }
    }
    private func startPair(at time:TimeInterval,token:UInt64)throws {
        guard let original,generation==token,wantsPlayback else{return}
        heldTime=time;setPositions(time)
        for p in channels{p.volume=0;guard p.prepareToPlay() else{throw QCFailure(message:"Playback kon niet worden voorbereid.")}}
        let start=original.deviceCurrentTime+startLead
        for p in channels{guard p.play(atTime:start) else{throw QCFailure(message:"Gesynchroniseerde playback kon niet starten.")}}
        guard original.deviceCurrentTime<start else{throw QCFailure(message:"Audiotoestel reageerde te laat voor gelijklopende playback. Probeer opnieuw.")}
        // A native volume ramp can advance during scheduled preroll. Begin it
        // only after the scheduled start; main-thread delay adds silence, not a step.
        schedule(max(0,start-original.deviceCurrentTime)){[weak self] in
            guard let self,self.generation==token,self.wantsPlayback else{return}
            self.isTransitioning=false;self.fadeToSelection()
        }
    }
    private func failed(_ error:Error){stop(immediate:true);onFailure?(error.localizedDescription)}

    func pause() {
        guard original != nil else{return}
        let settleTarget=isTransitioning
        heldTime=currentTime;wantsPlayback=false;isTransitioning=true
        generation &+= 1;let token=generation
        fadeToSilence()
        schedule(fadeWait){[weak self] in
            guard let self,self.generation==token else{return}
            let time=settleTarget ? self.heldTime:(self.original?.currentTime ?? self.heldTime)
            for p in self.channels{p.pause()}
            // pause() itself can block differently per player. Both are silent
            // now; reset to one captured position so paused timelines also agree.
            self.setPositions(time)
            self.heldTime=time;self.isTransitioning=false
        }
    }
    func seek(to time:TimeInterval) {
        guard let original else{heldTime=max(0,time.isFinite ? time:0);return}
        let target=clamp(time),resume=wantsPlayback && target<original.duration
        heldTime=target;wantsPlayback=resume;isTransitioning=true
        generation &+= 1;let token=generation
        let live=channels.contains(where:{$0.isPlaying})
        fadeToSilence()
        let relocate:@MainActor ()->Void = {[weak self] in
            guard let self,self.generation==token else{return}
            for p in self.channels{p.pause()}
            self.setPositions(target)
            if resume {do{try self.startPair(at:target,token:token)}catch{self.failed(error)}}
            else{self.isTransitioning=false}
        }
        if live{schedule(fadeWait,relocate)}else{relocate()}
    }
    func stop(immediate:Bool=false) {
        generation &+= 1;wantsPlayback=false;isTransitioning=false
        let retiring=channels,wait=fadeWait
        original=nil;preview=nil;originalURL=nil;previewURL=nil;heldTime=0
        if immediate {for p in retiring{p.stop()};return}
        if let graph=retiring.first?.engineGraph{graph.setGains(0,0)}else{for p in retiring{p.setVolume(0,fadeDuration:fadeDuration)}}
        // Capture only the retired pair: a later configure cannot be stopped by this callback.
        schedule(wait){for p in retiring{p.stop()}}
    }
}

// One render graph supplies the same sample/host clock to both file players.
// The mixer input gains are fed coherently once per render quantum; the C state
// holds only two floats and a finite ramp, with no audio-thread allocation/locks.
@MainActor final class PreviewEngineGraph {
    let engine=AVAudioEngine(),mixer=AVAudioMixerNode()
    private let unit:AUAudioUnit
    private let gainA:AUParameter,gainB:AUParameter
    private let scheduleGain:AUScheduleParameterBlock
    private var gainState:OpaquePointer?
    private var observer:Int?
    private var nextBus:AVAudioNodeBus=0
    private var desiredA:Float=0,desiredB:Float=0
    private(set) var fadeSettleMargin=0.050
    init()throws {
        unit=mixer.auAudioUnit
        guard let a=unit.parameterTree?.parameter(withID:kMultiChannelMixerParam_Volume,scope:kAudioUnitScope_Input,element:0),
              let b=unit.parameterTree?.parameter(withID:kMultiChannelMixerParam_Volume,scope:kAudioUnitScope_Input,element:1),
              a.flags.contains(.flag_CanRamp),b.flags.contains(.flag_CanRamp) else{throw QCFailure(message:"Audiomixer ondersteunt geen vloeiende vergelijking.")}
        gainA=a;gainB=b;scheduleGain=unit.scheduleParameterBlock
        engine.attach(mixer);gainA.value=0;gainB.value=0
    }
    deinit {
        engine.stop()
        if let observer{unit.removeRenderObserver(observer)}
        if let gainState{qcg_destroy(gainState)}
    }
    func makeChannel(_ url:URL)throws->PreviewPlaybackChannel {
        guard nextBus<2 else{throw QCFailure(message:"Te veel afspeelbronnen.")}
        let file=try AVAudioFile(forReading:url,commonFormat:.pcmFormatFloat32,interleaved:false)
        let player=AVAudioPlayerNode(),bus=nextBus;nextBus+=1
        engine.attach(player)
        engine.connect(player,to:mixer,fromBus:0,toBus:bus,format:file.processingFormat)
        if bus==0 {
            engine.connect(mixer,to:engine.mainMixerNode,format:file.processingFormat)
            guard let state=qcg_create(file.processingFormat.sampleRate,0.050) else{throw QCFailure(message:"Luisterfades konden niet worden voorbereid.")}
            gainState=state
            let block=scheduleGain,addressA=gainA.address,addressB=gainB.address
            observer=unit.token(byAddingRenderObserver:{flags,_,frames,_ in
                if flags.contains(.unitRenderAction_PostRender),frames>0 {qcg_set_rendered(state,1)}
                guard flags.contains(.unitRenderAction_PreRender) else{return}
                var ramp=QCGainRamp()
                qcg_next(state,frames,&ramp)
                // The v2 mixer bridge consumes ramps per render cycle. Resubmit
                // the FINAL target with remaining duration, not a tiny block ramp
                // (which would repeatedly trigger the mixer's internal dezipper).
                if ramp.remainingFrames>0 {
                    block(AUEventSampleTimeImmediate,ramp.remainingFrames,addressA,ramp.targetA)
                    block(AUEventSampleTimeImmediate,ramp.remainingFrames,addressB,ramp.targetB)
                }
            })
        }
        return PreviewEngineChannel(graph:self,file:file,node:player,bus:bus)
    }
    func prepare()throws {
        guard !engine.isRunning else{return}
        engine.prepare()
        // Connections/resource allocation may reset mixer inputs. No players are
        // running yet; establish silence after preparation, before device start.
        gainA.value=0;gainB.value=0
        guard let gainState else{throw QCFailure(message:"Luisterfades zijn niet voorbereid.")}
        qcg_set_rendered(gainState,0)
        try engine.start()
        // The native mixer initializes its DSP in the first render quantum. Do
        // that silently before scheduling files or publishing a nonzero target.
        // Only this control-thread startup waits; the audio callback stores an
        // atomic flag after rendering and never sleeps or signals a semaphore.
        let deadline=ProcessInfo.processInfo.systemUptime+0.5
        while qcg_has_rendered(gainState)==0 && ProcessInfo.processInfo.systemUptime<deadline {Thread.sleep(forTimeInterval:0.001)}
        guard qcg_has_rendered(gainState) != 0 else{engine.stop();throw QCFailure(message:"Audiotoestel kon de stille opstart niet afronden. Probeer opnieuw.")}
        // Two device quanta cover command pickup plus the last ramp quantum.
        let device=engine.outputNode.auAudioUnit.deviceID
        var address=AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyBufferFrameSize,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
        var frames:UInt32=0,size=UInt32(MemoryLayout<UInt32>.size)
        let rate=engine.outputNode.outputFormat(forBus:0).sampleRate
        if AudioObjectGetPropertyData(device,&address,0,nil,&size,&frames)==noErr,frames>0,rate>0 {fadeSettleMargin=max(0.005,2*Double(frames)/rate)}
    }
    func setGains(_ a:Float,_ b:Float){desiredA=a;desiredB=b;if let gainState{qcg_set_targets(gainState,a,b)}}
    func setGain(_ gain:Float,bus:AVAudioNodeBus){if bus==0{setGains(gain,desiredB)}else{setGains(desiredA,gain)}}
    func gain(_ bus:AVAudioNodeBus)->Float{bus==0 ? desiredA:desiredB}
}

@MainActor final class PreviewEngineChannel:PreviewPlaybackChannel {
    let graph:PreviewEngineGraph,file:AVAudioFile,node:AVAudioPlayerNode,bus:AVAudioNodeBus
    private var baseFrame:AVAudioFramePosition=0
    private var held=0.0,scheduled=false
    init(graph:PreviewEngineGraph,file:AVAudioFile,node:AVAudioPlayerNode,bus:AVAudioNodeBus){self.graph=graph;self.file=file;self.node=node;self.bus=bus}
    var engineGraph:PreviewEngineGraph?{graph}
    var sampleRate:Double{file.processingFormat.sampleRate}
    var numberOfChannels:Int{Int(file.processingFormat.channelCount)}
    var duration:Double{Double(file.length)/sampleRate}
    var deviceCurrentTime:Double{AVAudioTime.seconds(forHostTime:mach_absolute_time())}
    var currentTime:Double {
        get {
            guard node.isPlaying,let render=node.lastRenderTime,let player=node.playerTime(forNodeTime:render) else{return held}
            return min(duration,Double(baseFrame)/sampleRate+max(0,Double(player.sampleTime)/player.sampleRate))
        }
        set {node.stop();baseFrame=AVAudioFramePosition((max(0,min(duration,newValue))*sampleRate).rounded());held=Double(baseFrame)/sampleRate;scheduled=false}
    }
    var isPlaying:Bool{node.isPlaying && currentTime<duration && graph.engine.isRunning}
    var volume:Float{get{graph.gain(bus)}set{graph.setGain(newValue,bus:bus)}}
    func prepareToPlay()->Bool {
        do {
            if !scheduled {
                let remaining=file.length-baseFrame
                guard remaining>0,remaining<=Int64(UInt32.max) else{return false}
                node.scheduleSegment(file,startingFrame:baseFrame,frameCount:AVAudioFrameCount(remaining),at:nil)
                node.prepare(withFrameCount:AVAudioFrameCount(min(4096,remaining)));scheduled=true
            }
            try graph.prepare();return true
        }catch{return false}
    }
    func play(atTime:Double)->Bool{guard scheduled,graph.engine.isRunning else{return false};node.play(at:AVAudioTime(hostTime:AVAudioTime.hostTime(forSeconds:atTime)));return true}
    func pause(){held=currentTime;node.pause()}
    func stop(){node.stop();baseFrame=0;held=0;scheduled=false}
    func setVolume(_ volume:Float,fadeDuration:Double){graph.setGain(volume,bus:bus)}
}
