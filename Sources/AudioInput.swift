import Foundation
import AVFoundation

// Owned by an analysis result. Float PCM cache is removed on replacement, cancellation or failure.
final class DecodedAudio: Encodable {
    let directory: URL
    var url: URL { directory.appendingPathComponent("preview.caf") }
    init() throws {
        directory=FileManager.default.temporaryDirectory.appendingPathComponent("ya-mixcheck-decode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
    }
    func remove(){try? FileManager.default.removeItem(at:directory)}
    deinit {remove()}
    func encode(to encoder: Encoder) throws {var c=encoder.singleValueContainer();try c.encode("temporary float32 PCM; same decode for measurement and playback")}
}
final class AudioInput {
    var native: AVAudioFile?
    var mp3: OpaquePointer?
    var flac: OpaquePointer?
    var writer: AVAudioFile?
    var decoded: DecodedAudio?
    var length: Int64=0
    var format: AVAudioFormat!
    var sourceBits=0
    var sourceFloat=false
    var codec="PCM"
    var gaplessNote: String?
    init(_ url: URL) throws {
        if url.pathExtension.lowercased()=="mp3" {
            guard let m=qc_mp3_open(url.path) else{throw QCFailure(message:"MP3 kon niet betrouwbaar worden geopend: leeg, ongeldig of niet ondersteund.")}
            mp3=m;length=qc_mp3_frames(m);codec="MP3 / minimp3 float"
            format=AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:Double(qc_mp3_rate(m)),channels:AVAudioChannelCount(qc_mp3_channels(m)),interleaved:true)
            gaplessNote=qc_mp3_has_gapless(m) != 0 ? "MP3: encoder-delay door minimp3 verwerkt; geen ReplayGain toegepast." : "MP3: geen bruikbare gapless-delay herkend; encoder-padding kan duur en venstergrenzen beïnvloeden. Geen ReplayGain toegepast."
        }else if url.pathExtension.lowercased()=="flac" {
            guard let f=qc_flac_open(url.path) else {throw QCFailure(message:"FLAC kon niet worden geopend: gebruik mono/stereo native FLAC tot 24 bit met bekend frameaantal.")}
            flac=f;length=qc_flac_frames(f);sourceBits=Int(qc_flac_bits(f));codec="FLAC / dr_flac"
            format=AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:Double(qc_flac_rate(f)),channels:AVAudioChannelCount(qc_flac_channels(f)),interleaved:true)
        }else{
            let f=try AVAudioFile(forReading:url,commonFormat:.pcmFormatFloat32,interleaved:true)
            native=f;format=f.processingFormat;length=f.length
            let asbd=f.fileFormat.streamDescription.pointee
            guard [kAudioFormatLinearPCM,kAudioFormatFLAC].contains(asbd.mFormatID) else{throw QCFailure(message:"Ondersteund: PCM WAV/AIFF, FLAC en MP3.")}
            sourceBits=Int(asbd.mBitsPerChannel)
            sourceFloat=asbd.mFormatID==kAudioFormatLinearPCM && asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
            if asbd.mFormatID==kAudioFormatFLAC {
                codec="FLAC"
                let h=try FileHandle(forReadingFrom:url);defer{try? h.close()}
                let b=[UInt8](try h.read(upToCount:42) ?? Data())
                if b.count>=42 && Array(b[0..<4])==Array("fLaC".utf8) && b[4]&127==0 {
                    let packed=b[18..<26].reduce(UInt64(0)){($0<<8)|UInt64($1)};sourceBits=Int((packed>>36)&31)+1
                }
            }
        }
    }
    deinit {if let mp3 {qc_mp3_close(mp3)};if let flac {qc_flac_close(flac)}}
    func preparePreview() throws {
        guard mp3 != nil || flac != nil else{return}
        let cache=try DecodedAudio();decoded=cache
        writer=try AVAudioFile(forWriting:cache.url,settings:format.settings,commonFormat:.pcmFormatFloat32,interleaved:true)
    }
    func read(into b:AVAudioPCMBuffer, frameCount:AVAudioFrameCount) throws {
        if let mp3 {
            let n=qc_mp3_read(mp3,b.floatChannelData![0],Int32(frameCount))
            guard n>=0 else{throw QCFailure(message:"MP3 decodefout of veranderend streamformaat. Analyse afgebroken.")}
            b.frameLength=AVAudioFrameCount(n)
            if n>0 {try writer?.write(from:b)}
        }else if let flac {
            let n=qc_flac_read(flac,b.floatChannelData![0],Int32(frameCount))
            guard n>=0 else{throw QCFailure(message:"FLAC-decodefout.")}
            b.frameLength=AVAudioFrameCount(n)
            if n>0 {try writer?.write(from:b)}
        }else{try native!.read(into:b,frameCount:frameCount)}
    }
    func seek(_ frame:Int64) throws {
        if let mp3 {guard qc_mp3_seek(mp3,frame)==0 else{throw QCFailure(message:"MP3-passage kon niet worden opgezocht.")}}
        else if let flac {guard qc_flac_seek(flac,frame)==0 else{throw QCFailure(message:"FLAC-passage kon niet worden opgezocht.")}}
        else {native!.framePosition=frame}
    }
    func finish(atEnd:Bool=true) throws {
        if atEnd, let mp3 {
            var tail=[Float](repeating:0,count:2)
            guard qc_mp3_read(mp3,&tail,1)==0 else{throw QCFailure(message:"MP3-frametelling wijkt af; geen volledig rapport beschikbaar.")}
        }
        if atEnd, let flac {
            var tail=[Float](repeating:0,count:2)
            guard qc_flac_read(flac,&tail,1)==0 else{throw QCFailure(message:"FLAC-frametelling wijkt af.")}
        }
        writer=nil
    }
}
