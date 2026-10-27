import Foundation
import AVFoundation
import CryptoKit

struct QCFailure: LocalizedError { let message: String; var errorDescription: String? { message } }
final class Cancellation: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    func check() throws { lock.lock(); let stopped = value; lock.unlock(); if stopped { throw QCFailure(message: "Analyse geannuleerd.") } }
}
func finite(_ x: Double) -> Double? { x.isFinite ? x : nil }
func display(_ x: Double?, _ digits: Int = 1) -> String { x.map { String(format: "%.*f", digits, abs($0) < pow(10, -Double(digits))/2 ? 0 : $0) } ?? "—" }
func sha256(_ url: URL, cancellation: Cancellation = Cancellation()) throws -> String {
    let h = try FileHandle(forReadingFrom: url); defer { try? h.close() }
    var hash = SHA256()
    // FileHandle bridges autoreleased NSData. Drain every chunk so hashing a
    // long file never retains its entire byte stream until the worker finishes.
    while try autoreleasepool(invoking: { () throws -> Bool in
        try cancellation.check()
        let d = try h.read(upToCount: 1 << 20) ?? Data()
        guard !d.isEmpty else { return false }
        hash.update(data: d)
        return true
    }) {}
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}
struct Incident: Codable, Identifiable, Sendable {
    var id: Int; var startFrame: Int64; var endFrame: Int64; var channel: Int
}
struct SpectrumPoint: Codable, Sendable { var hz: Double; var db: Double? }
struct Analysis: Encodable, Sendable {
    var schema = 13; var appVersion = "1.0.0"; var engine = "YA-MixCheck reference-identity-20261020 / libebur128 1.2.6"
    var source: String; var sha256: String; var modifiedAt: Date; var byteCount: Int64; var sampleRate: Double; var channels: Int; var frames: Int64
    var bitDepth: Int; var floatingPoint: Bool; var duration: Double { Double(frames) / sampleRate }
    var integrated: Double?; var momentaryMax: Double?; var shortTermMax: Double?; var lra: Double?
    var truePeakEstimate: Double?; var samplePeak: Double?; var plr: Double?
    var rms: [Double?]; var crest: [Double?]; var correlation: Double?; var monoLoss: Double?
    var completeMonoCancellation: Bool; var dc: [Double?]
    var overrangeSamples: Int64; var incidents: [Incident]; var waveform: [Float]
    var spectrum: [SpectrumPoint]; var lowBandDBFS: [Double?]
    var limitations: [String]; var elapsedSeconds: Double
    var clipping: ClippingEvidence
    var codec: String
    var windowStartFrame:Int64 = 0
    var sourceFrames:Int64 = 0
    var toneSlices:[ToneSlice] = []
    var dynamics:[DynamicsSlice] = []
    var subSlices:[SubSlice] = []
    var anomalies:[AudioAnomaly] = []
    var anomalyCount:Int = 0
    var inputSnapshot:PreparedInput? = nil
    var originalSource:String? = nil
    var referenceIdentity:ReferenceIdentity? = nil
    var assessmentHash:String {referenceIdentity?.hash ?? sha256}
    var decodedAudio: DecodedAudio? = nil
    var playbackURL: URL { decodedAudio?.url ?? url }
    var url: URL { URL(fileURLWithPath: source) }
    func sourceIsUnchanged() -> Bool {
        if let snapshot=inputSnapshot{return snapshot.snapshotIsIntact() && snapshot.originalIsUnchanged()}
        guard let attrs=try? FileManager.default.attributesOfItem(atPath:source) else { return false }
        return (attrs[.modificationDate] as? Date)==modifiedAt && (attrs[.size] as? NSNumber)?.int64Value==byteCount
    }
    var previewGainDB: Double { -max(0, (truePeakEstimate ?? samplePeak ?? -120) + 1) }
    func json(purpose:String="Release/master",genre:String="Anders/onbekend",manualBounds:[Double]?=nil) throws -> Data {
        let e=JSONEncoder();e.dateEncodingStrategy = .iso8601
        var object=try JSONSerialization.jsonObject(with:e.encode(self)) as! [String:Any]
        let optionalKeys=["integrated","momentaryMax","shortTermMax","lra","truePeakEstimate","samplePeak","plr","correlation","monoLoss"]
        for key in optionalKeys where object[key]==nil { object[key]=NSNull() }
        object["referenceLibraries"]=["toneVersion":ToneLibrary.shared.version,"dynamicsVersion":DynamicsLibrary.shared.version,"toneIssue":ToneLibrary.shared.loadIssue ?? "","dynamicsIssue":DynamicsLibrary.shared.loadIssue ?? ""]
        object["spectrumMethod"]="v2: >=2s power-of-two Blackman-Harris window, 75% overlap; fractional-bin energy; finite resolution near boundaries. Shorter audio has no spectrum."
        object["adviceContext"]=["purpose":purpose,"genre":genre,"policy":"Genre uses pilot reference distributions; not a quality score or universal target."]
        object["channelBalanceDB"]=channelBalanceDB.map { $0 as Any } ?? NSNull()
        object["channelBalanceConvention"]="RMS L minus RMS R in dB; positive = left stronger. Missing/silent channel represented in channelBalance verdict, not infinity in JSON."
        object["truePeakInterpolationFactor"]=truePeakInterpolationFactor
        // Schema 13: never export a sample-only value under a true-peak/PLR key.
        object["truePeakEstimate"]=peakIsInterpolated ? (truePeakEstimate as Any? ?? NSNull()):NSNull()
        object["plr"]=peakIsInterpolated ? (reportedPeakGap as Any? ?? NSNull()):NSNull()
        object["samplePeakToLoudness"]=samplePeak.flatMap{p in integrated.map{p-$0}} as Any? ?? NSNull()
        object["measurementClaims"]=try JSONSerialization.jsonObject(with:e.encode(measurementClaims))
        object["validationEvidence"]=validationEvidence
        object["stereoAssessment"]=try JSONSerialization.jsonObject(with:e.encode(stereoAssessment))
        object["secondOpinion"]=try JSONSerialization.jsonObject(with:e.encode(secondOpinion(purpose:purpose)))
        let context=RecommendationAnalysis(self,genre:genre)
        object["loudnessAssessment"]=try JSONSerialization.jsonObject(with:e.encode(loudnessReview(purpose:purpose,dynamics:context.dynamics)))
        object["tonalAssessment"]=try JSONSerialization.jsonObject(with:e.encode(context.tone))
        object["louderPassageAssessment"]=try JSONSerialization.jsonObject(with:e.encode(assessTone(toneSlices,genre:genre,hash:assessmentHash,loud:true)))
        let sections=manualBounds == nil ? context.sections:arrangement(toneSlices,duration:duration,manual:manualBounds)
        let passageContext=manualBounds == nil ? context:RecommendationAnalysis(self,genre:genre,sections:sections)
        object["arrangement"]=try JSONSerialization.jsonObject(with:e.encode(sections))
        object["trackDynamics"]=try JSONSerialization.jsonObject(with:e.encode(context.dynamics))
        object["passageDynamics"]=try JSONSerialization.jsonObject(with:e.encode(passageContext.passages))
        object["mixRecommendations"]=try JSONSerialization.jsonObject(with:e.encode(mixRecommendations(context,purpose:purpose)))
        object["listeningAdvice"]=try JSONSerialization.jsonObject(with:e.encode(listeningAdvice(passageContext,purpose:purpose)))
        object["dynamicsMethod"]="v1: density=median negative 1s sample crest; punch=P90 maximum positive 10ms energy/preceding 100ms EMA per 100ms; movement=P90-P10 one-second energy levels. Active gate max(-70,P90 RMS-20); minimum eight active seconds. Descriptive, not compressor detection or quality scores."
        object["localSubEvents"]=try JSONSerialization.jsonObject(with:e.encode(localSubEvents(subSlices)))
        object["localSubMethod"]="v1: 100ms channel-energy, second-order HP20/LP80 vs HP120. Outlier requires dominance >3dB, >6dB above neighboring P90 ratio, sub >3dB above neighboring P90, rest within 6dB of median. +/-5s neighborhood excludes +/-0.5s. At least 40 active neighbors and 0.2s event. Listening candidates, no defect diagnosis."
        object["arrangementEdited"]=manualBounds != nil
        object["toneBandLayout"]=["assessment":"Sub 20–60, Bass 60–120, Low-mid 120–250, Body 250–500, Mids 500–2000, High 2000–10000, Air 10000–20000 Hz", "rawSlicesAndSummary":"Eight original bins; High is the linear-energy sum of raw bins 5 and 6 before per-track quantiles."]
        object["measurementStatus"]=measurementStatuses
        object["validationScope"]=MeasurementClaims.suite+" "+meterValidationNote
        return try JSONSerialization.data(withJSONObject:object,options:[.prettyPrinted,.sortedKeys])
    }
}
final class Analyzer {
    // All calls are serialized by the application. Vendor initialization uses static tables.
    static func run(_ url: URL, cancellation: Cancellation = Cancellation(), chunkSize: Int = 8192,
                    progress: (Double) -> Void = { _ in }, startSeconds:Double = 0, durationSeconds:Double? = nil, makePreview:Bool = true) throws -> Analysis {
        let start = Date(); try cancellation.check()
        let before = try FileManager.default.attributesOfItem(atPath: url.path)
        let hash = try sha256(url, cancellation: cancellation)
        let file = try AudioInput(url)
        let format = file.format!, rate = format.sampleRate, channels = Int(format.channelCount)
        guard [1,2].contains(channels) else { throw QCFailure(message: "Alleen mono en stereo worden ondersteund; dit bestand heeft \(channels) kanalen.") }
        guard [44100.0,48000,88200,96000,176400,192000].contains(rate) else { throw QCFailure(message: "Deze samplerate wordt nog niet ondersteund: \(Int(rate)) Hz.") }
        guard file.length > 0, Double(file.length)/rate <= 24*3600 else { throw QCFailure(message: "Het bestand is leeg of langer dan 24 uur.") }
        guard startSeconds.isFinite, startSeconds>=0, startSeconds<Double(file.length)/rate,
              durationSeconds == nil || (durationSeconds!.isFinite && durationSeconds!>0 && durationSeconds!<=24*3600) else {throw QCFailure(message:"Ongeldig passagebereik.")}
        let firstFrame=Int64((startSeconds*rate).rounded(.down))
        let measuredFrames=min(file.length-firstFrame,durationSeconds.map{Int64(($0*rate).rounded(.down))} ?? file.length)
        guard measuredFrames>0 else{throw QCFailure(message:"De passage bevat geen samples.")}
        if firstFrame>0 {try file.seek(firstFrame)}
        guard let q = qc_create(Int32(rate), Int32(channels), measuredFrames) else { throw QCFailure(message: "Meetkern kon niet worden gestart.") }; defer { qc_destroy(q) }
        guard let tonal=qct_create(Int32(rate),Int32(channels),measuredFrames) else {throw QCFailure(message:"Toonbalansbuffer niet beschikbaar.")};defer{qct_destroy(tonal)}
        let sourceBits=file.sourceBits, sourceFloat=file.sourceFloat
        let railsAvailable = file.mp3 == nil && !sourceFloat && (8...24).contains(sourceBits)
        if railsAvailable { qc_set_pcm_bits(q,Int32(sourceBits)) }
        if makePreview && firstFrame==0 && measuredFrames==file.length {try file.preparePreview()}
        let capacity = AVAudioFrameCount(max(1, min(chunkSize, 65536)))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw QCFailure(message: "Audiobuffer kon niet worden gemaakt.") }
        let dynamics=DynamicsDetector(rate:rate,channels:channels)
        let sub=SubDetector(rate:rate,channels:channels)
        let discontinuities=DiscontinuityDetector(rate:rate,channels:channels)
        var lastProgress = -1
        var decodedFrames: Int64 = 0
        while decodedFrames < measuredFrames {
            try cancellation.check(); try file.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(capacity),measuredFrames-decodedFrames)))
            guard buffer.frameLength > 0, let samples = buffer.floatChannelData?[0] else { throw QCFailure(message: "Onverwacht einde van de audiostream.") }
            let status = qc_push(q, samples, Int32(buffer.frameLength))
            if status != 0 { throw QCFailure(message: status == 2 ? "Ongeldige samples (NaN/Inf). Analyse en playback zijn geblokkeerd." : "De audiostream kon niet volledig worden gemeten (code \(status)).") }
            guard qct_push(tonal,samples,Int32(buffer.frameLength))==0 else{throw QCFailure(message:"Toonbalansanalyse mislukt.")}
            discontinuities.push(samples,frames:Int(buffer.frameLength))
            dynamics.push(samples,frames:Int(buffer.frameLength))
            sub.push(samples,frames:Int(buffer.frameLength))
            decodedFrames += Int64(buffer.frameLength)
            let pc = Int(decodedFrames * 100 / measuredFrames)
            if pc != lastProgress { progress(Double(pc)/100); lastProgress = pc }
        }
        try file.finish(atEnd:firstFrame+measuredFrames==file.length)
        guard qc_finish(q) == 0 else { throw QCFailure(message: "Frameaantal klopt niet of finalisatie is mislukt.") }
        let after = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (before[.size] as? NSNumber) == (after[.size] as? NSNumber), (before[.modificationDate] as? Date) == (after[.modificationDate] as? Date) else { throw QCFailure(message: "Het bronbestand veranderde tijdens de analyse. Analyseer de nieuwe versie opnieuw.") }
        func metric(_ i: Int32) -> Double? { finite(qc_value(q, i)) }
        var issues = MeasurementClaims.standardLimitations
        if let note=file.gaplessNote {issues.append(note);issues.append("MP3-pieken horen bij de float-decode, niet noodzakelijk bij het signaal vóór encoding. Tijdelijke float-PCM-cache voor identieke playback.")}
        if !railsAvailable {issues.append("PCM-railtest niet beschikbaar voor float, lossy of onbekende/>24-bit bron; plateaucontrole blijft actief.")}
        if measuredFrames < Int64(rate*60) { issues.append("LRA: minder dan 60 seconden materiaal; interpretatie beperkt.") }
        let spec = (0..<Int(QC_BANDS)).map { i -> SpectrumPoint in let p = qc_spectrum(q)![i]; return SpectrumPoint(hz: qc_frequency(Int32(i)), db: p>0 ? 10*log10(p) : nil) }
        let events = (0..<Int(qc_event_count(q))).map { i -> Incident in let e=qc_events(q)![i]; return Incident(id:i,startFrame:e.start,endFrame:e.end,channel:Int(e.channel)) }
        let tp=metric(Int32(QC_TP)), integrated=metric(Int32(QC_I))
        var result=Analysis(source:url.path,sha256:hash,modifiedAt:before[.modificationDate] as? Date ?? Date.distantPast,byteCount:(before[.size] as? NSNumber)?.int64Value ?? 0,sampleRate:rate,channels:channels,frames:measuredFrames,
                        bitDepth:sourceBits,floatingPoint:sourceFloat,
                        integrated:integrated,momentaryMax:metric(Int32(QC_M)),shortTermMax:metric(Int32(QC_S)),lra:metric(Int32(QC_LRA)),
                        truePeakEstimate:tp,samplePeak:metric(Int32(QC_PEAK)),plr:tp.flatMap { t in integrated.map { t-$0 } },
                        rms:(0..<channels).map { metric(Int32(QC_RMS_L)+Int32($0)) },crest:(0..<channels).map { metric(Int32(QC_CREST_L)+Int32($0)) },
                        correlation:metric(Int32(QC_CORR)),monoLoss:metric(Int32(QC_MONO)),completeMonoCancellation:qc_value(q,Int32(QC_MONO)) == -.infinity,
                        dc:(0..<channels).map { metric(Int32(QC_DC_L)+Int32($0)) },overrangeSamples:qc_over_samples(q),incidents:events,
                        waveform:Array(UnsafeBufferPointer(start:qc_wave(q),count:Int(QC_WAVE))),spectrum:spec,
                        lowBandDBFS:(0..<5).map { let p=qc_low_bands(q)![$0]; return p>0 ? 10*log10(p) : nil },limitations:issues,elapsedSeconds:Date().timeIntervalSince(start),
                        clipping:ClippingEvidence(railSamples:railsAvailable ? qc_rail_samples(q):nil,totalSamples:measuredFrames*Int64(channels),flatSamples:qc_flat_samples(q),lowLevelFlatSamples:qc_low_flat_samples(q),flatRuns:qc_flat_runs(q),longestFlatFrames:qc_flat_longest(q),events:(0..<Int(qc_flat_event_count(q))).map { i in let e=qc_flat_events(q)![i];return Incident(id:i,startFrame:e.start,endFrame:e.end,channel:Int(e.channel)) },plateauTimeline:Array(UnsafeBufferPointer(start:qc_timeline(q,0),count:Int(QC_WAVE))),railTimeline:Array(UnsafeBufferPointer(start:qc_timeline(q,1),count:Int(QC_WAVE))),overrangeTimeline:Array(UnsafeBufferPointer(start:qc_timeline(q,2),count:Int(QC_WAVE)))),codec:file.codec,decodedAudio:file.decoded)
        dynamics.emit();result.dynamics=dynamics.slices
        sub.emit();result.subSlices=sub.slices
        result.anomalies=discontinuities.events;result.anomalyCount=discontinuities.count
        result.limitations.append("Klik/stilte-check: heuristische luisterkandidaten, maximaal 512 opgeslagen. Klikken: geïsoleerde impulsen en abrupte stappen met rustig golfvormverloop eromheen; digitale nul-gaten van 1–20 ms met actieve flanken; overige stilte: 10-ms-blokken onder −90 dBFS, 20 ms–10 s, direct geflankeerd door >−45 dBFS. Begin/eindstilte uitgesloten. Geen garantie voor alle exportfouten of instrumentuitval.")
        result.windowStartFrame=firstFrame;result.sourceFrames=file.length;result.toneSlices=extractSlices(tonal)
        if firstFrame==0 && measuredFrames==file.length {result.referenceIdentity=ReferenceIdentities.shared.resolve(hash:hash,duration:result.duration,slices:result.toneSlices)}
        return result
    }
}
