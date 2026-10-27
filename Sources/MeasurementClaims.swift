import Foundation

// One source for the import-only method sheet and exported measurement claims.
// A passed test suite is evidence about a configuration, not certification of a file.
enum MeasurementClaims {
    static let suite="EBU v05-minimumset: op 24 oktober 2026 slaagden 68 numerieke checks en 2 tijdverloopchecks voor mono/stereo op 48 kHz. Geen certificering of foutgarantie voor alle signalen en samplerates."
    static let testedMeterSources=[
        "Sources/Measure.c":"00181202dabc35a789bc826b19f1a42b772bc3f1894131cf5a2c4f0347866a2d",
        "Vendor/ebur128.c":"c2fc562f1088cacab4d21250b6e04996ef36c7694ea901e08cc4d64eb542b78d"]
    static let peak="True peak: libebur128-interpolatie, 4× onder 96 kHz en 2× onder 192 kHz. Vanaf 192 kHz meten we alleen sample peak; dat is geen true-peakmeting."
    static let lra="LRA gebruikt volledige 3-s-vensters op 10 Hz, zonder eindpadding. De zes officiële LRA-minimumtests slaagden; korte bestanden en het randbeleid zijn niet volledig normgevalideerd. LRA beschrijft passageverschillen, geen clipping of compressie-instelling."
    static let loudness="LUFS beschrijft luidheid, geen kwaliteit. PLR is geïnterpoleerde true peak minus integrated loudness; zonder interpolatie heet dit samplepiek minus LUFS. Er is geen verplicht release- of premaster-LUFS-doel. De zeldzame oranje niveauhint is een vrijblijvende combinatie van niveau, piekruimte en dynamiek."
    static let tone="De toonbalans toont verschil met de genre-mediaan (0 dB) en de P10–P90-spreiding. Bandenergie is relatief aan 20 Hz–10 kHz. Een kleine pilotbibliotheek is geen kwaliteitsnorm of voorgeschreven EQ-curve. Air blijft beschrijvend vanwege codecverschillen."
    static let dynamics="Dichtheid: mediaan van negatieve sample-crest over 1 s. Punch: snelle envelopaanzet tegenover circa 100 ms ervoor. Beweging: spreiding van 1-s-energieniveaus, inclusief arrangement. Stilte en zeer zachte delen tellen niet mee; minimaal 8 actieve seconden. Deze maten bewijzen geen overcompressie of masking."
    static let preview="EQ-preview verandert alleen de beluistering: maximaal ±3 dB per band, Air blijft gelijk. De actieve muziek van de hele track vormt de basis, met luidere passages als terugval. Een gekozen passage of grafiekschaal verandert de metingen en preview niet."
    static let stereo="Correlatie, mono-energie en kanaalbalans zijn luisterhints, geen stereokwaliteitscijfer. Mono-energie is 10 log₁₀[2E((L+R)/2)/(E(L)+E(R))]. Kanaalbalans is RMS links minus rechts. Crest is samplepiek minus ongewogen RMS, zonder AES17-offset; een sinus meet 3,01 dB. Een hoge crest kan door pauzes of losse pieken ontstaan."
    static let integrity="Samples buiten ±1 worden geteld; dat bewijst op zichzelf geen hoorbare schade. Plateaus, kliks, discontinuïteiten en stiltes zijn heuristische luisterkandidaten. Geen garantie dat elke exportfout of instrumentuitval wordt gevonden. MP3-pieken horen bij het gedecodeerde bestand, niet noodzakelijk bij de bron vóór encoding."
    static let reports="HTML, JSON en CSV beschrijven de bevroren analyse en gekozen genre/doel. De bron wordt bij export niet opnieuw gemeten. Geen audio of volledige bronpaden worden ingesloten. CSV is een generiek markerformaat; Logic-import is niet gevalideerd. Klik/stilte, overrange en plateaus hebben elk een begrensde detaillijst; de waveform behoudt de volledige tel-tijdlijn."
    static let spectrum="Spectrum: gemiddelde energie van volledige Blackman-Harris-vensters van minimaal 2 seconden. De laatste onvolledige hop is uitgesloten. Genreanalyse gebruikt afzonderlijke 2-s-kenmerken; laagenergie is geen mud-classifier."
    static var standardLimitations:[String]{[suite,peak,lra,spectrum,integrity]}
    static let manifest:[String:Any]? = {
        guard let url=Bundle.main.url(forResource:"BuildManifest",withExtension:"json"),let data=try? Data(contentsOf:url) else{return nil}
        return (try? JSONSerialization.jsonObject(with:data)) as? [String:Any]
    }()
    static func meterSourcesMatch(_ inputs:[String:String]?)->Bool? {
        guard let inputs else{return nil}
        return testedMeterSources.allSatisfy{inputs[$0.key]==$0.value}
    }
    static var meterSourcesMatch:Bool?{meterSourcesMatch(manifest?["inputSHA256"] as? [String:String])}
}

