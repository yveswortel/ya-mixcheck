import Foundation

struct ClippingEvidence: Codable, Sendable {
    var railSamples:Int64?; var totalSamples:Int64
    var flatSamples:Int64; var lowLevelFlatSamples:Int64 = 0; var flatRuns:Int64; var longestFlatFrames:Int64
    var events:[Incident]
    var plateauTimeline:[Int64]
    var railTimeline:[Int64]
    var overrangeTimeline:[Int64]
    var timelineMethod:String = "2048 equal time bins spanning the entire decoded file; complete channel-sample counts, independent of detailed-event storage cap. Frame maps to floor(frame*2048/totalFrames). Plateau confirmation includes its first two samples retroactively."

    var railPercent:Double? {railSamples.map{100*Double($0)/Double(max(1,totalSamples))}}
    var method:String = "Exact plateaus ≥3 samples at |x|≥0.8 plus lower local extrema at |x|≥0.0001 with both edge steps > max(2 PCM LSB, |x|*1e-6, 1e-9); lower runs ending at EOF lack a confirmed exit and are excluded; PCM rails only for known 8–24-bit integer sources. Evidence, not an audible-damage verdict. First 512 detailed plateau intervals; full-track timeline and counts remain complete. Action card requires rail occupancy ≥0.1% OR longest plateau ≥0.5 ms AND flat occupancy ≥0.01%; isolated quantization plateaus remain raw data. Strong-evidence wording uses rail occupancy ≥10% and longest plateau ≥3 ms; heuristic, not a validated severity classifier."
}
struct Opinion: Codable,Identifiable {
    var id:String; var category:String; var title:String; var evidence:String; var action:String
    var startFrame:Int64? = nil
}
extension Analysis {
    var lowShare:Double? {
        guard lowBandDBFS.count==5,let sub=lowBandDBFS[0] else{return nil}
        let total=pow(10,sub/10)+spectrum.enumerated().reduce(0.0){sum,item in
            let (i,p)=item; let lo=20*pow(1000,Double(i)/Double(QC_BANDS)),hi=20*pow(1000,Double(i+1)/Double(QC_BANDS))
            return sum+(p.db.map{pow(10,$0/10)*(hi-lo)} ?? 0)
        }
        guard total>1e-16 else{return nil}
        return 100*(1...2).reduce(0.0){$0+(lowBandDBFS[$1].map{pow(10,$0/10)} ?? 0)}/total
    }
    func secondOpinion(purpose:String) -> [Opinion] {
        var items=anomalyOpinions
        if overrangeSamples>0 {
            items.append(Opinion(id:"overrange",category:"Technisch aandachtspunt",title:codec.hasPrefix("MP3") ? "Pieken na MP3-decoding":"Samples buiten nominale headroom",evidence:"\(overrangeSamples) kanaalsamples buiten ±1; hoogste sample \(display(samplePeak,2)) dBFS.",action:codec.hasPrefix("MP3") ? "Dit kan bij encoding of eerdere conversies ontstaan; de oorzaak is niet bewezen. Vergelijk met dezelfde lossless master. De preview houdt headroom vrij. Bij een nieuwe export: maak extra peak-headroom en controleer de opnieuw geëncodeerde versie." : "Controleer de limiter/output en de export. Verlaag zo nodig het eindniveau vóór omzetting naar integer PCM. Alleen gain verlagen herstelt al afgeplatte pieken niet.",startFrame:incidents.first?.startFrame))
        }
        let balance=channelBalanceAssessment
        if balance.level == .orange || balance.level == .red {
            items.append(Opinion(id:"channel-balance",category:balance.level == .red ? "Technisch aandachtspunt":"Luistercontrole",title:balance.label,evidence:balance.explanation,action:"Controleer panning, stereo-export en kanaalrouting. Een bewust eenzijdige opname is niet automatisch fout; vergelijk met de bedoelde mix."))
        }
        let ms=1000*Double(clipping.longestFlatFrames)/sampleRate
        let flatPercent=100*Double(clipping.flatSamples)/Double(max(1,clipping.totalSamples))
        // Suppress isolated quantization plateaus, retaining raw evidence and all timeline counts.
        // These attention thresholds are heuristics, not audibility or quality boundaries.
        let actionablePlateaus=(clipping.railPercent ?? 0)>=0.1 || (ms>=0.5 && flatPercent>=0.01)
        if actionablePlateaus {
            let dense=(clipping.railPercent ?? 0)>=10 && ms>=3
            let rail=clipping.railPercent.map{"\(display($0,2))% van de kanaalsamples raakt de PCM-grens. "} ?? "PCM-railtest niet beschikbaar voor dit bronformaat. "
            items.append(Opinion(id:"ceiling",category:"Luistercontrole",title:dense ? "Sterke aanwijzingen voor hard begrenzen":"Begrenzing onderzoeken",evidence:rail+"\(clipping.flatRuns) vlakke reeksen; langste \(display(ms,2)) ms.",action:dense ? "Beluister piektoppen op rasp, korreligheid en verlies van punch. Vergelijk level-matched met een versie vóór de clipper/limiter; verminder de drive alleen als deze textuur onbedoeld is." : "Vlakke pieken kunnen bewuste clipping, limiting of synthvormen zijn. Luister eerst op de markering. Deze aanwijzing is geen afkeur van de master.",startFrame:clipping.events.first?.startFrame))
        }
        if let tp=truePeakEstimate,tp>1,sampleRate<192000,overrangeSamples==0 {
            items.append(Opinion(id:"truepeak",category:"Technisch aandachtspunt",title:"Beperkte ruimte voor reconstructie",evidence:"True-peak-schatting \(display(tp,2)) dBTP. Dit is een andere meting dan sampleclipping.",action:"Controleer de uiteindelijke export en eventuele lossy encoding met een gevalideerde true-peak-meter. Geef indien nodig extra uitgangsheadroom; beoordeel luidheid niet op één universeel LUFS-doel."))
        }
        if completeMonoCancellation || (monoLoss ?? 0)<(-6) {
            items.append(Opinion(id:"mono",category:"Luistercontrole",title:"Controleer de monosom",evidence:completeMonoCancellation ? "Volledige L+R-uitdoving.":"Globale mono-energieverandering: \(display(monoLoss)) dB.",action:"Vergelijk stereo en mono op gelijk luisterniveau. Controleer polariteit, stereo-wideners en essentiële partijen. De globale meting lokaliseert geen afzonderlijk instrument."))
        }
        if let loud=integrated {
            let premaster=purpose=="Mix voor mastering"
            items.append(Opinion(id:"loudness",category:"Context, geen fout",title:premaster ? "Ruimte voor mastering":"Luidheid en punch",evidence:"\(display(loud)) LUFS-I; PLR \(display(plr)) dB; LRA \(display(lra)) LU. LRA beschrijft passageverschillen, niet clipping.",action:premaster ? "Stem limitergebruik en headroom af met de mastering engineer. Bewaar een versie zonder eindlimiting als vergelijkingspunt; er is geen vaste verplichte premaster-LUFS." : "Vergelijk met een passende referentie op gelijk waargenomen niveau. Let op kick/snare-attack, sustain en passagecontrast. Een luide professionele master wordt hier niet automatisch als fout aangemerkt."))
        }
        if let share=lowShare {
            items.append(Opinion(id:"low",category:"Context, geen fout",title:"Laag in context beluisteren",evidence:"\(display(share))% van de gemeten lineaire energie (0–20 kHz) ligt in 20–120 Hz. Dit is geen perceptuele balansscore.",action:"Vergelijk kick en bas met een stilistisch passende referentie, op gelijk niveau. Luister of noten leesbaar blijven en het laag andere partijen verdringt. Pas geen high-pass of mud-cut toe uitsluitend vanwege dit percentage of energie onder 20 Hz."))
        }
        if integrated==nil {items.append(Opinion(id:"insufficient",category:"Meetbeperking",title:"Onvoldoende loudnessinformatie",evidence:"Het bestand is te kort, stil of onder de meetpoort.",action:"Gebruik een representatieve passage voordat je dynamiek of toonbalans beoordeelt."))}
        return items
    }
}
