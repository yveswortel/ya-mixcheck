import Foundation
struct MixRecommendation:Codable,Identifiable {
    var id:String;var title:String;var evidence:String;var action:String;var start:Double? = nil;var scope:String? = nil;var supportFraction:Double? = nil;var contrast:Double? = nil
}
// Suggestions, not diagnoses. Relative energy can move because another band changed.
let toneSuggestions:[(low:String,high:String)] = [
    ("Mis je diepte? Vergelijk eerst de laagste basnoten en het kickgewicht. Een lichte productie hoeft geen extra sub; voeg alleen iets toe als het arrangement daarom vraagt.","Luister of het diepe laag ruimte inneemt zonder hoorbaar gewicht toe te voegen. Vergelijk basniveau en sustain; behoud de diepte als die de groove draagt."),
    ("Mist het fundament op normaal volume? Vergelijk de balans tussen kick, bas en de rest voordat je breed laag toevoegt.","Luister of kick en bas de hoofdpartijen naar achteren drukken. Probeer hun niveau of staarten iets terug te nemen als het geheel daardoor duidelijker wordt."),
    ("Klinkt de mix dun? Luister of instrumenten hun warmte verliezen. Vergelijk minder uitdunnen in de partijen voordat je de hele mix voller maakt.","Luister of warmte omslaat in een wollige klank. Kijk eerst welke partijen hier samenkomen; probeer ruimte te maken in een dominante partij in plaats van alles uit te hollen."),
    ("Missen zang of instrumenten lichaam? Vergelijk hun balans en eerdere EQ-cuts. Een open klank kan ook precies de bedoeling zijn.","Luister of de mix vol klinkt of juist gesloten en doosachtig. Probeer een kleine verandering bij de partij die dit gebied domineert; behoud voldoende body."),
    ("Komen melodie en hoofdpartij voldoende naar voren, ook zacht afgespeeld? Vergelijk hun onderlinge niveau voordat je de hele mix meer mids geeft.","Luister of de hoofdpartijen duidelijk blijven zonder druk of nasaal te worden. Vergelijk een zachtere dominante partij of een milde brede EQ-aanpassing."),
    ("Mis je definitie of is de donkere klank bewust? Vergelijk zang, percussie en aanslagen op gelijk niveau voordat je meer helderheid toevoegt.","Luister langer naar scherpte en vermoeidheid, vooral bij zang en percussie. Probeer eerst de dominante bron te verzachten; veel detail is op zichzelf geen fout."),
    ("Als je lucht mist, vergelijk een lossless referentie en de bronkwaliteit. MP3 kan dit gebied veranderen; voeg niet automatisch hoog toe om de curve te volgen.","Als het hoog ruisachtig of vermoeiend klinkt, controleer cymbals, sibilantie en eventuele exciters. Vergelijk lossless voordat je op deze meting ingrijpt.")
]
func tonalRecommendations(_ tone:ToneAssessment)->[MixRecommendation] {
    guard tone.referenceCount>=5,tone.summary.seconds>=8 else{return []}
    return tone.bands.compactMap{b in
        guard b.id>=0,b.id<6,b.attention,let delta=b.delta,delta.isFinite else{return nil}
        return MixRecommendation(id:"tone-\(b.id)",title:"\(b.name) · \(delta>0 ? "meer nadruk":"minder nadruk")",evidence:"\(b.status.lowercased()) dan de genrevoorbeelden. Relatieve klankverhouding, geen aanbevolen EQ-gain.",action:delta>0 ? toneSuggestions[b.id].high:toneSuggestions[b.id].low)
    }
}
func dynamicsRecommendations(_ d:TrackDynamics)->[MixRecommendation] {
    d.metrics.compactMap{m in
        guard let v=m.value,let lo=m.lower,let hi=m.upper,v.isFinite else{return nil}
        // Small excursions outside the pilot range are not useful reasons to intervene.
        let margin=m.id=="density" ? 1.0:1.5
        guard v<lo-margin || v>hi+margin else{return nil}
        let high=v>hi
        let action:String
        switch m.id {
        case "density": action=high ? "Luister of de volle klank nog ontspant en aanzetten herkenbaar blijven. Vergelijk met minder eindlimiting als het vermoeiend klinkt; een dichte master kan bewust zijn.":"Wil je meer samenhang of is de openheid prettig? Controleer eerst balans en sustain. Vergelijk eventueel lichte compressie op gelijk niveau; meer loudness is geen doel op zichzelf."
        case "punch": action=high ? "Luister of losse slagen prettig uitspringen of de rest wegdrukken. Probeer eerst hun niveau of envelope; behoud de aanslag als die de groove maakt.":"Luister of kick, snare en andere accenten voldoende spreken. Vergelijk balans en minder transient-afvlakking; een vloeiende of aangehouden klank hoeft geen extra punch."
        case "movement": action=high ? "Luister naar de overgangen: blijven rustigere delen betrokken en vollere delen beheerst? Vergelijk niveau-automatisering alleen als het contrast onbedoeld voelt.":"Luister of het nummer genoeg ontwikkeling heeft. Arrangement of niveau-automatisering kan meer contrast geven; een constante dansgroove hoeft niet meer te bewegen."
        default:return nil
        }
        return MixRecommendation(id:"dynamics-\(m.id)",title:"\(m.name) · \(m.label.lowercased())",evidence:"Over de actieve muziek van de hele track, tegenover genrevoorbeelden. Geen bewijs van te veel of te weinig compressie.",action:action)
    }
}
func mixRecommendations(_ a:Analysis,genre:String,purpose:String)->[MixRecommendation] {
    mixRecommendations(RecommendationAnalysis(a,genre:genre),purpose:purpose)
}
func mixRecommendations(_ context:RecommendationAnalysis,purpose:String)->[MixRecommendation] {
    let a=context.analysis
    var items=a.secondOpinion(purpose:purpose).filter{
        $0.category != "Context, geen fout" && !($0.id=="overrange" && a.codec.hasPrefix("MP3") && (a.samplePeak ?? 0)<=1)
    }.map{MixRecommendation(id:"technical-"+$0.id,title:$0.title,evidence:$0.evidence,action:$0.action,start:$0.startFrame.map{Double($0)/a.sampleRate},scope:$0.startFrame == nil ? "Trackcontext":"Lokaal")}
    let stereo=a.stereoAssessment
    if !items.contains(where:{$0.id=="technical-mono"}),let m=stereo["monoEnergy"],let c=stereo["correlation"],m.level == .orange || c.level == .orange {
        items.append(MixRecommendation(id:"stereo",title:"Stereo · beluister ook mono",evidence:"De mono-energie of correlatie vraagt een luistercontrole; breedte kan bewust zijn.",action:"Blijven zang, kick en bas overeind in mono? Controleer wideners en polariteit als belangrijke partijen verdwijnen. Maak het beeld niet smaller alleen om een meter groener te krijgen."))
    }
    if let sub=localSubRecommendation(a){items.append(sub)}
    items += temporalRecommendations(context,purpose:purpose)
    // Lowest priority: a level preference must never displace technical or tonal advice.
    if let level=a.loudnessReview(purpose:purpose,dynamics:context.dynamics).advice {items.append(level)}
    let fallback=representativeActiveStart(a.toneSlices)
    for i in items.indices {
        if items[i].start == nil {items[i].start=fallback;items[i].scope=items[i].scope ?? "Trackcontext"}
        else if items[i].scope == nil {items[i].scope="Lokaal"}
    }
    var seen=Set<String>()
    // One slot per pattern: opposing local directions must not duplicate SwiftUI IDs.
    return Array(items.filter{seen.insert($0.id).inserted}.prefix(3))
}

