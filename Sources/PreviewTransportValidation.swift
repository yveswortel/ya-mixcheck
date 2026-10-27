import Foundation
import AVFoundation

// Deterministic control-plane tests. These do not measure the output device or
// certify Apple's native envelope shape; real render alignment is tested separately.
@MainActor private final class PreviewTestClock {
    var now=1000.0
    var pending=[(Double,@MainActor ()->Void)]()
    func schedule(_ delay:Double,_ work:@escaping @MainActor ()->Void){pending.append((now+delay,work))}
    func advance(_ seconds:Double) {
        let end=now+seconds
        var count=0
        while let next=pending.indices.min(by:{pending[$0].0<pending[$1].0}),pending[next].0<=end,count<100 {
            let event=pending.remove(at:next);now=event.0;event.1();count+=1
        }
        now=end
    }
}
@MainActor private final class PreviewTestChannel:PreviewPlaybackChannel {
    let clock:PreviewTestClock
    var duration=120.0,sampleRate=48000.0,numberOfChannels=2
    var volume:Float=0
    var starts=[Double](),ramps=[(Float,Double)]()
    var writes=0,stops=0,pauses=0,prepares=0
    var failStart=false
    private var active=false,base=0.0,start=0.0
    init(_ clock:PreviewTestClock){self.clock=clock}
    var deviceCurrentTime:Double{clock.now}
    var currentTime:Double {
        get{min(duration,base+(active ? max(0,clock.now-start):0))}
        set{base=newValue;writes+=1;if active{start=clock.now}}
    }
    var isPlaying:Bool{active && currentTime<duration}
    func prepareToPlay()->Bool{prepares+=1;return true}
    func play(atTime:Double)->Bool{starts.append(atTime);start=atTime;active = !failStart;return !failStart}
    func pause(){base=currentTime;active=false;pauses+=1}
    func stop(){base=0;active=false;stops+=1}
    func setVolume(_ volume:Float,fadeDuration:Double){self.volume=volume;ramps.append((volume,fadeDuration))}
}

