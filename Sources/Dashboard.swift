import SwiftUI
import AppKit

// The approved overview: one spacing/color system, with details outside the main canvas.
enum DashboardStyle {
    static let background = Color(hex:0x14191e)
    static let panel = Color(hex:0x20272e)
    static let raised = Color(hex:0x28323a)
    static let line = Color(hex:0x36414b)
    static let text = Color(hex:0xedf1f3)
    static let muted = Color(hex:0xa2afb9)
    static let accent = Color(hex:0x9cc6d2)
    static let zone = Color(hex:0x344b58)
    static let amber = Color(hex:0xe5b783)
    static let green = Color(hex:0xa1c6ae)
    static func safety(_ level:MeterSafety)->Color {
        switch level {case .green:return green;case .orange:return amber;case .red:return Color(hex:0xf0787b);case .unavailable:return muted}
    }
}
private extension Color {
    init(hex:UInt32){self.init(red:Double((hex>>16)&255)/255,green:Double((hex>>8)&255)/255,blue:Double(hex&255)/255)}
}
struct DashboardButtonStyle:ButtonStyle {
    var selected=false
    func makeBody(configuration:Configuration)->some View {
        DashboardButtonBody(configuration:configuration,selected:selected)
    }
}
private struct DashboardButtonBody:View {
    let configuration:ButtonStyleConfiguration
    let selected:Bool
    @Environment(\.isEnabled) private var enabled
    @State private var hovered=false
    var body:some View {
        configuration.label.font(.system(size:14,weight:selected ? .semibold:.regular)).lineLimit(1)
            .foregroundStyle(selected ? DashboardStyle.background:DashboardStyle.text)
            .padding(.horizontal,13).frame(height:34)
            .background(selected ? DashboardStyle.accent:DashboardStyle.raised,in:RoundedRectangle(cornerRadius:7))
            .overlay(RoundedRectangle(cornerRadius:7).fill(.white.opacity(configuration.isPressed ? 0.12:hovered ? 0.05:0)).allowsHitTesting(false))
            .opacity(enabled ? 1:0.42).contentShape(Rectangle())
            .onHover{hovered=$0}
    }
}
struct DashboardMenuChoice {
    let title:String
    var selected=false
    let action:()->Void
}
// AppKit owns the entire 34-point menu button; SwiftUI only draws its surface.
// Borderless SwiftUI Menu can collapse its native hit area to the title text.
struct DashboardMenu:View {
    let title:String,width:CGFloat
    var chevron=true
    let choices:[DashboardMenuChoice]
    var accessibilityTitle:String?=nil
    @Environment(\.isEnabled) private var enabled
    var body:some View {
        ZStack {
            RoundedRectangle(cornerRadius:7).fill(DashboardStyle.raised).allowsHitTesting(false)
            HStack(spacing:8){
                Text(title).lineLimit(1)
                if chevron{Spacer(minLength:0);Image(systemName:"chevron.down").font(.system(size:11))}
            }.font(.system(size:14)).foregroundStyle(DashboardStyle.text)
                .padding(.horizontal,10).allowsHitTesting(false).accessibilityHidden(true)
            DashboardNativeMenu(choices:choices,label:accessibilityTitle ?? title)
        }.frame(width:width,height:34).opacity(enabled ? 1:0.42)
    }
}
private struct DashboardNativeMenu:NSViewRepresentable {
    let choices:[DashboardMenuChoice],label:String
    @Environment(\.isEnabled) private var enabled
    final class Coordinator:NSObject {
        var choices=[DashboardMenuChoice]()
        @objc func choose(_ item:NSMenuItem){guard choices.indices.contains(item.tag) else{return};choices[item.tag].action()}
    }
    func makeCoordinator()->Coordinator {Coordinator()}
    func makeNSView(context:Context)->NSPopUpButton {
        let button=NSPopUpButton(frame:.zero,pullsDown:true)
        button.isBordered=false;button.isTransparent=true
        (button.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        button.focusRingType = .exterior
        button.setContentHuggingPriority(.defaultLow,for:.horizontal)
        button.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        return button
    }
    func updateNSView(_ button:NSPopUpButton,context:Context) {
        context.coordinator.choices=choices
        let menu=NSMenu();menu.autoenablesItems=false
        menu.addItem(NSMenuItem(title:"",action:nil,keyEquivalent:""))
        for (index,choice) in choices.enumerated() {
            let item=NSMenuItem(title:choice.title,action:#selector(Coordinator.choose(_:)),keyEquivalent:"")
            item.target=context.coordinator;item.tag=index;item.state=choice.selected ? .on:.off
            menu.addItem(item)
        }
        button.menu=menu;button.isEnabled=enabled;button.setAccessibilityLabel(label)
    }
}
struct DashboardCard<Content:View>:View {
    let content:Content
    init(@ViewBuilder content:()->Content){self.content=content()}
    var body:some View {
        content.padding(20).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
            .background(DashboardStyle.panel,in:RoundedRectangle(cornerRadius:10))
    }
}
struct DashboardTitle:View {
    let title:String
    let action:()->Void
    var body:some View {
        Button(action:action){HStack(spacing:7){Text(title).font(.system(size:19,weight:.semibold));Image(systemName:"chevron.right").font(.system(size:10,weight:.semibold)).foregroundStyle(DashboardStyle.muted)}
            .frame(minHeight:24,alignment:.leading).contentShape(Rectangle())}
            .buttonStyle(.plain).help("Open \(title.lowercased()) en details")
    }
}

struct DashboardLoudness:View {
    let value:Double?
    let review:LoudnessReview
    @State private var showAdvice=false
    var body:some View {
        HStack(alignment:.firstTextBaseline,spacing:10){
            Text("Luidheid").font(.system(size:13)).foregroundStyle(DashboardStyle.muted)
            if let advice=review.advice,review.state == .orange {
                Button{showAdvice=true}label:{number.foregroundStyle(DashboardStyle.amber)}.buttonStyle(.plain)
                    .help(advice.title+". "+advice.action)
                    .accessibilityLabel("Luidheid \(display(value)) LUFS. Vrijblijvend niveauadvies")
                    .popover(isPresented:$showAdvice){
                        VStack(alignment:.leading,spacing:12){
                            Text(advice.title).font(.headline)
                            Text(advice.action).font(.system(size:14))
                            Text(advice.evidence).font(.system(size:12)).foregroundStyle(DashboardStyle.muted)
                        }.lineSpacing(3).padding(20).frame(width:380).textSelection(.enabled)
                            .foregroundStyle(DashboardStyle.text).background(DashboardStyle.panel).preferredColorScheme(.dark)
                    }
            }else{number.accessibilityLabel("Luidheid \(display(value)) LUFS")}
            Text("LUFS-I").font(.system(size:12)).foregroundStyle(DashboardStyle.muted)
        }.frame(maxWidth:.infinity,alignment:.leading)
            .onChange(of:review.reason){_,_ in showAdvice=false}
    }
    private var number:some View {Text(display(value)).font(.system(size:29,weight:.semibold)).monospacedDigit().fixedSize()}
}

struct DashboardTone:View {
    let assessment:ToneAssessment
    let selection:String
    let open:()->Void
    var body:some View {
        DashboardCard {
            VStack(alignment:.leading,spacing:16){
                HStack(alignment:.center){DashboardTitle(title:"Toonbalans",action:open);Spacer(minLength:12)
                    HStack(spacing:7){RoundedRectangle(cornerRadius:2).fill(DashboardStyle.zone).frame(width:12,height:10);Text("Genrespreiding").font(.system(size:12)).foregroundStyle(DashboardStyle.muted)}
                }
                DashboardBandChart(assessment:assessment)
                if assessment.referenceCount<5 || assessment.summary.seconds<8 {
                    Text(assessment.referenceCount<5 ? "Onvoldoende genrevoorbeelden voor een vergelijking.":"Te weinig actieve audio voor een vergelijking.")
                        .font(.system(size:12)).foregroundStyle(DashboardStyle.muted)
                }else if selection != "Hele track" {
                    Text(selection).font(.system(size:12)).foregroundStyle(DashboardStyle.accent).lineLimit(1)
                }
            }
        }
    }
}
// One display preference for both charts; changing it never changes the assessment.
struct ToneScaleAxis:View {
    static let preferenceKey="toneChartWideRange"
    @Binding var wideRange:Bool
    var inset:Double=6
    var intermediateTicks=false
    var alignment:Alignment = .leading
    @State private var hovered=false
    private var limit:Double{wideRange ? 12:6}
    var body:some View {
        Button{wideRange.toggle()}label:{
            GeometryReader{g in
                let ticks=intermediateTicks ? [-limit,-limit/2,0,limit/2,limit]:[-limit,0,limit]
                ForEach(ticks,id:\.self){value in
                    Text(value==0 ? "0":String(format:"%+.0f",value)).font(.system(size:12)).monospacedDigit()
                        .foregroundStyle(hovered ? DashboardStyle.accent:DashboardStyle.muted)
                        .frame(width:g.size.width,alignment:alignment)
                        .position(x:g.size.width/2,y:inset+(limit-value)/(limit*2)*max(1,g.size.height-2*inset))
                }
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).onHover{hovered=$0}
            .accessibilityLabel("Toonbalansschaal")
            .accessibilityValue("Min \(Int(limit)) tot plus \(Int(limit)) decibel")
            .accessibilityHint("Wissel naar plus of min \(wideRange ? 6:12) decibel")
            .help("Schaal ±\(Int(limit)) dB. Klik op de getallen om naar ±\(wideRange ? 6:12) dB te wisselen.")
    }
}
struct DashboardBandChart:View {
    let assessment:ToneAssessment
    @AppStorage(ToneScaleAxis.preferenceKey) private var wideRange=false
    private var extent:Double{wideRange ? 12:6}
    var body:some View {
        GeometryReader{geometry in
        VStack(spacing:8){
            HStack(spacing:0){Color.clear.frame(width:32)
                ForEach(assessment.bands){b in Text(b.name).font(.system(size:14)).foregroundStyle(DashboardStyle.muted).frame(maxWidth:.infinity).lineLimit(1)}
            }.frame(height:18)
            Canvas{ctx,size in
                let left=32.0,step=(size.width-left)/7,h=max(1,size.height-12),top=6.0,limit=extent
                func y(_ value:Double)->Double {top+(limit-max(-limit,min(limit,value)))/(limit*2)*h}
                for value in [-limit,0,limit] {
                    var line=Path();line.move(to:CGPoint(x:left,y:y(value)));line.addLine(to:CGPoint(x:size.width,y:y(value)))
                    ctx.stroke(line,with:.color(DashboardStyle.line),lineWidth:1)
                }
                for b in assessment.bands {
                    let x=left+(Double(b.id)+0.5)*step,w=step*0.68
                    if let low=b.lower,let high=b.upper,let median=b.median {
                        let rect=CGRect(x:x-w/2,y:y(high-median),width:w,height:max(3,y(low-median)-y(high-median)))
                        ctx.fill(Path(roundedRect:rect,cornerRadius:4),with:.color(DashboardStyle.zone))
                    }
                    if let delta=b.delta,delta.isFinite {
                        let colour=b.attention ? DashboardStyle.amber:DashboardStyle.text
                        ctx.fill(Path(CGRect(x:x-w/2,y:y(delta)-2.5,width:w,height:5)),with:.color(colour))
                        if abs(delta)>limit {
                            let edge=y(delta),direction=delta>0 ? 1.0:-1.0
                            var arrow=Path();arrow.move(to:CGPoint(x:x-4,y:edge+direction*7));arrow.addLine(to:CGPoint(x:x,y:edge+direction*2));arrow.addLine(to:CGPoint(x:x+4,y:edge+direction*7))
                            ctx.stroke(arrow,with:.color(colour),lineWidth:1.5)
                        }
                    }
                }
            }.frame(height:max(36,geometry.size.height-50)).accessibilityHidden(true)
                .overlay(alignment:.leading){ToneScaleAxis(wideRange:$wideRange).frame(width:32)}
            HStack(spacing:0){Color.clear.frame(width:32)
                ForEach(assessment.bands){b in
                    Text(b.delta.map{String(format:"%+.1f",$0)} ?? "—").font(.system(size:13)).monospacedDigit()
                        .foregroundStyle(DashboardStyle.muted).frame(maxWidth:.infinity)
                        .accessibilityLabel("\(b.name), \(b.range), \(display(b.delta)) decibel tegenover de mediaan. \(b.status)")
                        .help("\(b.range) · \(b.status). Verschil in dB tegenover de mediaan, geen EQ-instelling.")
                }
            }.frame(height:16)
        }
        }
    }
}
struct DashboardDynamics:View {
    let dynamics:TrackDynamics?
    let computing:Bool
    let open:()->Void
    var body:some View {
        DashboardCard {
            VStack(alignment:.leading,spacing:8){
                HStack{DashboardTitle(title:"Dynamics",action:open);Spacer();Text("Hele track").font(.system(size:12)).foregroundStyle(DashboardStyle.muted)}
                if let dynamics {
                    VStack(spacing:6){ForEach(dynamics.metrics){m in DashboardDynamicsMeter(metric:m)}}
                }else{Text(computing ? "Dynamics berekenen…":"Nog geen meetgegevens").font(.system(size:13)).foregroundStyle(DashboardStyle.muted)}
            }
        }
    }
}
private struct DashboardDynamicsMeter:View {
    let metric:DynamicsMetric
    var body:some View {
        VStack(spacing:2){
            HStack{Text(metric.name);Spacer();Text("\(display(metric.value)) dB").fontWeight(.semibold).monospacedDigit()}.font(.system(size:14))
            GeometryReader{g in
                let m=metric
                ZStack(alignment:.leading){
                    Capsule().fill(DashboardStyle.raised).frame(height:8)
                    if let v=m.value,let lo=m.lower,let hi=m.upper,v.isFinite,lo.isFinite,hi.isFinite {
                        let span=max(2,hi-lo),minimum=min(lo-span*0.6,v-span*0.15),maximum=max(hi+span*0.6,v+span*0.15)
                        let width=max(1,g.size.width-4)
                        let x={ (v:Double) in (v-minimum)/(maximum-minimum)*width+2 }
                        Capsule().fill(DashboardStyle.zone).frame(width:max(2,x(hi)-x(lo)),height:8).offset(x:x(lo))
                        Capsule().fill(DashboardStyle.accent).frame(width:4,height:16).offset(x:x(v)-2)
                    }
                }.frame(height:16)
            }.frame(height:16).accessibilityHidden(true)
        }.help("\(metric.label). Referentiegebied: \(display(metric.lower)) tot \(display(metric.upper)) dB. Meer is niet automatisch beter.")
            .accessibilityElement(children:.combine)
    }
}
struct DashboardStereo:View {
    let result:Analysis
    let open:()->Void
    var body:some View {
        let verdicts=result.stereoAssessment
        DashboardCard {
            VStack(alignment:.leading,spacing:14){
                DashboardTitle(title:"Stereo",action:open)
                row("Correlatie",display(result.correlation,2),verdicts["correlation"])
                row("Mono-energie",result.completeMonoCancellation ? "−∞ dB":"\(display(result.monoLoss)) dB",verdicts["monoEnergy"])
                row(result.channels==2 ? "Crest L / R":"Crest",result.channels==2 ? "\(display(result.crest.first ?? nil)) / \(display(result.crest.count>1 ? result.crest[1]:nil))":"\(display(result.crest.first ?? nil)) dB",nil)
                if let v=verdicts["channelBalance"],v.level == .red || v.level == .orange {
                    Button("Kanaalbalans controleren…",action:open).buttonStyle(.plain).font(.system(size:12)).foregroundStyle(DashboardStyle.safety(v.level))
                }
            }
        }
    }
    private func row(_ name:String,_ value:String,_ verdict:MeterVerdict?)->some View {
        HStack(spacing:8){Text(name).foregroundStyle(DashboardStyle.muted);Spacer(minLength:4)
            if let verdict {Circle().fill(DashboardStyle.safety(verdict.level)).frame(width:7,height:7)}
            Text(value).monospacedDigit().fixedSize()
        }.font(.system(size:14)).help(verdict?.explanation ?? "Crest in dB: samplepiek minus RMS; dynamiek, geen stereoscore.")
            .accessibilityElement(children:.ignore).accessibilityLabel("\(name), \(value)").accessibilityValue(verdict?.label ?? "")
    }
}
struct DashboardAdvice:View {
    let advice:[MixRecommendation]
    let computing:Bool
    let open:()->Void
    var body:some View {
        DashboardCard {
            VStack(alignment:.leading,spacing:14){
                Text("Wat verdient aandacht?").font(.system(size:19,weight:.semibold))
                ScrollView {
                    VStack(alignment:.leading,spacing:18){
                        if computing {Text("Adviezen berekenen…").foregroundStyle(DashboardStyle.muted)}
                        else if advice.isEmpty {Text("Geen duidelijk luisterpunt uit deze metingen. Vergelijk vooral balans en groove met je referentie.").foregroundStyle(DashboardStyle.muted).fixedSize(horizontal:false,vertical:true)}
                        ForEach(Array(advice.enumerated()),id:\.element.id){i,a in
                            if i>0 {Rectangle().fill(DashboardStyle.line).frame(height:1)}
                            VStack(alignment:.leading,spacing:8){
                                Text(a.title).font(.system(size:17,weight:.semibold)).fixedSize(horizontal:false,vertical:true)
                                Text(a.action).font(.system(size:15)).foregroundStyle(DashboardStyle.muted).lineSpacing(3).fixedSize(horizontal:false,vertical:true)
                            }
                        }
                    }.frame(maxWidth:.infinity,alignment:.leading).padding(.trailing,4)
                }.scrollIndicators(.automatic)
                Button("Onderbouwing…",action:open).buttonStyle(.plain).font(.system(size:13)).foregroundStyle(DashboardStyle.accent).frame(minHeight:28)
            }
        }
    }
}
struct DashboardTechnical:View {
    let result:Analysis
    let purpose:String
    let listen:(Double)->Void
    let open:()->Void
    var body:some View {
        let items=result.secondOpinion(purpose:purpose).filter{$0.category != "Context, geen fout"}
        let anomaly=result.anomalies.first
        DashboardCard {
            VStack(alignment:.leading,spacing:14){
                DashboardTitle(title:"Technische controle",action:open)
                HStack(alignment:.top,spacing:10){
                    Circle().fill(items.isEmpty && anomaly==nil ? DashboardStyle.muted:DashboardStyle.amber).frame(width:7,height:7).padding(.top,5)
                    Text(anomaly.map{$0.kind=="click" ? "Mogelijke discontinuïteit":"Mogelijke abrupte stilte"} ?? items.first?.title ?? "Geen technische melding")
                        .font(.system(size:14)).lineLimit(2).frame(maxWidth:.infinity,alignment:.leading)
                }
                Spacer(minLength:0)
                HStack(spacing:16){
                    if let anomaly {
                        let time=Double(anomaly.startFrame)/result.sampleRate
                        Button("Beluister \(dashboardTime(time))"){listen(time)}.buttonStyle(DashboardButtonStyle())
                            .help("Origineel vanaf één seconde vóór de markering, zonder EQ-preview.")
                    }
                    Button("Alle controles…",action:open).buttonStyle(.plain).font(.system(size:13)).foregroundStyle(DashboardStyle.muted).frame(minHeight:28)
                    Spacer(minLength:0)
                }
            }
        }
    }
}
func dashboardTime(_ seconds:Double)->String {
    guard seconds.isFinite else{return "—"}
    let t=max(0,Int(seconds));return String(format:"%d:%02d",t/60,t%60)
}
