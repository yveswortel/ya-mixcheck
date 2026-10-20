import SwiftUI
struct ListeningPanel:View {
    @ObservedObject var s:Session
    let r:Analysis
    @State private var showEvidence=false
    var body:some View {
        let advice=s.recommendations
        VStack(alignment:.leading,spacing:16){
            HStack(alignment:.firstTextBaseline){
                Text("Advies voor jouw mix").font(.title3.bold())
                Spacer()
                Button("Onderbouwing…"){showEvidence=true}
                    .help("Bekijk de meetbasis, beperkingen en luistermomenten bij de adviezen")
            }
            Text("\(s.genre) · hele track. Luister op gelijk niveau en behoud bewuste keuzes.")
                .font(.caption).foregroundStyle(.secondary)
            if advice.isEmpty {
                Text("Geen duidelijke aanleiding voor een aanpassing uit de beschikbare metingen. Vergelijk vooral balans, groove en luistercomfort met je referentie; dit is geen kwaliteitsgoedkeuring.").font(.callout)
            }
            ForEach(advice){a in
                VStack(alignment:.leading,spacing:5){
                    Text(a.title).font(.system(size:14,weight:.semibold))
                    Text(a.action).font(.system(size:13)).lineSpacing(3)
                        .fixedSize(horizontal:false,vertical:true)
                }.frame(maxWidth:760,alignment:.leading)
            }
        }.padding(20).frame(maxWidth:.infinity,alignment:.leading)
            .background(.white.opacity(0.035),in:RoundedRectangle(cornerRadius:10))
            .sheet(isPresented:$showEvidence){
                VStack(alignment:.leading,spacing:16){
                    HStack{
                        Text("Onderbouwing van het advies").font(.title2.bold())
                        Spacer()
                        Button("Gereed"){showEvidence=false}.keyboardShortcut(.cancelAction)
                    }
                    Text("\(s.genre) · hele track").foregroundStyle(.secondary)
                    Divider()
                    ScrollView{
                        VStack(alignment:.leading,spacing:20){
                            ForEach(advice){a in
                                VStack(alignment:.leading,spacing:6){
                                    Text(a.title).font(.headline)
                                    Text(a.evidence).textSelection(.enabled)
                                    if let start=a.start {
                                        Button(String(format:"Ga naar %d:%02d",Int(start)/60,Int(start)%60)) {
                                            showEvidence=false;s.stop();s.usingReference=false;s.comparisonMode="Hele nummer";s.seek(start)
                                        }
                                    }
                                }
                            }
                            VStack(alignment:.leading,spacing:6){
                                Text("Wat de metingen niet bepalen").font(.headline)
                                Text("LUFS, LRA, PLR en crest zijn geen kwaliteitsdoelen. Vergelijk passende muziek op gelijk luisterniveau. Stem headroom en eindlimiting af op de mastering. Veel laag is niet automatisch mud; Air is codecgevoelig. Een smal stereobeeld hoeft niet breder. De adviezen zijn luisterhypotheses, geen bewezen oorzaken of verplichte correcties.")
                            }
                            if !s.listeningReview.isEmpty {
                                VStack(alignment:.leading,spacing:10){
                                    Text("Luistermomenten").font(.headline)
                                    ForEach(s.listeningReview){a in
                                        HStack(alignment:.top){
                                            Text(a.listen)
                                            Spacer()
                                            Button(String(format:"Ga naar %d:%02d",Int(a.start)/60,Int(a.start)%60)){
                                                showEvidence=false;s.stop();s.usingReference=false;s.comparisonMode="Hele nummer";s.seek(a.start)
                                            }
                                        }
                                    }
                                }
                            }
                        }.font(.system(size:13)).lineSpacing(3).frame(maxWidth:.infinity,alignment:.leading).padding(.trailing,8)
                    }
                }.padding(24).frame(width:620,height:540)
            }
    }
}
struct DynamicsPanel:View {
    @ObservedObject var s:Session
    let r:Analysis
    var body:some View {
        VStack(alignment:.leading,spacing:12){
            Text("Dynamics · hele track").font(.title3.bold())
            if let d=s.dynamicsReview {
                VStack(alignment:.leading,spacing:14){
                    Text("Actieve muziek · \(d.referenceCount) genrevoorbeelden")
                        .font(.caption).foregroundStyle(.secondary)
                    VStack(spacing:20){
                        ForEach(d.metrics){m in DynamicsMeter(metric:m)}
                    }.padding(16).background(.white.opacity(0.025),in:RoundedRectangle(cornerRadius:8))
                    HelpButton("Dynamics-uitleg"){
                        Text("Eén overzicht over de hele track; stilte en zeer zachte delen tellen niet mee. Dichtheid: typische piek/RMS-afstand op 1 seconde; dichter bij nul = dichter. Punch: snelle envelopaanzet tegenover circa 100 ms ervoor. Beweging: spreiding van 1-s-energieniveaus over de track, inclusief arrangementverschillen. Geen bewijs van overcompressie. Minimaal 8 actieve seconden. Referenties P10–P90, één gewicht per track; kleine pilotbibliotheek, deels MP3. Meer dichtheid of punch is niet automatisch beter.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.top,10)
            }
        }
    }
}

struct DynamicsMeter:View {
    let metric:DynamicsMetric
    var body:some View {
        VStack(alignment:.leading,spacing:8){
            HStack{Text(metric.name).fontWeight(.semibold);Spacer();Text(metric.label).foregroundStyle(.secondary);Text("\(display(metric.value)) dB").monospacedDigit().frame(minWidth:72,alignment:.trailing)}
                .font(.system(size:13))
            if let value=metric.value,let low=metric.lower,let high=metric.upper,value.isFinite,low.isFinite,high.isFinite {
                let span=max(2,high-low)
                let minimum=min(low-span*0.6,value-span*0.15)
                let maximum=max(high+span*0.6,value+span*0.15)
                GeometryReader{g in
                    let width=max(1,g.size.width-12)
                    let x={ (v:Double) in CGFloat((v-minimum)/(maximum-minimum))*width+6 }
                    ZStack(alignment:.leading){
                        Capsule().fill(.white.opacity(0.07)).frame(height:12)
                        Capsule().fill(Color(red:0.48,green:0.72,blue:0.80).opacity(0.35))
                            .frame(width:max(2,x(high)-x(low)),height:12).offset(x:x(low))
                        if let mid=metric.median {Rectangle().fill(.white.opacity(0.4)).frame(width:1,height:12).offset(x:x(mid))}
                        Capsule().fill(.white).frame(width:4,height:24).offset(x:x(value)-2)
                    }.frame(height:24)
                }.frame(height:24).accessibilityHidden(true)
                HStack{Text("\(display(minimum))");Spacer();Text("Referenties \(display(low))–\(display(high)) dB");Spacer();Text("\(display(maximum))")}.font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            } else {Text("Onvoldoende meet- of referentiegegevens").font(.caption).foregroundStyle(.secondary)}
        }.accessibilityElement(children:.combine)
    }
}