@MainActor func validatePreviewTransport()throws->[TestOutcome] {
    var out=[TestOutcome]()
    func check(_ name:String,_ pass:Bool,_ detail:String=""){out.append(TestOutcome(name:"Preview transport: "+name,passed:pass,detail:detail))}
    let clock=PreviewTestClock()
    var made=[PreviewTestChannel]()
    let t=PreviewTransport(makeChannel:{_ in let p=PreviewTestChannel(clock);made.append(p);return p},schedule:{clock.schedule($0,$1)})
    let a=URL(fileURLWithPath:"/fixture/original.caf"),b=URL(fileURLWithPath:"/fixture/preview.caf")
    try t.configure(originalURL:a,previewURL:b,originalGain:0.6,previewGain:0.7,previewEnabled:false)
    let original=made[0],preview=made[1]
    try t.play(at:12.345)
    check("same file position and device timestamp for original and EQ",original.currentTime==preview.currentTime && original.currentTime==12.345 && original.starts==preview.starts && original.starts.count==1)
    check("scheduled start remains silent until device onset",original.volume==0 && preview.volume==0 && t.isTransitioning)
    clock.advance(0.029)
    check("preroll does not consume fade-in",original.ramps.isEmpty && preview.ramps.isEmpty)
    clock.advance(0.002)
    check("native fade-in requested only after scheduled start",!t.isTransitioning && t.isPlaying && original.ramps.last?.0==0.6 && original.ramps.last?.1==0.050 && preview.volume==0)
    let writes=original.writes+preview.writes,starts=original.starts.count+preview.starts.count
    t.setPreviewEnabled(true);clock.advance(0.05)
    check("EQ switch changes gains without restart or position write",original.volume==0 && preview.volume==0.7 && original.writes+preview.writes==writes && original.starts.count+preview.starts.count==starts && abs(original.currentTime-preview.currentTime)<1e-12)
    t.setPreviewEnabled(false);t.setPreviewEnabled(true);t.setPreviewEnabled(false)
    check("rapid EQ switching leaves latest selection audible",original.volume==0.6 && preview.volume==0 && made.count==2)
    try t.configure(originalURL:a,previewURL:b,originalGain:0.6,previewGain:0.7,previewEnabled:false)
    check("same configuration retains both players and their timeline",made.count==2 && original.starts.count+preview.starts.count==starts && original.writes+preview.writes==writes)

    t.pause()
    check("pause is logically immediate but fades before physical pause",!t.isPlaying && t.isTransitioning && original.isPlaying && original.volume==0 && preview.volume==0)
    clock.advance(0.051)
    check("pause settles common final position and keeps prepared pair",!t.isPlaying && !t.isTransitioning && !original.isPlaying && !preview.isPlaying && t.isConfigured && abs(t.currentTime-original.currentTime)<1e-12 && abs(original.currentTime-preview.currentTime)<1e-12)
    try t.play(at:t.currentTime);clock.advance(0.04)
    t.seek(to:40);t.seek(to:50)
    check("seek presents latest target while fading",t.isPlaying && t.isTransitioning && t.currentTime==50)
    clock.advance(0.051)
    check("rapid seek discards superseded target",original.currentTime==50 && preview.currentTime==50 && original.starts==preview.starts)
    clock.advance(0.04)
    t.seek(to:75);t.pause();clock.advance(0.051)
    check("pause during seek preserves requested target without restarting",!t.isPlaying && !t.isTransitioning && t.currentTime==75 && original.currentTime==75 && preview.currentTime==75)
    try t.play(at:75);clock.advance(0.04);t.pause();try t.play(at:120);clock.advance(0.085)
    check("play at EOF during pending pause wraps consistently",t.isPlaying && original.currentTime<0.01 && preview.currentTime<0.01 && original.starts==preview.starts)

    t.stop();let oldStops=original.stops
    try t.configure(originalURL:URL(fileURLWithPath:"/fixture/new.caf"),previewURL:nil,originalGain:0.5,previewGain:0.5,previewEnabled:false)
    let newer=made.last!
    try t.play(at:4);clock.advance(0.12)
    check("old deferred teardown cannot stop a new configuration",original.stops==oldStops+1 && preview.stops>0 && newer.stops==0 && t.isPlaying)
    t.stop();try t.configure(originalURL:a,previewURL:b,originalGain:0.6,previewGain:0.7,previewEnabled:true)
    let stoppedOriginal=made[made.count-2],stoppedPreview=made.last!
    try t.play(at:3);t.stop();clock.advance(0.1)
    check("stop during preroll cannot be undone by delayed fade-in",!t.isConfigured && !t.isPlaying && !t.isTransitioning && stoppedOriginal.volume==0 && stoppedPreview.volume==0 && stoppedOriginal.stops==1 && stoppedPreview.stops==1)

    let mismatch=PreviewTransport(makeChannel:{url in let p=PreviewTestChannel(clock);if url==b{p.duration+=0.1};return p},schedule:{clock.schedule($0,$1)})
    var rejected=false
    do{try mismatch.configure(originalURL:a,previewURL:b,originalGain:1,previewGain:1,previewEnabled:false)}catch{rejected=true}
    check("unaligned preview duration rejected before playback",rejected && !mismatch.isConfigured)
    let failure=PreviewTransport(makeChannel:{url in let p=PreviewTestChannel(clock);p.failStart=url==b;return p},schedule:{clock.schedule($0,$1)})
    try failure.configure(originalURL:a,previewURL:b,originalGain:1,previewGain:1,previewEnabled:false)
    rejected=false
    do{try failure.play(at:0)}catch{rejected=true}
    check("partial scheduled start failure tears down both players",rejected && !failure.isConfigured && !failure.isPlaying)
    return out
}

