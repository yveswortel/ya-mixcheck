import Foundation
import AVFoundation

// Raw extraction/library retain eight bins. Assessments combine energies into seven bands.
let toneNames=["Sub","Bass","Low-mid","Body","Mids","High","Air"]
let toneRanges=["20–60 Hz","60–120 Hz","120–250 Hz","250–500 Hz","0,5–2 kHz","2–10 kHz","10–20 kHz"]
let toneLabels=zip(toneNames,toneRanges).map{"\($0) · \($1)"}
let toneSourceBands=[[0],[1],[2],[3],[4],[5,6],[7]]
func sevenToneBands(_ raw:[Double?])->[Double?] {
    guard raw.count==8 else{return [Double?](repeating:nil,count:7)}
    return toneSourceBands.map{indices in
        let powers=indices.compactMap{raw[$0]}.filter{$0.isFinite}.map{pow(10,$0/10)}
        return powers.isEmpty ? nil:powerDB(powers.reduce(0,+))
    }
}

func quantile(_ values:[Double],_ p:Double)->Double? {let a=values.filter{$0.isFinite}.sorted();guard !a.isEmpty else{return nil};let x=Double(a.count-1)*p;let i=Int(x);return a[i]+(a[min(i+1,a.count-1)]-a[i])*(x-Double(i))}
func powerDB(_ value:Double)->Double? {value>1e-25 ? 10*log10(value):nil}
struct ToneSlice:Codable, Sendable {
    var start:Double;var duration:Double;var rms:Double?;var bands:[Double?];var lowContrast:Double?;var lowMono:Double?
    var center:Double{start+duration/2}
}
func extractSlices(_ q:OpaquePointer)->[ToneSlice] {
    var result=[ToneSlice]()
    for i in 0..<Int(qct_count(q)) {
        let index=Int32(i)
        let bands:[Double?]=(1...8).map{finite(qct_value(q,index,Int32($0)))}
        let value=ToneSlice(start:Double(i)*2,duration:qct_value(q,index,11),rms:finite(qct_value(q,index,0)),bands:bands,lowContrast:finite(qct_value(q,index,9)),lowMono:finite(qct_value(q,index,10)))
        result.append(value)
    }
    return result
}
struct ToneSummary:Codable {
    var bands:[Double?];var lowRatio:Double?;var lowContrast:Double?;var lowMono:Double?;var seconds:Double;var rms:Double?
}
func usableSlices(_ slices:[ToneSlice],loud:Bool=false,quiet:Bool=false)->[ToneSlice]{
    guard let top=quantile(slices.compactMap{$0.rms},0.9) else{return []}
    var active=slices.filter{$0.duration>=1 && ($0.rms ?? -999)>max(-70,top-20) && $0.bands.compactMap{$0}.count>0}
    if loud,let mid=quantile(active.compactMap{$0.rms},0.5){active=active.filter{($0.rms ?? -999)>=mid}}
    if quiet,let mid=quantile(active.compactMap{$0.rms},0.5){active=active.filter{($0.rms ?? -999)<=mid}}
    return active
}
func summarizeTone(_ input:[ToneSlice],loud:Bool=false,quiet:Bool=false)->ToneSummary {
    let slices=usableSlices(input,loud:loud,quiet:quiet),seconds=slices.reduce(0){$0+$1.duration}
    var energy=[Double](repeating:0,count:8),lowMono=0.0,lowWeight=0.0,rms=0.0
    for s in slices {
        for b in 0..<8 {energy[b]+=(s.bands[b].map{pow(10,$0/10)} ?? 0)*s.duration}
        let low=(0...1).reduce(0.0){$0+(s.bands[$1].map{pow(10,$0/10)} ?? 0)}*s.duration
        if let m=s.lowMono{lowMono+=low*pow(10,m/10);lowWeight+=low}
        rms+=(s.rms.map{pow(10,$0/10)} ?? 0)*s.duration
    }
    let total=energy.prefix(7).reduce(0,+)
    return ToneSummary(bands:energy.map{total>0 ? powerDB($0/total):nil},lowRatio:total>0 ? powerDB((energy[0]+energy[1])/total):nil,lowContrast:quantile(slices.compactMap{$0.lowContrast},0.5),lowMono:lowWeight>0 ? 10*log10(max(1e-12,lowMono/lowWeight)):nil,seconds:seconds,rms:seconds>0 ? powerDB(rms/seconds):nil)
}
struct ArrangementSection:Codable,Identifiable {var id:Int;var start:Double;var end:Double;var label:String;var change:String}
func sectionShape(_ slices:[ToneSlice])->[Double?]{summarizeTone(slices).bands}
func arrangement(_ slices:[ToneSlice],duration:Double,manual:[Double]?=nil)->[ArrangementSection]{
    guard duration>0 else{return []}
    var bounds=[0.0];var causes=[Double:String]()
    if let manual {bounds += manual.filter{$0.isFinite && $0>0 && $0<duration}.sorted()}
    else if slices.count>=8 {
        var candidates=[(Double,Double,String)]()
        for i in 3..<(slices.count-3){
            let left=Array(slices[(i-3)..<i]),right=Array(slices[i..<(i+3)])
            let l=quantile(left.compactMap{$0.rms},0.5) ?? -120,r=quantile(right.compactMap{$0.rms},0.5) ?? -120
            let a=sectionShape(left),b=sectionShape(right)
            let diffs=(0..<7).compactMap{j->Double? in guard let x=a[j],let y=b[j],max(x,y)>(-35) else{return nil};return abs(x-y)}
            let tone=diffs.isEmpty ? 0:diffs.reduce(0,+)/Double(diffs.count),level=abs(r-l)
            if level>=3 || tone>=2.5 {candidates.append((slices[i].start,max(level/3,tone/2.5),level/3>=tone/2.5 ? "Niveauverandering":"Klankverandering"))}
        }
        for (time,_,cause) in candidates.sorted(by:{$0.1>$1.1}) {
            if time>=8,duration-time>=8,!bounds.contains(where:{abs($0-time)<8}) {bounds.append(time);causes[time]=cause}
            if bounds.count>=40{break}
        }
    }
    bounds=Array(Set(bounds)).sorted();bounds.append(duration)
    let global=quantile(usableSlices(slices).compactMap{$0.rms},0.5) ?? -70
    return (0..<(bounds.count-1)).map{i in
        let selected=slices.filter{$0.center>=bounds[i] && $0.center<bounds[i+1]}
        let level=quantile(selected.compactMap{$0.rms},0.5) ?? -120
        let label=level < -65 ? "Stil/zeer zacht":(level<global-3 ? "Rustiger":"Voller")
        return ArrangementSection(id:i,start:bounds[i],end:bounds[i+1],label:label,change:manual != nil ? "Handmatige grens":(causes[bounds[i]] ?? "Begin"))
    }
}
struct ToneReference:Codable {var title:String;var genre:String;var hashes:[String];var active:ToneSummary;var loud:ToneSummary;var quiet:ToneSummary}
struct ToneLibrary:Codable {
    var version:String;var method:String;var references:[ToneReference]
    var loadIssue:String? = nil
    static func load(_ data:Data?)->ToneLibrary {
        guard let data,let l=try? JSONDecoder().decode(Self.self,from:data) else{return Self(version:"unavailable",method:"",references:[],loadIssue:"Toonreferenties ontbreken of zijn beschadigd; genrevergelijking niet beschikbaar.")}
        guard l.version=="0.4.0" else{return Self(version:l.version,method:l.method,references:[],loadIssue:"Niet-ondersteunde toonbibliotheekversie \(l.version); genrevergelijking niet beschikbaar.")}
        guard l.references.allSatisfy({[$0.active,$0.loud,$0.quiet].allSatisfy{$0.bands.count==8}}) else{return Self(version:l.version,method:l.method,references:[],loadIssue:"Toonbibliotheek bevat ongeldige bandgegevens.")}
        return l
    }
    static let shared:ToneLibrary = load(Bundle.main.url(forResource:"ToneReferences",withExtension:"json").flatMap{try? Data(contentsOf:$0)})

}
struct ToneBandVerdict:Codable,Identifiable {
    var id:Int;var name:String;var range:String;var value:Double?;var median:Double?;var lower:Double?;var upper:Double?;var delta:Double?;var status:String;var attention:Bool
}
struct ToneAdvice:Codable,Identifiable {var id:String;var title:String;var evidence:String;var action:String;var start:Double?}
struct ToneAssessment:Codable {
    var genre:String;var mode:String;var referenceCount:Int;var referenceTitles:[String];var summary:ToneSummary;var bands:[ToneBandVerdict];var advice:[ToneAdvice];var conclusion:String;var limitation:String
}
func assessTone(_ slices:[ToneSlice],genre:String,hash:String,loud:Bool=false,quiet:Bool=false,library:ToneLibrary = .shared)->ToneAssessment {
    let summary=summarizeTone(slices,loud:loud,quiet:quiet)
    let refs=library.references.filter{$0.genre==genre && !$0.hashes.contains(hash)}
    let targets=refs.map{loud ? $0.loud:(quiet ? $0.quiet:$0.active)},enough=targets.count>=5 && summary.seconds>=8
    let assessedBands=sevenToneBands(summary.bands),targetBands=targets.map{sevenToneBands($0.bands)}
    var bands=[ToneBandVerdict](),advice=[ToneAdvice]()
    for b in 0..<7 {
        let values=targetBands.compactMap{$0[b]},med=quantile(values,0.5),lo=quantile(values,0.1),hi=quantile(values,0.9)
        let v=assessedBands[b],delta=v.flatMap{x in med.map{x-$0}}
        var status="Onvoldoende referentie",attention=false
        if summary.seconds<8{status="Te weinig actieve audio"}
        else if enough,let x=v,let m=med,let lower=lo,let upper=hi {
            if b==6 {status="Beschrijvend · codecgevoelig"}
            else {
                let lowerBound=min(lower,m-1.5),upperBound=max(upper,m+1.5)
                if x<lowerBound-1.5 {status="Duidelijk minder";attention=true}
                else if x>upperBound+1.5 {status="Duidelijk meer";attention=true}
                else if x<lowerBound {status="Iets minder"}
                else if x>upperBound {status="Iets meer"}
                else {status="Binnen referentiegebied"}
            }
        }
        bands.append(ToneBandVerdict(id:b,name:toneNames[b],range:toneRanges[b],value:v,median:med,lower:lo,upper:hi,delta:delta,status:status,attention:attention))
    }
    let active=usableSlices(slices,loud:loud,quiet:quiet)
    // Compute each slice shape at most once across all requested markers.
    var markerShapes:[[Double?]]?
    func marker(_ indices:[Int],high:Bool)->Double? {
        if markerShapes == nil {markerShapes=active.map{sevenToneBands(summarizeTone([$0]).bands)}}
        let values=markerShapes!.map{shape in indices.reduce(0.0){$0+(shape[$1] ?? -100)}}
        return active.indices.max{high ? values[$0]<values[$1]:values[$0]>values[$1]}.map{active[$0].start}
    }
    if enough {
        // Low/rest ratio avoids saturation of percentages near 100% bass energy.
        func lowRest(_ db:Double)->Double {let p=min(1-1e-12,pow(10,db/10));return 10*log10(max(1e-12,p)/(1-p))}
        let lowTargets=targets.compactMap{$0.lowRatio}.map(lowRest),lowTop=quantile(lowTargets,0.9),lowBottom=quantile(lowTargets,0.1)
        let contrastBottom=quantile(targets.compactMap{$0.lowContrast},0.1)
        if let fraction=summary.lowRatio,let top=lowTop,lowRest(fraction)>top+3 {
            let low=lowRest(fraction)
            let sustained=(summary.lowContrast ?? 100)<(contrastBottom ?? -100)-1
            advice.append(ToneAdvice(id:"bass",title:sustained ? "Prominent én gelijkmatig laag":"Laag staat duidelijk vooraan",evidence:"20–120 Hz ligt \(display(low-(quantile(lowTargets,0.5) ?? low))) dB boven de referentiemediaan ten opzichte van 120 Hz–10 kHz."+(sustained ? " De laag-envelop heeft ook minder contrast binnen de meetvensters.":" Veel laag is niet vanzelf een probleem."),action:sustained ? "Luister of het prominente laag de overige partijen hoorbaar bedekt. Vergelijk basniveau en sustain vóór een brede master-EQ-cut. De meetvensters isoleren geen kick of basstaart en bewijzen geen masking of compressie.":"Vergelijk op gelijk luisterniveau of kick en bas prominent mogen zijn, of de middenpartijen naar achteren drukken. Probeer eerst een kleine aanpassing en A/B; geen verplichte basreductie.",start:marker([0,1],high:true)))
        } else if let low=summary.lowRatio,let bottom=lowBottom,lowRest(low)<bottom-3 {
            advice.append(ToneAdvice(id:"bass-light",title:"Lichter fundament dan de referenties",evidence:"20–120 Hz is relatief minder aanwezig dan in de meeste gekozen voorbeelden.",action:"Controleer de volle passage. Bij een arrangement zonder bas is dit logisch. Alleen als een stevig fundament de bedoeling is: vergelijk basnoten, kickgewicht en sustain; niet blind sub toevoegen.",start:marker([0,1],high:false)))
        }
        if !advice.contains(where:{$0.id.hasPrefix("bass")}),bands.prefix(2).contains(where:{$0.attention}) {
            let sub=(bands[0].delta ?? 0)>(bands[1].delta ?? 0)
            advice.append(ToneAdvice(id:"bass-distribution",title:sub ? "Meer nadruk op subdiepte":"Meer nadruk op de bovenbas",evidence:"De verdeling tussen 20–60 en 60–120 Hz wijkt af van deze referenties; de totale hoeveelheid laag hoeft niet te hoog of te laag te zijn.",action:"Vergelijk kickgewicht en de ligging van de basnoten. Dit kan door toonsoort, instrumentkeuze of arrangement komen. Pas alleen aan als die verdeling niet bij de beoogde klank past.",start:marker([sub ? 0:1],high:true)))
        }
        let dominantLow=advice.contains{$0.id=="bass"}
        let focus=bands.filter{$0.attention && $0.id>=2 && $0.id<6 && !(dominantLow && ($0.delta ?? 0)<0)}.sorted{abs($0.delta ?? 0)>abs($1.delta ?? 0)}
        for b in focus.prefix(2) {
            let high=(b.delta ?? 0)>0
            let action=b.id<=3 ? (high ? "Luister naar warmte tegenover leesbaarheid. Aanhoudende energie kan een volle klank zijn; deze meting bewijst geen mud. Vergelijk eerst de betreffende partijen, daarna pas een brede EQ-aanpassing.":"Luister of er warmte of body ontbreekt, of dat een open arrangement deze ruimte bewust laat. Vergelijk de relevante partijen; voeg niet automatisch laagmidden toe omdat de referentiemediaan hoger ligt."):(high ? "Luister op gelijk niveau naar nadruk, scherpte en vermoeidheid. Controleer of het hele arrangement of een enkele partij de nadruk veroorzaakt; geen automatische EQ-cut.":"Vergelijk aanwezigheid en helderheid op gelijk niveau. Een donkere esthetiek kan bewust zijn; probeer alleen een kleine brede correctie als de mix werkelijk terugvalt.")
            advice.append(ToneAdvice(id:"band-\(b.id)",title:"\(toneLabels[b.id]): \(high ? "meer nadruk":"terughoudender")",evidence:"\(display(b.delta)) dB tegenover de mediaan; buiten de gebruikelijke spreiding plus beoordelingsmarge.",action:action,start:marker([b.id],high:high)))
        }
    }
    if summary.seconds>=8,let mono=summary.lowMono,mono < -6,let low=summary.lowRatio,low > -25 {
        advice.insert(ToneAdvice(id:"low-mono",title:"Laag verliest energie in mono",evidence:"20–120 Hz: \(display(mono)) dB volgens 2E(mono)/(E(L)+E(R)).",action:"Controleer of het fundament op een monosysteem overeind blijft. Onderzoek polariteit of stereoverbreding van het laag. Deze verhouding is geen voorspelling van elk luidsprekersysteem.",start:active.min{($0.lowMono ?? 0)<($1.lowMono ?? 0)}?.start),at:0)
    }
    let conclusion = library.loadIssue ?? (summary.seconds<8 ? "Te weinig actieve audio voor een toonbalansoordeel." : (!enough ? "Kies een genre met minimaal vijf onafhankelijke referenties." : (bands.contains{$0.attention} || !advice.isEmpty ? "Er zijn klankverschillen om gericht te beluisteren; geen automatische afkeur." : "Geen duidelijke tonale uitschieter tegenover deze referenties. Dat is geen volledige kwaliteitsgoedkeuring.")))
    return ToneAssessment(genre:genre,mode:loud ? "Luidere passages":(quiet ? "Rustigere referentiepassages":"Actieve muziek"),referenceCount:refs.count,referenceTitles:refs.map{$0.title},summary:summary,bands:bands,advice:advice,conclusion:conclusion,limitation:"Voorlopige pilotbibliotheek; geen universele genre-norm. Bandenergie relatief aan 20 Hz–10 kHz, niet een voorgeschreven EQ-curve. Air is beschrijvend vanwege lossy bronnen. Envelopcontrast is geen meting van compressorinstellingen of hoorbare masking.")
}
struct FeatureDocument:Codable {var source:String;var sha256:String;var sampleRate:Double;var duration:Double;var slices:[ToneSlice];var active:ToneSummary;var loud:ToneSummary;var quiet:ToneSummary;var sections:[ArrangementSection];var referenceIdentity:ReferenceIdentity? = nil}
func analyzeFeatures(_ url:URL)throws->FeatureDocument {
    let hash=try sha256(url),file=try AudioInput(url),format=file.format!,rate=format.sampleRate,ch=Int(format.channelCount)
    guard let q=qct_create(Int32(rate),Int32(ch),file.length) else{throw QCFailure(message:"Ongeldig formaat voor toonbalans.")};defer{qct_destroy(q)}
    let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:8192)!
    var frames:Int64=0
    while frames<file.length{try file.read(into:buffer,frameCount:AVAudioFrameCount(min(8192,file.length-frames)));guard buffer.frameLength>0,qct_push(q,buffer.floatChannelData![0],Int32(buffer.frameLength))==0 else{throw QCFailure(message:"Onvolledige of ongeldige audio.")};frames+=Int64(buffer.frameLength)}
    try file.finish(atEnd:true)
    let slices=extractSlices(q),duration=Double(frames)/rate
    return FeatureDocument(source:url.path,sha256:hash,sampleRate:rate,duration:duration,slices:slices,active:summarizeTone(slices),loud:summarizeTone(slices,loud:true),quiet:summarizeTone(slices,quiet:true),sections:arrangement(slices,duration:duration),referenceIdentity:ReferenceIdentities.shared.resolve(hash:hash,duration:duration,slices:slices))
}
