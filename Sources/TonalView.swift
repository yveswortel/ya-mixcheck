import SwiftUI

private let toneAccent=DashboardStyle.accent
private let toneWarm=DashboardStyle.amber
struct ArrangementPanel:View {
    @ObservedObject var s:Session
    func stamp(_ t:Double)->String{String(format:"%d:%02d",Int(t)/60,Int(t)%60)}
    var body:some View {
        DisclosureGroup("Passages (\(s.sections.count))") {
            VStack(alignment:.leading,spacing:10){
                HelpButton("Passages aanpassen"){Text("Selecteer een passage om de toonbalans daarvan te beoordelen. Voorstellen zijn gebaseerd op 2-s-vensters, geen herkenning van couplet of refrein. Grenzen in seconden, gescheiden door puntkomma’s; minstens 4 s per passage. Leeg + toepassen geeft één passage. Bewaar rapport neemt de indeling mee.")}
                Picker("Beoordeel",selection:$s.selectedSection){
                    Text("Hele track").tag(-1)
                    ForEach(s.sections){x in Text("\(stamp(x.start))–\(stamp(x.end)) · \(x.label)").tag(x.id)}
                }
                if let section=s.sections.first(where:{$0.id==s.selectedSection}) {
                    HStack{Text(section.change).foregroundStyle(.secondary);Button("Ga naar passage"){s.stop();s.comparisonMode="Hele nummer";if s.usingReference{s.switchSource()};s.seek(section.start)}}.font(.caption)
                }
                HStack{TextField("Grensseconden, bijvoorbeeld 18; 42; 88",text:$s.boundaryText);Button("Pas grenzen toe"){s.applyBoundaries()};Button("Automatisch"){s.manualBounds=nil;s.selectedSection = -1;s.boundaryText=""}}
            }.padding(.top,10)
        }.padding(16).background(Color.white.opacity(0.035),in:RoundedRectangle(cornerRadius:8))
    }
}
struct TonalPanel:View {
    @ObservedObject var s:Session
    let r:Analysis
    @AppStorage(ToneScaleAxis.preferenceKey) private var wideRange=false
    private var extent:Double{wideRange ? 12:6}
    var body:some View {
        let assessment=s.toneReview
        let preview=s.eqPlan
        VStack(alignment:.leading,spacing:16){
            HStack{Text("Toonbalans").font(.title3.bold());Spacer();Text("\(assessment.referenceCount) referentietracks · pilot").font(.caption).foregroundStyle(.secondary)}
            Picker("Meetbereik",selection:$s.tonalLoud){Text("Actieve muziek").tag(false);Text("Luidere passages").tag(true)}.pickerStyle(.segmented)
            Text("\(s.selectedSection<0 ? "Hele track":"Geselecteerde passage") · \(Int(assessment.summary.seconds)) s actieve meetvensters. ").font(.caption).foregroundStyle(.secondary)
            bandChart(assessment)
            VStack(alignment:.leading,spacing:7){
                HStack(spacing:14){
                    Button(s.eqPreview==nil ? "Maak EQ-preview":s.eqEnabled ? "Schakel EQ uit":"Schakel EQ in"){s.toggleEQ()}
                        .disabled(s.busy || s.usingReference || (s.eqPreview==nil && preview.bands.isEmpty))
                    Text(s.eqEnabled ? "Preview actief · metingen blijven origineel":"Metingen blijven origineel")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(s.usingReference ? "Wissel naar A om de EQ-preview te gebruiken.":preview.unavailableReason ?? "Basis: \(preview.context.lowercased()).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let eq=s.eqPreview {
                Text(eq.bands.map{String(format:"%.0f Hz: %+.1f dB",$0.hz,$0.gain)}.joined(separator:" · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack{
                VStack(alignment:.leading){Text("Laag in mono").font(.caption);Text("\(display(assessment.summary.lowMono)) dB").monospacedDigit()}
                Spacer()
                VStack(alignment:.leading){Text("Laag-envelopcontrast · traag").font(.caption);Text("\(display(assessment.summary.lowContrast)) dB").monospacedDigit()}
                Spacer()
                Text("20–120 Hz").font(.caption).foregroundStyle(.secondary)
            }

        }
    }
    func bandChart(_ a:ToneAssessment)->some View {
        VStack(spacing:0){
            HStack(spacing:18){
                Label("Jouw mix",systemImage:"minus").foregroundStyle(.white)
                Label("Referentiegebied",systemImage:"rectangle.fill").foregroundStyle(toneAccent)
                Spacer()
                Text("0 dB = mediaan").foregroundStyle(.secondary)
            }.font(.system(size:12,weight:.medium)).padding(.bottom,22)
            HStack(spacing:0){
                Color.clear.frame(width:46)
                ForEach(a.bands){b in
                    VStack(spacing:5){
                        Text(b.name).font(.system(size:15,weight:.semibold))
                        Text(b.range).font(.system(size:11)).foregroundStyle(.secondary)
                    }.frame(maxWidth:.infinity)
                }
            }.padding(.bottom,12)
            Canvas{ctx,size in
                let left=46.0,top=12.0,height=size.height-24,width=(size.width-left)/7,limit=extent
                func y(_ value:Double)->Double{top+(limit-max(-limit,min(limit,value)))/(2*limit)*height}
                for d in [-limit,-limit/2,0,limit/2,limit]{
                    var line=Path();line.move(to:CGPoint(x:left,y:y(d)));line.addLine(to:CGPoint(x:size.width,y:y(d)))
                    ctx.stroke(line,with:.color(.white.opacity(d==0 ? 0.42:0.1)),style:StrokeStyle(lineWidth:d==0 ? 1.5:1,dash:d==0 ? []:[3,4]))
                }
                for b in a.bands {
                    let x=left+(Double(b.id)+0.5)*width,w=width*0.72
                    let lane=CGRect(x:x-w/2,y:top,width:w,height:height)
                    ctx.fill(Path(roundedRect:lane,cornerRadius:5),with:.color(.white.opacity(0.025)))
                    if let lo=b.lower,let hi=b.upper,let m=b.median {
                        let rect=CGRect(x:x-w/2,y:y(hi-m),width:w,height:max(3,y(lo-m)-y(hi-m)))
                        let band=Path(roundedRect:rect,cornerRadius:3)
                        ctx.fill(band,with:.color(toneAccent.opacity(0.28)))
                        ctx.stroke(band,with:.color(toneAccent.opacity(0.75)),lineWidth:1)
                    }
                    if let delta=b.delta {
                        let color=b.attention ? toneWarm:Color.white
                        var stem=Path();stem.move(to:CGPoint(x:x,y:y(0)));stem.addLine(to:CGPoint(x:x,y:y(delta)))
                        ctx.stroke(stem,with:.color(color.opacity(0.5)),lineWidth:2)
                        let marker=Path(roundedRect:CGRect(x:x-w/2-2,y:y(delta)-3,width:w+4,height:6),cornerRadius:3)
                        ctx.fill(Path(roundedRect:CGRect(x:x-w/2-4,y:y(delta)-5,width:w+8,height:10),cornerRadius:4),with:.color(Color(red:0.07,green:0.1,blue:0.13)))
                        ctx.fill(marker,with:.color(color))
                        if abs(delta)>limit {
                            let direction=delta>0 ? -1.0:1.0,cy=y(delta)
                            var arrow=Path();arrow.move(to:CGPoint(x:x-5,y:cy-direction*7));arrow.addLine(to:CGPoint(x:x,y:cy+direction*1));arrow.addLine(to:CGPoint(x:x+5,y:cy-direction*7))
                            ctx.stroke(arrow,with:.color(color),lineWidth:2)
                        }
                    }
                }
            }.frame(height:244).accessibilityHidden(true)
                .overlay(alignment:.leading){ToneScaleAxis(wideRange:$wideRange,inset:12,intermediateTicks:true,alignment:.trailing).frame(width:36)}
            HStack(alignment:.top,spacing:0){
                Color.clear.frame(width:46,height:1)
                ForEach(a.bands){b in
                    VStack(spacing:6){
                        Text(b.delta.map{String(format:"%+.1f dB",$0)} ?? "—").font(.system(size:16,weight:.semibold)).monospacedDigit().foregroundStyle(b.attention ? toneWarm:.white)
                        Text(shortStatus(b)).font(.system(size:11,weight:.medium)).multilineTextAlignment(.center).foregroundStyle(b.attention ? toneWarm:toneAccent).frame(minHeight:28,alignment:.top)
                    }.frame(maxWidth:.infinity).padding(.horizontal,3)
                    .accessibilityElement(children:.ignore)
                    .accessibilityLabel("\(b.name), \(b.range), \(b.delta.map{String(format:"%+.1f dB",$0)} ?? "niet beschikbaar") tegenover de referentiemediaan. \(b.status)")
                    .help("\(b.name) · \(b.range). \(b.status). \(abs(b.delta ?? 0)>extent ? "Meetstreep buiten de schaal; exacte waarde hieronder.":"Het vlak toont P10–P90; de meetstreep is jouw mix.")")
                }
            }.padding(.top,8)
        }.padding(18).background(Color(red:0.055,green:0.08,blue:0.105),in:RoundedRectangle(cornerRadius:10))
    }
    func shortStatus(_ b:ToneBandVerdict)->String {
        switch b.status {
        case "Binnen referentiegebied":return "Binnen bereik"
        case "Beschrijvend · codecgevoelig":return "Beschrijvend"
        case "Te weinig actieve audio":return "Te weinig audio"
        case "Onvoldoende referentie":return "Geen referentie"
        default:return b.status
        }
    }
}