@MainActor private final class PreviewObservedChannel:PreviewPlaybackChannel {
    let player:PreviewPlaybackChannel
    var starts=[(requested:Double,issuedAt:Double,returnedAt:Double,wallMilliseconds:Double)]()
    var positions=[Double]()
    var maximumRequestedVolume:Float=0
    init(_ player:PreviewPlaybackChannel){self.player=player}
    var engineGraph:PreviewEngineGraph?{player.engineGraph}
    var currentTime:Double {get{player.currentTime}set{positions.append(newValue);player.currentTime=newValue}}
    var duration:Double{player.duration}
    var deviceCurrentTime:Double{player.deviceCurrentTime}
    var isPlaying:Bool{player.isPlaying}
    var volume:Float {get{player.volume}set{maximumRequestedVolume=max(maximumRequestedVolume,newValue);player.volume=newValue}}
    var sampleRate:Double{player.sampleRate}
    var numberOfChannels:Int{player.numberOfChannels}
    func prepareToPlay()->Bool{player.prepareToPlay()}
    func play(atTime:Double)->Bool{
        let issued=player.deviceCurrentTime,begin=ProcessInfo.processInfo.systemUptime
        let success=player.play(atTime:atTime)
        starts.append((atTime,issued,player.deviceCurrentTime,(ProcessInfo.processInfo.systemUptime-begin)*1000))
        return success
    }
    func pause(){player.pause()}
    func stop(){player.stop()}
    func setVolume(_ volume:Float,fadeDuration:Double){maximumRequestedVolume=max(maximumRequestedVolume,volume);player.setVolume(volume,fadeDuration:fadeDuration)}
}