// Joint patterns are listening hypotheses, not instrument or compressor identification.
func contextualRecommendations(tone:ToneAssessment,d:TrackDynamics,passages:[PassageDynamics],purpose:String)->[MixRecommendation] {
    var items=[MixRecommendation](),consumed=Set<String>()
    func metric(_ id:String)->DynamicsMetric?{d.metrics.first{$0.id==id}}
    func extreme(_ id:String,high:Bool,margin:Double)->Bool {
        guard let m=metric(id),let v=m.value,let lo=m.lower,let hi=m.upper else{return false}
        return high ? v>hi+margin:v<lo-margin
    }
    // Air stays descriptive alone. Only a large, joint contrast generates a listening suggestion.
    let hollow=tone.bands.filter{[3,4].contains($0.id) && $0.attention && ($0.delta ?? 0)<(-4)}
    if tone.referenceCount>=5,tone.summary.seconds>=8,hollow.count==2,
       let air=tone.bands.first(where:{$0.id==6}),let v=air.value,let upper=air.upper,
       let delta=air.delta,v>upper+3,delta>6 {
        consumed.formUnion(hollow.map{"tone-\($0.id)"})
        items.append(MixRecommendation(id:"air-body-mids",title:"Veel lucht tegenover weinig kern",evidence:"Air ligt ruim boven deze genrevoorbeelden, terwijl body én mids relatief terugliggen. Samen vormt dit een groter klankcontrast dan één losse band. Air is gevoelig voor codec, bronmateriaal en de beperkte referentieset; dit bewijst geen slechte mix.",action:"Luister op gelijk niveau of cymbals, sibilantie of ruis de aandacht trekken terwijl zang en instrumenten weinig lichaam hebben. Vergelijk eerst iets minder van de dominante hoge bron; beoordeel daarna pas of body of mids echt ontbreken. Voeg niet automatisch beide toe om de curve te volgen."))
    }
    let bass=tone.bands.filter{$0.id<2 && $0.attention && ($0.delta ?? 0)>0}
    let presence=tone.bands.filter{(2...5).contains($0.id) && $0.attention && ($0.delta ?? 0)<0}
    if !bass.isEmpty && !presence.isEmpty {
        consumed.formUnion((bass+presence).map{"tone-\($0.id)"})
        items.append(MixRecommendation(id:"balance-weight-presence",title:"Laaggewicht tegenover leesbaarheid",evidence:"Meer nadruk op \(bass.map{$0.name}.joined(separator:", ")) gaat samen met minder relatieve energie in \(presence.map{$0.name}.joined(separator:", ")). De bandverhoudingen zijn gekoppeld: extra laag kan de rest relatief laten dalen. Dit bewijst geen zachtere vocal of masking.",action:"Vergelijk op gelijk niveau of het laag de groove draagt én de hoofdpartij leesbaar blijft. Probeer eerst één kleine verandering in basniveau of sustain. Luister opnieuw voordat je óók mids toevoegt; twee losse correcties kunnen hetzelfde balansverschil overcompenseren."))
    }
    if extreme("density",high:true,margin:1) && extreme("punch",high:false,margin:1.5) {
        consumed.formUnion(["dynamics-density","dynamics-punch"])
        items.append(MixRecommendation(id:"dense-soft-attacks",title:"Volle klank met weinig aanzetcontrast",evidence:"Hogere dichtheid én minder aanzetcontrast dan deze genrevoorbeelden. Aangehouden instrumenten kunnen hetzelfde patroon geven als dynamische verwerking.",action:"Luister of accenten nog loskomen uit de volle klank. Alleen als ze hoorbaar verdwijnen: vergelijk minder eindlimiting of de balans van de ritmische partijen. De metingen bewijzen geen overcompressie."))
    } else if extreme("density",high:false,margin:1) {
        let punch=metric("punch"),hasPunch=punch?.value != nil && punch?.lower != nil
        let intact=hasPunch && !extreme("punch",high:false,margin:1.5)
        if intact {
            consumed.formUnion(["dynamics-density","dynamics-punch"])
            items.append(MixRecommendation(id:"open-with-attacks",title:purpose=="Mix voor mastering" ? "Open mix met aanwezige aanzetten":"Openheid tegenover samenhang",evidence:"Minder dicht dan de masterreferenties, terwijl het aanzetcontrast niet duidelijk laag is. \(purpose=="Mix voor mastering" ? "Voor een premaster is de dichtheid van een afgemaakte master geen verplicht doel.":"Meer piekruimte is geen kwaliteitsgebrek.")",action:"Behoud de aanzetten als die de groove dragen. Luister of zachtere partijen tussen de slagen voldoende aanwezig blijven; pas hun balans alleen aan als daar iets ontbreekt. Voeg geen buscompressie toe alleen om de masterreferenties te benaderen."))
        }
    }
    if extreme("movement",high:true,margin:1.5),let whole=d.summary.movement {
        let valid=passages.filter{$0.summary.seconds>=8 && $0.summary.movement != nil}
        let coverage=valid.reduce(0){$0+$1.summary.seconds}
        if valid.count>=2,coverage>=d.summary.seconds*0.7 {
            let within=valid.reduce(0){$0+($1.summary.movement ?? 0)*$1.summary.seconds}/max(1,coverage)
            if within<whole*0.65 {
                consumed.insert("dynamics-movement")
                items.append(MixRecommendation(id:"arrangement-contrast",title:"Contrast tussen delen, niet overal onrust",evidence:"Beweging over de track: \(display(whole)) dB; gewogen binnen secties: \(display(within)) dB. Dit wijst op een rol van sectiecontrast, maar is geen oorzakelijke scheiding van arrangement en compressie.",action:"Beluister de overgang van een rustig naar een vol deel. Behoud het contrast als de energie goed opbouwt; werk alleen aan een overgang die onbedoeld inzakt of uitspringt. Trek de hele track niet gelijk op basis van de globale bewegingswaarde."))
            }
        }
    }
    items += tonalRecommendations(tone).filter{!consumed.contains($0.id)}
    items += dynamicsRecommendations(d).filter{!consumed.contains($0.id)}
    return items
}