struct MeasurementClaim:Codable {
    var id:String;var name:String;var value:Double?;var unit:String;var status:String
    var method:String;var validation:String
}
extension Analysis {
    var truePeakInterpolationFactor:Int{sampleRate<96000 ? 4:(sampleRate<192000 ? 2:1)}
    var peakIsInterpolated:Bool{truePeakInterpolationFactor>1}
    var reportedPeak:Double?{peakIsInterpolated ? truePeakEstimate:samplePeak}
    var reportedPeakGap:Double?{reportedPeak.flatMap{p in integrated.map{p-$0}}}
    var measurementStatuses:[String:String] {
        ["integrated":integrated==nil ? "insufficient_or_below_gate":"measured",
         "momentaryMax":momentaryMax==nil ? "insufficient_or_below_gate":"measured",
         "shortTermMax":shortTermMax==nil ? "insufficient_or_below_gate":"measured",
         "lra":lra==nil ? "insufficient_or_below_gate":(duration<60 ? "measured_short_program":"measured_unpadded_windows"),
         "truePeakEstimate":!peakIsInterpolated ? "not_measured_no_interpolation":(truePeakEstimate==nil ? "unavailable":"interpolated_estimate"),
         "samplePeak":samplePeak==nil ? "unavailable":"measured",
         "plr":!peakIsInterpolated ? "not_available_without_true_peak":(reportedPeakGap==nil ? "unavailable":"measured"),
         "monoLoss":completeMonoCancellation ? "complete_cancellation":(monoLoss==nil ? "mono_or_insufficient_energy":"measured")]
    }
    var meterValidationNote:String {
        guard MeasurementClaims.meterSourcesMatch==true else{return "Historische 48-kHz-tests; overeenkomst van de meetbronnen van deze build is niet bevestigd."}
        return sampleRate==48000 && (1...2).contains(channels)
            ? "Meetbronnen en samplerate/kanaalindeling komen overeen met de geteste 48-kHz-minimumset. Geen certificering van dit bestand."
            : "Meetbronnen komen overeen met de geteste implementatie; dit formaat valt buiten de officiële 48-kHz-minimumset."
    }
    var measurementClaims:[MeasurementClaim] {
        let s=measurementStatuses
        return [
            MeasurementClaim(id:"integrated",name:"Integrated loudness",value:integrated,unit:"LUFS",status:s["integrated"]!,method:"K-gewogen, gated geïntegreerde luidheid",validation:meterValidationNote),
            MeasurementClaim(id:"momentaryMax",name:"Momentary max",value:momentaryMax,unit:"LUFS",status:s["momentaryMax"]!,method:"Maximum van momentary loudness (400 ms)",validation:meterValidationNote),
            MeasurementClaim(id:"shortTermMax",name:"Short-term max",value:shortTermMax,unit:"LUFS",status:s["shortTermMax"]!,method:"Maximum van short-term loudness (3 s)",validation:meterValidationNote),
            MeasurementClaim(id:"lra",name:"Loudness range",value:lra,unit:"LU",status:s["lra"]!,method:MeasurementClaims.lra,validation:meterValidationNote),
            MeasurementClaim(id:"peak",name:peakIsInterpolated ? "True peak":"Sample peak",value:reportedPeak,unit:peakIsInterpolated ? "dBTP":"dBFS",status:peakIsInterpolated ? s["truePeakEstimate"]!:s["samplePeak"]!,method:peakIsInterpolated ? "\(truePeakInterpolationFactor)× interpolatie":"Sample peak; geen interpolatie",validation:peakIsInterpolated ? meterValidationNote:"Geen true-peakclaim bij deze samplerate."),
            MeasurementClaim(id:"peakToLoudness",name:peakIsInterpolated ? "PLR":"Samplepiek − LUFS",value:reportedPeakGap,unit:"dB",status:reportedPeakGap==nil ? "unavailable":"measured",method:peakIsInterpolated ? "True peak minus integrated loudness":"Sample peak minus integrated loudness; geen PLR op true-peakbasis",validation:"Afgeleid van bovenstaande metingen; geen kwaliteitscijfer.")]
    }
    var validationEvidence:[String:Any] {
        ["suite":"EBU v05 minimum","testedAt":"2026-10-24","sampleRate":48000,"channels":[1,2],
         "numericalChecks":68,"timeSeriesChecks":2,"certified":false,"allSampleRatesValidated":false,
         "currentRateAndChannelsWithinSuite":sampleRate==48000 && (1...2).contains(channels),
         "meterSourcesMatch":MeasurementClaims.meterSourcesMatch as Any? ?? NSNull(),
         "testedMeterSources":MeasurementClaims.testedMeterSources,
         "scope":MeasurementClaims.suite,"lraBoundaryPolicy":MeasurementClaims.lra,
         "sources":["https://tech.ebu.ch/docs/tech/tech3341.pdf","https://tech.ebu.ch/docs/tech/tech3342.pdf"]]
    }
}
