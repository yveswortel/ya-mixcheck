import Foundation

struct DynamicsSlice:Codable, Sendable {var start:Double;var duration:Double;var rms:Double;var crest:Double;var onset:Double}
// 10 ms envelopes, summarized every 100 ms. No allocation per sample, channel energy summed.
final class DynamicsDetector {
    let rate:Double,channels:Int,hop:Int
    var frames=0,n=0,hops=0,energy=0.0,total=0.0,peak=0.0,onset=0.0,baseline=0.0
    var slices=[DynamicsSlice]()
    init(rate:Double,channels:Int){self.rate=rate;self.channels=channels;hop=Int((rate*0.01).rounded())}
    func push(_ p:UnsafePointer<Float>,frames count:Int){
        for i in 0..<count {
            for c in 0..<channels{let x=Double(p[i*channels+c]);energy+=x*x;peak=max(peak,abs(x))}
            n+=1;frames+=1
            if n==hop {
                let power=energy/Double(n*channels)
                if frames>hop*10,power>1e-7,baseline>1e-9{onset=max(onset,max(0,10*log10(power/baseline)))}
                baseline=0.9*baseline+0.1*power;total+=energy;energy=0;n=0;hops+=1
                if hops==10{emit()}
            }
        }
    }
    func emit(){
        let count=hops*hop+n
        guard count>0 else{return}
        let power=(total+energy)/Double(count*channels)
        let rms=10*log10(max(1e-20,power))
        slices.append(DynamicsSlice(start:Double(frames-count)/rate,duration:Double(count)/rate,rms:rms,crest:max(0,20*log10(max(1e-10,peak))-rms),onset:onset))
        hops=0;n=0;total=0;energy=0;peak=0;onset=0
    }
}
struct DynamicsSummary:Codable {
    var density:Double?;var punch:Double?;var movement:Double?;var seconds:Double
}
func summarizeDynamics(_ input:[DynamicsSlice])->DynamicsSummary {
    let top=quantile(input.map{$0.rms},0.9) ?? -200
    let active=input.filter{$0.duration>=0.09 && $0.rms>max(-70,top-20)}
    // Movement uses one-second energy averages, not individual drum hits.
    var groups=[Int:[DynamicsSlice]]()
    for x in active{groups[Int(x.start),default:[]].append(x)}
    let windows=groups.values.compactMap{xs->(Double,Double)? in
        let seconds=xs.reduce(0){$0+$1.duration};guard seconds>=0.8 else{return nil}
        let level=powerDB(xs.reduce(0){$0+pow(10,$1.rms/10)*$1.duration}/seconds)!
        let peak=xs.map{$0.rms+$0.crest}.max()!
        return (level,level-peak)
    }
    let levels=windows.map{$0.0}
    let seconds=active.reduce(0){$0+$1.duration}
    guard seconds>=8 else{return DynamicsSummary(density:nil,punch:nil,movement:nil,seconds:seconds)}
    return DynamicsSummary(density:quantile(windows.map{$0.1},0.5),punch:quantile(active.map{$0.onset},0.9),movement:levels.count>=8 ? (quantile(levels,0.9)!-quantile(levels,0.1)!):nil,seconds:seconds)
}
struct DynamicsReference:Codable {var title:String;var genre:String;var hashes:[String];var active:DynamicsSummary;var loud:DynamicsSummary;var quiet:DynamicsSummary}
struct DynamicsLibrary:Codable {
    var version:String;var references:[DynamicsReference]
    var loadIssue:String? = nil
    static func load(_ data:Data?)->DynamicsLibrary {
        guard let data,let l=try? JSONDecoder().decode(Self.self,from:data) else{return Self(version:"unavailable",references:[],loadIssue:"Dynamicsreferenties ontbreken of zijn beschadigd.")}
        guard l.version=="1" else{return Self(version:l.version,references:[],loadIssue:"Niet-ondersteunde dynamicsbibliotheekversie \(l.version).")}
        return l
    }
    static let shared:DynamicsLibrary = load(Bundle.main.url(forResource:"DynamicsReferences",withExtension:"json").flatMap{try? Data(contentsOf:$0)})
}
func dynamicsModes(_ slices:[DynamicsSlice])->[String:DynamicsSummary]{
    // Select complete 2s windows, preserving within-window transient structure.
    let bins=Dictionary(grouping:slices,by:{Int($0.start/2)})
    let levels=bins.mapValues{xs in xs.reduce(0){$0+pow(10,$1.rms/10)}/Double(xs.count)}
    let med=quantile(Array(levels.values),0.5) ?? 0
    return ["active":summarizeDynamics(slices),"loud":summarizeDynamics(slices.filter{(levels[Int($0.start/2)] ?? 0)>=med}),"quiet":summarizeDynamics(slices.filter{(levels[Int($0.start/2)] ?? 0)<=med})]
}
struct DynamicsMetric:Codable,Identifiable {var id:String;var name:String;var value:Double?;var lower:Double?;var median:Double?;var upper:Double?;var label:String}
struct PassageDynamics:Codable,Identifiable {
    var id:Int;var start:Double;var end:Double;var mode:String;var referenceCount:Int;var summary:DynamicsSummary;var metrics:[DynamicsMetric]
}
func passageDynamics(_ a:Analysis,sections:[ArrangementSection],genre:String,library:DynamicsLibrary = .shared,index:DynamicsSliceIndex?=nil)->[PassageDynamics]{
    let index=index ?? DynamicsSliceIndex(a.dynamics)
    let refs=library.references.filter{$0.genre==genre && !$0.hashes.contains(a.assessmentHash)}
    return sections.map{s in
        let summary=summarizeDynamics(index.within(start:s.start,end:s.end))
        let quiet=s.label=="Rustiger",targets=refs.map{quiet ? $0.quiet:$0.loud}
        return PassageDynamics(id:s.id,start:s.start,end:s.end,mode:quiet ? "Rustigere referentievensters":"Luidere referentievensters",referenceCount:refs.count,summary:summary,metrics:dynamicsMetrics(summary,targets:targets))
    }
}
struct ListeningAdvice:Codable,Identifiable {var id:String;var title:String;var evidence:String;var listen:String;var action:String;var start:Double;var priority:Double;var support:Double = 0}
func listeningAdvice(_ a:Analysis,sections:[ArrangementSection],genre:String,purpose:String,library:DynamicsLibrary = .shared)->[ListeningAdvice]{
    listeningAdvice(RecommendationAnalysis(a,genre:genre,sections:sections,library:library),purpose:purpose)
}
func listeningAdvice(_ context:RecommendationAnalysis,purpose:String)->[ListeningAdvice]{
    let a=context.analysis,sections=context.sections,genre=context.genre
    var choices=[ListeningAdvice]()
    // Technical integrity takes precedence; tonal/dynamics choices are never labelled faults.
    for o in a.secondOpinion(purpose:purpose) where ["overrange","channel-balance","mono","click","silence"].contains(o.id){
        if o.id=="overrange",a.codec.hasPrefix("MP3"),(a.samplePeak ?? 0)<=1 {continue}
        choices.append(ListeningAdvice(id:o.id,title:o.title,evidence:o.evidence,listen:"Beluister dit moment en vergelijk met de bedoelde export.",action:o.action,start:Double(o.startFrame ?? 0)/a.sampleRate,priority:100))
    }
    let ds=context.passages
    for s in sections {
        guard s.end-s.start>=8,let d=ds.first(where:{$0.id==s.id}),d.summary.seconds>=8 else{continue}
        let tone=assessTone(a.toneSlices.filter{$0.center>=s.start && $0.center<s.end},genre:genre,hash:a.assessmentHash,quiet:s.label=="Rustiger")
        func add(_ id:String,_ title:String,_ evidence:String,_ listen:String,_ action:String,_ priority:Double){choices.append(ListeningAdvice(id:id,title:title,evidence:evidence,listen:listen,action:action,start:s.start,priority:priority,support:s.end-s.start))}
        func low(_ id:String,_ margin:Double)->Bool{guard let m=d.metrics.first(where:{$0.id==id}),let v=m.value,let lo=m.lower else{return false};return v<lo-margin}
        func high(_ id:String,_ margin:Double)->Bool{guard let m=d.metrics.first(where:{$0.id==id}),let v=m.value,let hi=m.upper else{return false};return v>hi+margin}
        let bass=tone.advice.first{$0.id=="bass"}
        if let bass,low("punch",1.5),tone.referenceCount>=5 {
            let focus="Blijven ritmische accenten herkenbaar naast het prominente laag? De aanzetmeting is volbandig en isoleert geen kick of bas."
            add("low-punch","Controleer gewicht tegenover aanslag",bass.evidence+" Het globale aanzetcontrast is ook lager dan bij deze referenties.",focus,"Vergelijk eerst basniveau en sustain. Probeer alleen bij hoorbare bedekking een kortere basstaart of minder laag; geen automatische master-EQ-cut.",60)
        }
        if high("density",1),low("punch",1.5),low("movement",0.5){
            add("dense","Controleer of de volle passage nog ademt","Deze passage combineert hogere dichtheid met minder aanzetcontrast en minder niveauverandering dan de genrevoorbeelden.",genre=="EDM/house" ? "Blijven kickaanzet en de bedoelde pompbeweging overeind?":"Blijven aanzetten en kleine accenten hoorbaar op gelijk niveau?","Vergelijk met iets minder eindlimiting. Sustained instrumenten en een bewust constante esthetiek kunnen hetzelfde patroon geven; dit bewijst geen overcompressie.",55)
        } else if low("density",2),high("punch",2){
            add("open","Wil je deze passage voller laten voelen?","De passage heeft meer piekruimte én meer aanzetcontrast dan de meeste genrevoorbeelden.",genre=="Alternative/indie" ? "Draagt de openheid de expressie, of verliezen zachtere partijen hun samenhang?":"Steken vooral losse slagen uit, terwijl de tussenliggende muziek terugvalt?","Als openheid de bedoeling is: behouden. Controleer anders eerst de onderlinge balans; vergelijk daarna een kleine hoeveelheid compressie op gelijk luisterniveau. Geen verplicht loudnessdoel.",40)
        }
        // Two adjacent tonal deviations: avoid single-band and compositional bass false alarms.
        if bass==nil,tone.referenceCount>=5 {
            let bands=tone.bands
            for pair in [[2,3],[4,5]] {
                let x=bands[pair[0]],y=bands[pair[1]]
                if x.attention,y.attention,(x.delta ?? 0)*(y.delta ?? 0)>0 {
                    let boosted=(x.delta ?? 0)>0,body=pair[0]==2
                    add(body ? "body":"presence",body ? "Controleer body en leesbaarheid":"Controleer aanwezigheid en luistercomfort","Twee aangrenzende gebieden wijken in dezelfde richting af: \(x.name) \(display(x.delta)) dB en \(y.name) \(display(y.delta)) dB tegenover de mediaan.",body ? "Klinkt dit bewust warm/open, of raken partijen elkaar kwijt?":"Blijven details prettig hoorbaar, ook na langer luisteren?",boosted ? "Vergelijk een kleine brede reductie, of pas de dominante partij aan. Behoud de nadruk als die bij de stijl past.":"Vergelijk op gelijk niveau met je referentie; probeer alleen bij hoorbaar gemis een kleine brede boost. Een donker of open arrangement is geen fout.",30+min(10,abs(x.delta ?? 0)))
                }
            }
        }
    }
    // A local arrangement change alone should not dominate the track-level shortlist.
    let supported=choices.filter{candidate in
        guard ["body","presence"].contains(candidate.id) else{return true}
        let seconds=choices.filter{$0.id==candidate.id}.reduce(0){$0+$1.support}
        return seconds>=max(16,a.duration*0.2)
    }
    var seen=Set<String>()
    return supported.sorted{if $0.priority != $1.priority{return $0.priority>$1.priority};return $0.start<$1.start}.filter{seen.insert($0.id).inserted}.prefix(3).map{$0}
}

