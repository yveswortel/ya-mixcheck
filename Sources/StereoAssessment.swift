import Foundation

enum MeterSafety:String,Codable {case green,orange,red,unavailable}
struct MeterVerdict:Codable {
    var level:MeterSafety;var label:String;var explanation:String
}
// Display policy, not a perceptual standard. Derived mono ratio thresholds are exact.
let stereoHalfEnergyDB = 10*log10(0.5)
let stereoQuarterEnergyDB = 10*log10(0.25)
func monoVerdict(_ value:Double?,complete:Bool=false,channels:Int=2,seconds:Double=10)->MeterVerdict {
    guard channels==2,seconds>=1 else{return MeterVerdict(level:.unavailable,label:"Niet beoordeeld",explanation:"Mono-compatibiliteit vraagt stereo en minstens één seconde audio.")}
    if complete{return MeterVerdict(level:.red,label:"Volledige uitdoving",explanation:"L+R valt volledig weg. Controleer de polariteit en stereoverwerking vóór export.")}
    guard let v=value,v.isFinite else{return MeterVerdict(level:.unavailable,label:"Geen meetwaarde",explanation:"Onvoldoende signaalenergie voor deze meting.")}
    if v<=stereoQuarterEnergyDB+1e-6{return MeterVerdict(level:.red,label:"Sterke uitdoving",explanation:"Hoogstens 25% van de genormaliseerde stereo-energie blijft over in mono. Controleer of essentiële partijen verdwijnen; een bewust side-effect is geen bewezen mixfout.")}
    if v<stereoHalfEnergyDB-1e-6{return MeterVerdict(level:.orange,label:"Controleer in mono",explanation:"Minder mono-energie dan bij ongecorreleerd stereo. Dit kan een breedtekeuze zijn; luister naar fundament en hoofdpartijen.")}
    return MeterVerdict(level:.green,label:"Geen sterke uitdoving",explanation:"0 dB bij identieke kanalen; circa −3,01 dB bij ongecorreleerd stereo of één actief kanaal. Geen garantie voor elke frequentie of passage.")
}
func correlationVerdict(_ value:Double?,mono:Double?,complete:Bool=false,channels:Int=2,seconds:Double=10)->MeterVerdict {
    guard channels==2,seconds>=1 else{return MeterVerdict(level:.unavailable,label:"Niet beoordeeld",explanation:"Correlatie vraagt twee actieve kanalen en minstens één seconde audio.")}
    guard let v=value,v.isFinite else{return MeterVerdict(level:.unavailable,label:"Geen meetwaarde",explanation:"Correlatie is niet gedefinieerd bij stilte of een stil kanaal; dit is niet hetzelfde als nul correlatie.")}
    if v<=(-0.5)+1e-6 && (complete || (mono ?? 0)<=stereoQuarterEnergyDB+1e-6){return MeterVerdict(level:.red,label:"Sterk tegengecorreleerd",explanation:"Correlatie ≤ −0,5 én sterke mono-uitdoving. Controleer polariteit en stereo-wideners. Een effect kan bedoeld zijn; de meetwaarde bewijst geen artistieke fout.")}
    if v < -1e-6{return MeterVerdict(level:.orange,label:"Negatieve correlatie",explanation:"L en R werken gemiddeld tegen elkaar in. Dit kan breedte geven, maar luister wat in mono verloren gaat. Bij ongelijke kanaalniveaus is correlatie alleen onvoldoende voor rood.")}
    return MeterVerdict(level:.green,label:"Niet tegengecorreleerd",explanation:"0 tot +1 is een normaal uitgangspunt. +1 betekent sterk gelijkend, niet automatisch een beter stereobeeld. Lokale of frequentiegebonden problemen kunnen verborgen blijven.")
}
func crestVerdict(_ value:Double?,seconds:Double=10)->MeterVerdict {
    guard seconds>=1,let v=value,v.isFinite else{return MeterVerdict(level:.unavailable,label:"Geen beoordeling",explanation:"Onvoldoende audio of kanaalenergie.")}
    if v<6{return MeterVerdict(level:.orange,label:"Dicht signaal · luister",explanation:"Weinig verschil tussen samplepiek en ruwe RMS. Dit kan bij een luide master of aangehouden klank passen. Controleer punch en vervorming; geen bewijs van clipping of slecht stereo.")}
    return MeterVerdict(level:.green,label:"Geen lage crest",explanation:"Minstens 6 dB samplepiek boven ruwe RMS. Dit is geen streefwaarde of dynamiekgoedkeuring: hoge crest kan ook door losse pieken, pauzes of arrangement komen.")
}
// Conservative triage, not a genre target. Raw RMS over the complete selection.
func channelBalanceVerdict(_ rms:[Double?],channels:Int=2,seconds:Double=10)->MeterVerdict {
    guard channels==2,seconds>=1,rms.count==2 else{return MeterVerdict(level:.unavailable,label:"Niet beoordeeld",explanation:"Kanaalbalans vraagt stereo en minstens één seconde audio.")}
    let l=rms[0],r=rms[1]
    guard l?.isFinite != false,r?.isFinite != false else{return MeterVerdict(level:.unavailable,label:"Geen meetwaarde",explanation:"Ongeldige kanaalenergie.")}
    guard max(l ?? -999,r ?? -999) > -60 else{return MeterVerdict(level:.unavailable,label:"Te weinig signaal",explanation:"Beide kanalen zijn stil of zeer zacht; geen balanswaarschuwing.")}
    guard let left=l,let right=r else{return MeterVerdict(level:.red,label:l == nil ? "Linkerkanaal stil":"Rechterkanaal stil",explanation:"Eén kanaal bevat geen meetbare energie terwijl het andere actief is. Controleer routing of bewuste eenzijdige plaatsing.")}
    let difference=left-right,amount=abs(difference),side=difference>0 ? "links":"rechts"
    let explanation="Gemiddeld is \(side) \(display(amount)) dB sterker. Dit is een niveauverschil, geen correlatie- of fasefout. Bewuste panning kan dit verklaren."
    if amount>=30{return MeterVerdict(level:.red,label:"Zeer sterke kanaalonbalans",explanation:explanation)}
    if amount>=6{return MeterVerdict(level:.orange,label:"Controleer kanaalbalans",explanation:explanation)}
    return MeterVerdict(level:.green,label:"Geen grote kanaalonbalans",explanation:"Minder dan 6 dB gemiddeld RMS-verschil. Geen garantie voor elke passage; links en rechts hoeven niet exact gelijk te zijn.")
}
extension Analysis {
    var channelBalanceDB:Double? {guard channels==2,rms.count==2,let l=rms[0],let r=rms[1],l.isFinite,r.isFinite else{return nil};return l-r}
    var channelBalanceAssessment:MeterVerdict {channelBalanceVerdict(rms,channels:channels,seconds:duration)}
    var stereoAssessment:[String:MeterVerdict]{
        var result=["correlation":correlationVerdict(correlation,mono:monoLoss,complete:completeMonoCancellation,channels:channels,seconds:duration),"monoEnergy":monoVerdict(monoLoss,complete:completeMonoCancellation,channels:channels,seconds:duration)]
        result["channelBalance"]=channelBalanceAssessment
        for (i,value) in crest.enumerated(){result[i==0 ? "crestL":"crestR"]=crestVerdict(value,seconds:duration)}
        return result
    }
}
