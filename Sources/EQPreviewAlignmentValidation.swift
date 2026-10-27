import Foundation
import AVFoundation

// File alignment only: these tests do not claim device-clock or audible playback accuracy.
func validateEQPreviewAlignment() throws -> [TestOutcome] {
    var results=[TestOutcome]()
    func check(_ name:String,_ pass:Bool,_ detail:String="") {
        results.append(TestOutcome(name:name,passed:pass,detail:detail))
    }
    func readPCM(_ url:URL)throws->(frames:Int64,rate:Double,channels:Int,samples:[Float]) {
        let input=try AudioInput(url),channels=Int(input.format.channelCount)
        let buffer=AVAudioPCMBuffer(pcmFormat:input.format,frameCapacity:4093)!
        var values=[Float]();values.reserveCapacity(Int(input.length)*channels)
        while Int64(values.count/channels)<input.length {
            try input.read(into:buffer,frameCount:4093)
            guard buffer.frameLength>0,let data=buffer.floatChannelData?[0] else {
                throw QCFailure(message:"Alignment fixture ended unexpectedly.")
            }
            values.append(contentsOf:UnsafeBufferPointer(start:data,count:Int(buffer.frameLength)*channels))
        }
        try input.finish()
        return (input.length,input.format.sampleRate,channels,values)
    }
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent("ya-eq-alignment-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false)
    defer{try? FileManager.default.removeItem(at:directory)}
    for rate in [44100,48000,96000] {for channels in [1,2] {
        let label="EQ alignment \(rate) Hz / \(channels) ch",frames=rate+37
        let sourceURL=directory.appendingPathComponent("source-\(rate)-\(channels).wav")
        var samples=[Float](repeating:0,count:frames*channels)
        for frame in 0..<frames {for channel in 0..<channels {
            samples[frame*channels+channel]=Float(0.07*sin(Double(frame)*0.137+Double(channel)*0.7))
        }}
        // Nonzero boundaries catch trimming, padding, dropped final chunks and channel shifts.
        for channel in 0..<channels {
            samples[channel]=Float(0.123+Double(channel)*0.1)
            samples[(frames-1)*channels+channel]=Float(-0.234-Double(channel)*0.1)
        }
        try writeTestAudio(sourceURL,samples:samples,rate:Double(rate),channels:channels)
        let source=try Analyzer.run(sourceURL,makePreview:false),hash=try sha256(sourceURL)
        let neutral=try renderEQPreview(PreviewSource(source),bands:[35.0,85,175,350,1000,5000].map{PreviewBand(hz:$0,gain:0)},cancellation:Cancellation(),progress:{_ in})
        defer{neutral.remove()}
        let rendered=try readPCM(neutral.url)
        check(label+": neutral EQ preserves format and frame count",rendered.frames==Int64(frames) && rendered.rate==Double(rate) && rendered.channels==channels)
        check(label+": neutral EQ sample-identical across all chunks",rendered.samples==samples)
        check(label+": first and last frame remain aligned",Array(rendered.samples.prefix(channels))==Array(samples.prefix(channels)) && Array(rendered.samples.suffix(channels))==Array(samples.suffix(channels)))
        let originalPlayer=try AVAudioPlayer(contentsOf:sourceURL),previewPlayer=try AVAudioPlayer(contentsOf:neutral.url)
        check(label+": native players expose compatible timelines",originalPlayer.format.sampleRate==previewPlayer.format.sampleRate && originalPlayer.numberOfChannels==previewPlayer.numberOfChannels && abs(originalPlayer.duration-previewPlayer.duration)<=1.1/Double(rate))
        check(label+": original hash unchanged",try sha256(sourceURL)==hash)

        let impulseURL=directory.appendingPathComponent("impulse-\(rate)-\(channels).wav"),onset=8191
        var impulse=[Float](repeating:0,count:frames*channels)
        for channel in 0..<channels {impulse[onset*channels+channel]=Float(channel==0 ? 0.4:-0.3)}
        try writeTestAudio(impulseURL,samples:impulse,rate:Double(rate),channels:channels)
        let impulseAnalysis=try Analyzer.run(impulseURL,makePreview:false),impulseHash=try sha256(impulseURL)
        let filtered=try renderEQPreview(PreviewSource(impulseAnalysis),bands:[PreviewBand(hz:350,gain:3),PreviewBand(hz:5000,gain:-2)],cancellation:Cancellation(),progress:{_ in})
        defer{filtered.remove()}
        let filteredPCM=try readPCM(filtered.url)
        check(label+": active EQ has no inserted whole-sample delay",filteredPCM.samples.count==impulse.count && (0..<channels).allSatisfy{channel in
            (0..<frames).first(where:{filteredPCM.samples[$0*channels+channel] != 0})==onset
        })
        let afterImpulseHash=try sha256(impulseURL)
        check(label+": active EQ preserves length and source hash",filteredPCM.frames==Int64(frames) && afterImpulseHash==impulseHash)
    }}
    return results
}