struct TrackDynamics:Codable {
    var referenceCount:Int;var summary:DynamicsSummary;var metrics:[DynamicsMetric]
}
func trackDynamics(_ a:Analysis,genre:String,library:DynamicsLibrary = .shared)->TrackDynamics {
    let refs=library.references.filter{$0.genre==genre && !$0.hashes.contains(a.assessmentHash)}
    let summary=summarizeDynamics(a.dynamics)
    return TrackDynamics(referenceCount:refs.count,summary:summary,metrics:dynamicsMetrics(summary,targets:refs.map{$0.active}))
}
func dynamicsMetrics(_ summary:DynamicsSummary,targets:[DynamicsSummary])->[DynamicsMetric] {
        func metric(_ id:String,_ name:String,_ v:Double?,_ values:[Double],_ labels:[String])->DynamicsMetric{
            let lo=quantile(values,0.1),hi=quantile(values,0.9),med=quantile(values,0.5)
            var label="Onvoldoende context"
            if let v,values.count>=5,let lo,let hi {label=v<lo ? labels[0]:(v>hi ? labels[2]:labels[1])}
            return DynamicsMetric(id:id,name:name,value:v,lower:values.count>=5 ? lo:nil,median:values.count>=5 ? med:nil,upper:values.count>=5 ? hi:nil,label:label)
        }

    return [
            metric("density","Dichtheid",summary.density,targets.compactMap{$0.density},["Luchtiger","Binnen spreiding","Dichter"]),
            metric("punch","Punch",summary.punch,targets.compactMap{$0.punch},["Minder aanzetcontrast","Binnen spreiding","Meer aanzetcontrast"]),
            metric("movement","Beweging",summary.movement,targets.compactMap{$0.movement},["Gelijkmatiger","Binnen spreiding","Meer beweging"])]
}