// Opt-in only: uses the real audio device with both player gains fixed at zero.
// It measures player-clock agreement, not captured output samples or audible clicks.
@MainActor func validatePreviewTransportDevice()throws->[TestOutcome] {
    var out=[TestOutcome]()
    func check(_ name:String,_ pass:Bool,_ detail:String=""){out.append(TestOutcome(name:"Native silent transport: "+name,passed:pass,detail:detail))}
    let fm=FileManager.default,dir=fm.temporaryDirectory.appendingPathComponent("ya-transport-device-"+UUID().uuidString,isDirectory:true)
    try fm.createDirectory(at:dir,withIntermediateDirectories:false)
    defer{try? fm.removeItem(at:dir)}
    let originalURL=dir.appendingPathComponent("original.wav"),previewURL=dir.appendingPathComponent("preview.caf")
    let rate=48000.0,frames=192000
    let format=AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:rate,channels:2,interleaved:true)!
    let settings:[String:Any]=[AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:rate,AVNumberOfChannelsKey:2,AVLinearPCMBitDepthKey:32,AVLinearPCMIsFloatKey:true,AVLinearPCMIsNonInterleaved:false]
    do {
        let a=try AVAudioFile(forWriting:originalURL,settings:settings,commonFormat:.pcmFormatFloat32,interleaved:true)
        let b=try AVAudioFile(forWriting:previewURL,settings:settings,commonFormat:.pcmFormatFloat32,interleaved:true)
        let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:4096)!
        var written=0
        while written<frames {
            let count=min(4096,frames-written);buffer.frameLength=AVAudioFrameCount(count)
            let samples=buffer.floatChannelData![0]
            for n in 0..<count {let sample=Float(0.2*sin(2*Double.pi*233*Double(written+n)/rate));samples[n*2]=sample;samples[n*2+1]=sample}
            try a.write(from:buffer);try b.write(from:buffer);written+=count
        }
    }
    var channels=[PreviewObservedChannel](),failures=[String]()
    let graph=try PreviewEngineGraph()
    let t=PreviewTransport(makeChannel:{url in let p=PreviewObservedChannel(try graph.makeChannel(url));channels.append(p);return p})
    t.onFailure={failures.append($0)}
    defer{t.stop(immediate:true)}
    func pump(_ seconds:Double){let deadline=Date().addingTimeInterval(seconds);while Date()<deadline{RunLoop.current.run(until:min(deadline,Date().addingTimeInterval(0.005)))}}
    func wait(_ predicate:()->Bool,timeout:Double=2)->Bool {
        let deadline=Date().addingTimeInterval(timeout)
        while !predicate() && Date()<deadline{RunLoop.current.run(until:Date().addingTimeInterval(0.005))}
        return predicate()
    }
    do {
        try t.configure(originalURL:originalURL,previewURL:previewURL,originalGain:0,previewGain:0,previewEnabled:false)
        try t.play(at:0)
    } catch {
        check("device and synchronized start available",false,"Native device preparation/start failed: \(error.localizedDescription). No audible signal was requested. Native requests: \(channels.map{$0.starts})")
        return out
    }
    let ready=wait{!t.isTransitioning && t.isPlaying && channels.allSatisfy{$0.isPlaying}}
    check("device and synchronized start available",ready,"\(failures.joined(separator:"; "))")
    guard ready,channels.count==2 else{return out}
    let a=channels[0],b=channels[1]
    check("shared future device-clock start requested",a.starts.count==1 && b.starts.count==1 && a.starts[0].requested==b.starts[0].requested && a.starts[0].requested>a.starts[0].issuedAt && b.starts[0].requested>b.starts[0].issuedAt,"A request \(a.starts[0].requested), B request \(b.starts[0].requested); this is scheduling evidence, not captured output.")
    // Bracket B by two A reads so time spent querying does not count as drift.
    func driftMS()->Double {
        let a0=a.currentTime,b0=b.currentTime,a1=a.currentTime
        return max(0,max(min(a0,a1)-b0,b0-max(a0,a1)))*1000
    }
    func maximumDriftMS()->Double {
        var peak=0.0
        for _ in 0..<8{peak=max(peak,driftMS());pump(0.005)}
        return peak
    }
    let initialDrift=maximumDriftMS()
    check("native pair clocks agree after start",initialDrift<=2,"Maximum bracketed currentTime drift \(initialDrift) ms; tolerance 2 ms, not sample-exact certification.")
    let startCount=a.starts.count+b.starts.count,writeCount=a.positions.count+b.positions.count,before=t.currentTime
    t.setPreviewEnabled(true);pump(0.06)
    let after=t.currentTime,toggleDrift=maximumDriftMS()
    check("EQ toggle keeps the native timeline running",t.isPlaying && after>before && after-before<0.25 && startCount==a.starts.count+b.starts.count && writeCount==a.positions.count+b.positions.count,"Position advanced \((after-before)*1000) ms; no new play or position-set calls.")
    check("native pair clocks agree after EQ toggle",toggleDrift<=2,"Maximum bracketed drift \(toggleDrift) ms.")
    t.seek(to:1.5)
    let sought=wait{!t.isTransitioning && t.isPlaying},seekTime=t.currentTime,seekDrift=maximumDriftMS()
    check("native seek settles at requested passage",sought && a.positions.last==1.5 && b.positions.last==1.5 && seekTime>=1.5 && seekTime<1.75,"Settled time \(seekTime) s after requested 1.5 s.")
    check("native pair clocks agree after seek",seekDrift<=2,"Maximum bracketed drift \(seekDrift) ms.")
    t.seek(to:2.5);t.seek(to:0.5)
    let latest=wait{!t.isTransitioning && t.isPlaying},latestTime=t.currentTime,latestDrift=maximumDriftMS()
    check("native rapid seek keeps latest target",latest && a.positions.last==0.5 && b.positions.last==0.5 && latestTime>=0.5 && latestTime<0.75 && latestDrift<=2,"Settled time \(latestTime) s; maximum bracketed drift \(latestDrift) ms.")
    t.pause();let paused=wait{!t.isTransitioning},pausedAt=t.currentTime; pump(0.05)
    check("native pause settles and remains stopped",paused && !t.isPlaying && !a.isPlaying && !b.isPlaying && abs(t.currentTime-pausedAt)<=1/rate && driftMS()<=2,"Paused at \(pausedAt) s; subsequent change \((t.currentTime-pausedAt)*1000) ms.")
    check("all native playback remained muted",channels.allSatisfy{$0.maximumRequestedVolume==0 && $0.volume==0},"Both original and EQ gains were zero throughout; no audible-output test.")
    check("no deferred native transport failure",failures.isEmpty,failures.joined(separator:"; "))
    return out
}
