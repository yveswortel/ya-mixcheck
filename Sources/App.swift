import Foundation
import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

private let paper=Color(red:0.86,green:0.89,blue:0.90)
private let panel=Color(red:0.13,green:0.16,blue:0.19)
private let accent=Color(red:0.48,green:0.72,blue:0.80)
private let caution=Color(red:0.89,green:0.65,blue:0.38)

// Shared by every disclosure: the whole header is a keyboard-accessible button.
private struct WideDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        WideDisclosureRow(configuration: configuration)
    }
}
private struct WideDisclosureRow: View {
    let configuration: DisclosureGroupStyleConfiguration
    @State private var hovering = false
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { configuration.isExpanded.toggle() } label: {
                HStack(spacing: 12) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 15, weight: .semibold))
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .frame(width: 22, height: 22)
                        .foregroundStyle(accent)
                        .accessibilityHidden(true)
                    configuration.label
                        .font(.system(size: 14, weight: .medium))
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .background(accent.opacity(hovering || focused ? 0.13 : 0.04), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($focused)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(focused ? accent : .clear, lineWidth: 2).allowsHitTesting(false))
            .onHover { hovering = $0 }
            .accessibilityValue(configuration.isExpanded ? "Uitgeklapt" : "Ingeklapt")
            .accessibilityHint("Toon of verberg de details")
            if configuration.isExpanded {
                configuration.content
                    .padding(.top, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

@MainActor final class Session: ObservableObject {
    @Published var result:Analysis?
    @Published var reference:Analysis?
    @Published var busy=false
    @Published var progress=0.0
    @Published var message=""
    @Published var eqEnabled=false
    @Published var eqPreview:EQPreviewResult?
    @Published var playing=false
    @Published var position=0.0
    @Published var usingReference=false
    @Published var tab="Toonbalans"
    @Published var tonalLoud=false
    @Published var selectedSection = -1
    @Published var manualBounds:[Double]?
    @Published var boundaryText=""
    @Published var genre=UserDefaults.standard.string(forKey:"genre") ?? "Anders/onbekend" {didSet{UserDefaults.standard.set(genre,forKey:"genre")}}
    @Published var purpose=UserDefaults.standard.string(forKey:"purpose") ?? "Release/master" {didSet{UserDefaults.standard.set(purpose,forKey:"purpose")}}
    @Published var comparisonMode="Hele nummer"
    @Published var passageAStart=0.0
    @Published var passageBStart=0.0
    @Published var passageLength=20.0
    @Published var passageA:Analysis?
    @Published var passageB:Analysis?
    @Published var loopEnabled=true
    var passagesReady:Bool {passageA != nil && (reference == nil || passageB != nil)}
    var activeBounds:(Double,Double) {
        if comparisonMode=="Passages",passagesReady,let a=usingReference ? passageB:passageA {
            let start=Double(a.windowStartFrame)/a.sampleRate;return (start,start+a.duration)
        }
        return (0,active?.duration ?? 0)
    }
    var cancellation=Cancellation()
    let queue=DispatchQueue(label:"audio.yves.mixcheck.analysis",qos:.userInitiated)
    var player:AVAudioPlayer?
    var timer:Timer?
    var active:Analysis? {usingReference ? reference:result}
    var playbackGain:Double {
        guard let a=active else{return 0}
        guard let original=result else{return a.previewGainDB}
        let levelsA=comparisonMode=="Passages" ? passageA:result
        let levelsB=comparisonMode=="Passages" ? passageB:reference
        let gains=comparisonGains(original,reference,levelA:levelsA?.integrated,levelB:levelsB?.integrated)
        if !usingReference,let eqPreview {
            let common=min(gains.0,eqPreview.gainDB-eqPreview.matchingDB)
            return common+(eqEnabled ? eqPreview.matchingDB:0)
        }
        return usingReference ? gains.1:gains.0
    }
    func invalidatePassages(){stop();passageA=nil;passageB=nil}
    func markPassageStart(){let time=position;invalidatePassages();if usingReference{passageBStart=time}else{passageAStart=time}}
    func measurePassages(){
        guard !busy,let a=result else{return}
        let b=reference,sa=passageAStart,sb=passageBStart,len=passageLength
        guard len.isFinite,len>=3,len<=120,sa.isFinite,sa>=0,sa+len<=a.duration,
              b==nil || (sb.isFinite && sb>=0 && sb+len<=b!.duration) else{message="Kies 3–120 seconden die volledig binnen A en B vallen.";return}
        let urlA=a.url,urlB=b?.url,hashA=a.sha256,hashB=b?.sha256
        invalidatePassages();busy=true;progress=0;message="";cancellation=Cancellation();let token=cancellation
        queue.async { [weak self] in
            do {
                let pa=try Analyzer.run(urlA,cancellation:token,progress:{p in DispatchQueue.main.async{self?.progress=p*(urlB==nil ? 1:0.5)}},startSeconds:sa,durationSeconds:len,makePreview:false)
                let pb=try urlB.map{url in try Analyzer.run(url,cancellation:token,progress:{p in DispatchQueue.main.async{self?.progress=0.5+p*0.5}},startSeconds:sb,durationSeconds:len,makePreview:false)}
                guard pa.sha256==hashA,pb?.sha256==hashB else{throw QCFailure(message:"Bron gewijzigd; open de bestanden opnieuw.")}
                DispatchQueue.main.async{guard let self else{return};self.passageA=pa;self.passageB=pb;self.comparisonMode="Passages";self.busy=false;self.position=self.activeBounds.0}
            } catch {DispatchQueue.main.async{self?.busy=false;self?.message=error.localizedDescription}}
        }
    }
    func choose(reference:Bool=false){let p=NSOpenPanel();p.allowedContentTypes=[.wav,.aiff,.mp3,UTType(filenameExtension:"flac")!];p.allowsMultipleSelection=false;if p.runModal() == .OK,let u=p.url{load(u,reference:reference)}}
    func load(_ url:URL,reference isRef:Bool=false){
        guard !busy else{return};clearEQ();invalidatePassages();comparisonMode="Hele nummer";usingReference=false;busy=true;progress=0;message="";cancellation=Cancellation();let token=cancellation
        // Clear stale results so a failed file can never play a previously analyzed source.
        if isRef { reference=nil;passageBStart=0 } else { result=nil;reference=nil;usingReference=false;passageAStart=0;passageBStart=0;manualBounds=nil;boundaryText="";selectedSection = -1 }
        queue.async { [weak self] in
            do {let r=try Analyzer.run(url,cancellation:token,progress:{p in DispatchQueue.main.async{self?.progress=p}})
                DispatchQueue.main.async{guard let self else{return};if isRef{self.reference=r}else{self.result=r};self.busy=false;self.position=0}
            }catch{DispatchQueue.main.async{self?.busy=false;self?.message=error.localizedDescription}}
        }
    }
    private var sectionCacheKey=""
    private var sectionCache=[ArrangementSection]()
    private var toneCacheKey=""
    private var toneCache:ToneAssessment?
    var sections:[ArrangementSection] {
        guard let r=result else{return []}
        let key=r.sha256+String(describing:manualBounds)
        if key != sectionCacheKey {sectionCache=arrangement(r.toneSlices,duration:r.duration,manual:manualBounds);sectionCacheKey=key}
        return sectionCache
    }
    private var referenceSectionKey=""
    private var referenceSectionCache=[ArrangementSection]()
    var displayedSections:[ArrangementSection] {
        guard usingReference,let ref=reference else{return sections}
        if referenceSectionKey != ref.sha256 {referenceSectionCache=arrangement(ref.toneSlices,duration:ref.duration);referenceSectionKey=ref.sha256}
        return referenceSectionCache
    }
    var toneReview:ToneAssessment {
        let key=(result?.sha256 ?? "")+genre+String(tonalLoud)+String(selectedSection)+String(describing:manualBounds)
        if key != toneCacheKey || toneCache==nil {toneCache=assessTone(selectedToneSlices,genre:genre,hash:result?.sha256 ?? "",loud:tonalLoud,quiet:sections.first(where:{$0.id==selectedSection})?.label=="Rustiger");toneCacheKey=key}
        return toneCache!
    }
    private var engineerKey=""
    private var engineerDynamics:TrackDynamics?
    private var engineerAdvice=[ListeningAdvice]()
    private var recommendationCache=[MixRecommendation]()
    func refreshEngineer(){
        guard let result else{return}
        let key=result.sha256+genre+purpose+String(describing:manualBounds)
        if key != engineerKey {
            engineerDynamics=trackDynamics(result,genre:genre)
            recommendationCache=mixRecommendations(result,genre:genre,purpose:purpose)
            engineerAdvice=listeningAdvice(result,sections:sections,genre:genre,purpose:purpose)
            engineerKey=key
        }
    }
    var dynamicsReview:TrackDynamics?{refreshEngineer();return engineerDynamics}
    var recommendations:[MixRecommendation]{refreshEngineer();return recommendationCache}
    var listeningReview:[ListeningAdvice]{refreshEngineer();return engineerAdvice}
    var selectedToneSlices:[ToneSlice] {guard let r=result else{return []};guard let section=sections.first(where:{$0.id==selectedSection}) else{return r.toneSlices};return r.toneSlices.filter{$0.center>=section.start && $0.center<section.end}}
    func applyBoundaries(){
        guard let r=result else{return}
        let parts=boundaryText.split(whereSeparator:{$0==";" || $0==" "})
        let values=parts.compactMap{Double($0.replacingOccurrences(of:",",with:"."))}
        guard values.count==parts.count,values.allSatisfy({$0.isFinite && $0>0 && $0<r.duration}),values==values.sorted(),Set(values).count==values.count else{message="Vul oplopende grensseconden in, gescheiden door puntkomma's, binnen de track.";return}
        let all=[0.0]+values+[r.duration]
        guard zip(all,all.dropFirst()).allSatisfy({$1-$0>=4}) else{message="Elke handmatige passage moet minimaal 4 seconden duren.";return}
        manualBounds=values;selectedSection = -1;message=""
    }
    func cleanup(){cancellation.cancel();stop();eqPreview?.remove();result?.decodedAudio?.remove();reference?.decodedAudio?.remove()}
    func stop(){player?.stop();player=nil;playing=false;timer?.invalidate();timer=nil}
    func play(){
        if playing{position=player?.currentTime ?? position;stop();return}
        guard let r=active else{return}
        guard comparisonMode != "Passages" || passagesReady else{message="Meet eerst de gekozen passages voor een gelijkgetrokken vergelijking.";return}
        guard r.sourceIsUnchanged() else{message="Het bronbestand is gewijzigd. Analyseer het opnieuw vóór playback.";return}
        do{let p=try AVAudioPlayer(contentsOf:eqEnabled && !usingReference ? (eqPreview?.url ?? r.playbackURL):r.playbackURL);p.volume=Float(pow(10,playbackGain/20));let bounds=activeBounds;p.currentTime=position>=bounds.0 && position<bounds.1 ? position:bounds.0;p.prepareToPlay();guard p.play() else{throw QCFailure(message:"Playback kon niet starten.")};player=p;playing=true
            timer=Timer.scheduledTimer(withTimeInterval:0.03,repeats:true){[weak self] _ in Task{@MainActor in guard let self,let p=self.player else{return};let bounds=self.activeBounds
                if self.comparisonMode=="Passages",p.currentTime>=bounds.1 || !p.isPlaying {
                    if self.loopEnabled {p.currentTime=bounds.0;p.play()} else{self.position=bounds.1;self.stop();return}
                }
                self.position=p.currentTime;if !p.isPlaying{self.stop()}}}
        }catch{message=error.localizedDescription}
    }
    func seek(_ time:Double){position=max(0,min(time,active?.duration ?? 0));player?.currentTime=position}
    func switchSource(){
        let resume=playing,offset=max(0,position-activeBounds.0);stop();usingReference.toggle()
        let bounds=activeBounds;position=min(bounds.0+offset,max(bounds.0,bounds.1-0.05));if resume{play()}
    }
    func clearEQ(){stop();eqEnabled=false;eqPreview?.remove();eqPreview=nil}
    func toggleEQ(){
        if eqPreview != nil {let resume=playing;position=player?.currentTime ?? position;stop();eqEnabled.toggle();if resume{play()};return}
        guard !busy,let r=result else{return}
        let bands=previewBands(toneReview),source=PreviewSource(r)
        guard !bands.isEmpty else{message="Geen correctie nodig of onvoldoende genregegevens voor een EQ-preview.";return}
        stop();usingReference=false;comparisonMode="Hele nummer";busy=true;progress=0;message="EQ-preview voorbereiden…";cancellation=Cancellation();let token=cancellation
        queue.async{[weak self] in
            do{let preview=try renderEQPreview(source,bands:bands,cancellation:token,progress:{p in DispatchQueue.main.async{self?.progress=p}})
                DispatchQueue.main.async{guard let self else{preview.remove();return};self.eqPreview=preview;self.eqEnabled=true;self.busy=false;self.message=""}
            }catch{DispatchQueue.main.async{self?.busy=false;self?.message=error.localizedDescription}}
        }
    }
    func report(){guard let r=result else{return};let p=NSSavePanel();p.nameFieldStringValue=r.url.deletingPathExtension().lastPathComponent+"-mixcheck.json";p.allowedContentTypes=[.json];if p.runModal() == .OK,let u=p.url{do{guard !FileManager.default.fileExists(atPath:u.path) else{throw QCFailure(message:"Kies een nieuwe bestandsnaam. Bestaande bestanden worden niet overschreven.")};try r.json(purpose:purpose,genre:genre,manualBounds:manualBounds).write(to:u,options:.atomic)}catch{message=error.localizedDescription}}}
}
struct MainView:View {
    @ObservedObject var s:Session
    @State private var drop=false
    var body:some View {
        VStack(alignment:.leading,spacing:0){
            HStack(alignment:.center){
                VStack(alignment:.leading,spacing:3){Text("YA / MixCheck").font(.system(size:25,weight:.semibold,design:.rounded));Text("Luisteren met meetbare context").font(.system(size:12)).foregroundStyle(.secondary)}
                Spacer()
                Text("0.5.0 • Onderzoeksbuild").font(.system(size:12)).foregroundStyle(caution)
                Button("Open audio…"){s.choose()}.keyboardShortcut("o").disabled(s.busy)
            }.padding(24)
            Divider()
            HStack(spacing:22){Picker("Genre",selection:$s.genre){ForEach(["Trap/hiphop","EDM/house","Alternative/indie","Pop/R&B","Anders/onbekend"],id:\.self){Text($0).tag($0)}}.frame(width:280)
                Picker("Doel",selection:$s.purpose){ForEach(["Release/master","Mix voor mastering"],id:\.self){Text($0).tag($0)}}.frame(width:300)
                Spacer()
                Button("Bewaar rapport…"){s.report()}.disabled(s.result==nil || s.busy)
            }.padding(.horizontal,24).padding(.vertical,14).disabled(s.busy)
            if s.busy {
                VStack(alignment:.leading,spacing:16){Text("Bestand analyseren…").font(.title2);ProgressView(value:s.progress);HStack{Text("\(Int(s.progress*100))% • bron blijft ongewijzigd").foregroundStyle(.secondary);Spacer();Button("Annuleren"){s.cancellation.cancel()}}}.padding(40)
                Spacer()
            }else if let r=s.result {
                ScrollView{VStack(alignment:.leading,spacing:20){
                    HStack{VStack(alignment:.leading,spacing:6){Text(r.url.lastPathComponent).font(.system(size:21,weight:.medium));Text("\(Int(r.sampleRate)) Hz   /   \(r.channels==2 ? "Stereo":"Mono")   /   \(r.codec.hasPrefix("MP3") ? "MP3 → float32" : "\(r.bitDepth)-bit\(r.floatingPoint ? " float":"")")   /   \(clock(r.duration))").font(.system(size:12)).foregroundStyle(.secondary)};Spacer();Button(s.reference==nil ? "Referentie toevoegen…":"Referentie vervangen…"){s.choose(reference:true)}}
                    if let ref=s.reference{Text("Referentie B: \(ref.url.lastPathComponent)").font(.system(size:12)).foregroundStyle(.secondary)}
                    VStack(alignment:.leading,spacing:2){waveform(r);sectionStrip(r)}
                    HStack{Button(s.playing ? "Pauze":"Afspelen"){s.play()}.keyboardShortcut(.space,modifiers:[])
                        Text(clock(s.position)).monospacedDigit();Spacer()
                        if s.reference != nil{Button(s.usingReference ? "B · Referentie":"A · Jouw bestand"){s.switchSource()}}
                        if s.eqPreview != nil,!s.usingReference {Button(s.eqEnabled ? "EQ-preview aan":"Origineel"){s.toggleEQ()}}
                        Text("Luistergain \(display(s.playbackGain)) dB").foregroundStyle(.secondary).font(.system(size:12))
                    }
                    HStack{Text("Metingen: A").font(.caption).foregroundStyle(.secondary);Spacer();HelpButton("Afspelen & markeringen"){Text("A/B gebruikt het hele nummer of apart gemeten passages, met loudnessmatching en preview-headroom. De selectie bepaalt welke loudnessmeting wordt gebruikt. Meetwaarden blijven van A. Blauw/paarse streep onder de waveform: secties, geen kwaliteitsoordeel. Dunne markeringen onderin: oranje = begrenzingsaanwijzingen; rood = sample-overrange. Geel bovenaan: mogelijke kliks of stiltes.")}}
                    HStack{metric("Luidheid",display(r.integrated),"LUFS-I");metric(r.sampleRate>=192000 ? "Sample peak":"True peak",display(r.truePeakEstimate),r.sampleRate>=192000 ? "dBFS":"dBTP");metric("LRA",display(r.lra),"LU")}.padding(16).background(panel,in:RoundedRectangle(cornerRadius:8))
                    ListeningPanel(s:s,r:r)
                    Picker("Analyse",selection:$s.tab){ForEach(["Toonbalans","Niveau","Stereo","Bestandscontrole"],id:\.self){Text($0).tag($0)}}.pickerStyle(.segmented)
                    Group{switch s.tab{case "Toonbalans":VStack(alignment:.leading,spacing:16){TonalPanel(s:s,r:r);DisclosureGroup("Gemiddeld spectrum · ruwe meetgegevens"){spectrum(r)}};case "Stereo":stereo(r);case "Bestandscontrole":details(r);default:levels(r)}}.padding(22).frame(maxWidth:.infinity,alignment:.leading).background(panel,in:RoundedRectangle(cornerRadius:10))
                    DynamicsPanel(s:s,r:r)
                    ArrangementPanel(s:s)
                    DisclosureGroup("Technische checks"){findings(r).padding(.top,10)}
                    DisclosureGroup("Referentie vergelijken"){comparisonPanel.padding(.top,10)}
                    HelpButton("Meetmethode & referenties") {
                        VStack(alignment:.leading,spacing:10){
                            Text("Officiële conformancetests nog niet voltooid. Genreprofielen zijn voorlopige referentiegebieden, geen kwaliteitscijfer.")
                            Text(genreNote)
                            Text(s.toneReview.limitation)
                            ForEach(s.toneReview.referenceTitles,id:\.self){Text("• "+$0)}
                            Divider()
                            ForEach(r.limitations,id:\.self){Text($0)}
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(24)}
            }else{
                Spacer()
                VStack(spacing:20){Image(systemName:"waveform.path").font(.system(size:60,weight:.ultraLight)).foregroundStyle(accent);Text("Leg je mix onder de loep.").font(.system(size:30,weight:.medium,design:.rounded));Text("Sleep een WAV, AIFF, FLAC of MP3 hierheen.\nJe krijgt meetwaarden en controleerbare aandachtspunten.").multilineTextAlignment(.center).foregroundStyle(.secondary);Button("Kies een audiobestand…"){s.choose()}.controlSize(.large);Text("Lokaal op je Mac • Geen uploads • Geen automatische correcties").font(.system(size:11)).foregroundStyle(.secondary)}.frame(maxWidth:.infinity)
                Spacer()
            }
            if !s.message.isEmpty {Text(s.message).foregroundStyle(caution).padding(16).frame(maxWidth:.infinity,alignment:.leading).background(panel)}
            Divider();HStack{Text("Diagnose, geen mastering.");Spacer();Text("Lokaal op je Mac")}.font(.system(size:11)).foregroundStyle(.secondary).padding(.horizontal,24).padding(.vertical,12)
        }.frame(minWidth:940,minHeight:740).foregroundStyle(paper).background(Color(red:0.09,green:0.115,blue:0.14)).tint(accent).preferredColorScheme(.dark)
        .onChange(of:s.genre){_,_ in s.clearEQ()}
        .onChange(of:s.selectedSection){_,_ in s.clearEQ()}
        .onChange(of:s.tonalLoud){_,_ in s.clearEQ()}
        .onChange(of:s.comparisonMode){_,mode in if mode=="Passages"{s.clearEQ()}}
        .onChange(of:s.manualBounds){_,_ in s.clearEQ()}
        .disclosureGroupStyle(WideDisclosureStyle())
        .overlay{if drop{RoundedRectangle(cornerRadius:12).stroke(accent,lineWidth:3).padding(5).allowsHitTesting(false)}}
        .onDrop(of:[UTType.fileURL.identifier],isTargeted:$drop){providers in guard !s.busy,let p=providers.first else{return false};_ = p.loadObject(ofClass:URL.self){url,_ in if let url{DispatchQueue.main.async{s.load(url)}}};return true}
    }
    var genreNote:String {switch s.genre{case "Trap/hiphop":return "Luisterfocus: subenergie, sustain en punch.";case "EDM/house":return "Luisterfocus: dropcontrast en mono-impact van het laag.";case "Alternative/indie":return "Luisterfocus: arrangement, ruimte en bewuste textuur.";case "Pop/R&B":return "Luisterfocus: zangcontext, laagbalans en sectiecontrast.";default:return "De metingen zijn onafhankelijk van genre."}}
    func clock(_ seconds:Double)->String{String(format:"%d:%02d",Int(seconds)/60,Int(seconds)%60)}
    func metric(_ title:String,_ value:String,_ unit:String)->some View{VStack(alignment:.leading,spacing:9){Text(title).font(.system(size:12)).foregroundStyle(.secondary);HStack(alignment:.firstTextBaseline,spacing:5){Text(value).font(.system(size:31,weight:.light,design:.rounded)).monospacedDigit();Text(unit).font(.system(size:11)).foregroundStyle(.secondary)}}.frame(maxWidth:.infinity,alignment:.leading)}
    func sectionStrip(_ r:Analysis)->some View {
        let a=s.active ?? r
        let sections=s.displayedSections
        return VStack(alignment:.leading,spacing:6){
            GeometryReader{geo in
                HStack(spacing:0){
                    ForEach(sections){section in
                        let width=max(0,(section.end-section.start)/max(a.duration,0.001)*geo.size.width)
                        Button {
                            s.stop();s.comparisonMode="Hele nummer"
                            if !s.usingReference{s.selectedSection=section.id}
                            s.seek(section.start)
                        } label:{
                            Rectangle()
                            .fill(section.id.isMultiple(of:2) ? Color(red:0.22,green:0.40,blue:0.52):Color(red:0.43,green:0.34,blue:0.54))
                            .frame(width:width,height:6)
                            .frame(height:14)
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        .help("Sectie \(section.id+1): \(clock(section.start))–\(clock(section.end)) · \(section.label). Klik om naar het begin te gaan.")
                        .accessibilityLabel("Sectie \(section.id+1), \(clock(section.start)) tot \(clock(section.end)), \(section.label)")
                    }
                }
            }.frame(height:14).clipped()
        }
    }
    func waveform(_ r:Analysis)->some View {
        let a=s.active ?? r
        return Canvas{ctx,size in
            let mid=size.height/2;var path=Path();let ceiling=max(1,Double(a.waveform.max() ?? 1))
            for i in 0..<min(Int(size.width),a.waveform.count){let j=i*a.waveform.count/max(1,Int(size.width));let end=min(a.waveform.count,max(j+1,(i+1)*a.waveform.count/max(1,Int(size.width))));let peak=a.waveform[j..<end].max() ?? 0;let h=Double(peak)/ceiling*(mid-10);path.move(to:CGPoint(x:Double(i),y:mid-h));path.addLine(to:CGPoint(x:Double(i),y:mid+h))}
            ctx.stroke(path,with:.color(accent.opacity(0.8)),lineWidth:1)
            let bins=a.clipping.plateauTimeline.count
            for b in 0..<bins {
                let x=Double(b)/Double(bins)*size.width, width=size.width/Double(bins)
                // Exact bin frame count (bins can be empty for very short files).
                let first=(Int64(b)*a.frames+Int64(bins)-1)/Int64(bins)
                let end=(Int64(b+1)*a.frames+Int64(bins)-1)/Int64(bins)
                let denominator=Double(max(1,(end-first)*Int64(a.channels)))
                let evidence=max(a.clipping.plateauTimeline[b],a.clipping.railTimeline[b])
                if evidence>0 {
                    let density=min(1,Double(evidence)/denominator)
                    ctx.fill(Path(CGRect(x:x,y:size.height-8,width:width,height:8)),with:.color(caution.opacity(0.4+0.6*sqrt(density))))
                }
                if a.clipping.overrangeTimeline[b]>0 {
                    ctx.fill(Path(CGRect(x:x,y:size.height-16,width:max(1,width),height:7)),with:.color(.red.opacity(0.85)))
                }
            }
            for event in a.anomalies {
                let x=Double(event.startFrame)/Double(a.frames)*size.width
                let width=max(2,Double(event.endFrame-event.startFrame)/Double(a.frames)*size.width)
                ctx.fill(Path(CGRect(x:x,y:0,width:width,height:6)),with:.color(.yellow.opacity(0.85)))
            }
            if s.comparisonMode=="Passages",s.passagesReady {
                let bounds=s.activeBounds
                ctx.fill(Path(CGRect(x:bounds.0/a.duration*size.width,y:0,width:(bounds.1-bounds.0)/a.duration*size.width,height:size.height)),with:.color(.white.opacity(0.10)))
            }
            let x=s.position/a.duration*size.width;var cursor=Path();cursor.move(to:CGPoint(x:x,y:0));cursor.addLine(to:CGPoint(x:x,y:size.height));ctx.stroke(cursor,with:.color(.white),lineWidth:1)
        }.frame(height:130).background(panel,in:RoundedRectangle(cornerRadius:8)).overlay{GeometryReader{geo in Color.clear.contentShape(Rectangle()).gesture(DragGesture(minimumDistance:0).onChanged{s.seek($0.location.x/geo.size.width*a.duration)})}}.accessibilityLabel("Waveform. Klik om een tijdstip te kiezen.")
    }
    @ViewBuilder func findings(_ r:Analysis)->some View {
        VStack(alignment:.leading,spacing:14){
            if r.secondOpinion(purpose:s.purpose).allSatisfy({$0.category=="Context, geen fout"}) {Text("Geen prioritaire melding uit de huidige checks. Dit is geen volledige kwaliteitsbeoordeling.").font(.system(size:12)).foregroundStyle(.secondary)}
            if !r.anomalies.isEmpty {
                DisclosureGroup("Kliks en stiltes · luisterpunten (\(r.anomalies.count))") {
                    ForEach(r.anomalies){event in
                        Button("\(clock(Double(event.startFrame)/r.sampleRate)) · \(event.kind=="click" ? "Mogelijke klik":"Abrupte stilte") · kanaal \(event.channel+1)") {
                            s.stop();s.comparisonMode="Hele nummer";s.usingReference=false;s.seek(max(0,Double(event.startFrame)/r.sampleRate-1))
                        }
                    }
                }
            }
            DisclosureGroup("Niveau en laag in context") {
                ForEach(r.secondOpinion(purpose:s.purpose).filter{$0.category=="Context, geen fout"}){item in
                    VStack(alignment:.leading,spacing:4){Text(item.title).bold();Text(item.evidence);Text(item.action)}.font(.system(size:12)).padding(.vertical,6)
                }
            }

            ForEach(Array(r.secondOpinion(purpose:s.purpose).filter{$0.category != "Context, geen fout"})){item in
                VStack(alignment:.leading,spacing:6){
                    Text(item.category.uppercased()).font(.system(size:10,weight:.semibold)).foregroundStyle(item.category=="Technisch aandachtspunt" ? caution:accent)
                    Text(item.title).font(.system(size:14,weight:.semibold))
                    Text(item.evidence).foregroundStyle(.secondary)
                    Text(item.action)
                    if let frame=item.startFrame{Button("Beluister bij \(clock(Double(frame)/r.sampleRate))"){s.stop();s.comparisonMode="Hele nummer";if s.usingReference{s.switchSource()};s.seek(max(0,Double(frame)/r.sampleRate-1));s.play()}}
                }.font(.system(size:12)).padding(14).frame(maxWidth:.infinity,alignment:.leading).background(panel,in:RoundedRectangle(cornerRadius:8))
            }
        }
    }
    var comparisonPanel:some View {
        VStack(alignment:.leading,spacing:12){
            Picker("Vergelijking",selection:Binding(get:{s.comparisonMode},set:{s.stop();s.comparisonMode=$0;s.position=s.activeBounds.0})){Text("Hele nummer").tag("Hele nummer");Text("Passages").tag("Passages")}.pickerStyle(.segmented)
            HStack(alignment:.top,spacing:24){
                VStack(alignment:.leading,spacing:8){Text("A · Jouw bestand").bold();Text(s.result?.url.lastPathComponent ?? "—").lineLimit(2).foregroundStyle(.secondary)}
                    .frame(maxWidth:.infinity,alignment:.leading)
                VStack(alignment:.leading,spacing:8){Text("B · Referentie").bold();Text(s.reference?.url.lastPathComponent ?? "Nog geen referentie gekozen").lineLimit(2).foregroundStyle(.secondary)
                    Button(s.reference==nil ? "Kies referentie…":"Vervang…"){s.choose(reference:true)}
                }.frame(maxWidth:.infinity,alignment:.leading)
            }.font(.system(size:13)).padding(.vertical,8)
            Group { if s.comparisonMode=="Passages" {
                Grid(alignment:.leading,horizontalSpacing:18,verticalSpacing:12){
                    GridRow{Text("Start A");TextField("Seconden",value:$s.passageAStart,format:.number.precision(.fractionLength(1))).frame(width:90);Text("seconden")}
                    if s.reference != nil {GridRow{Text("Start B");TextField("Seconden",value:$s.passageBStart,format:.number.precision(.fractionLength(1))).frame(width:90);Text("seconden")}}
                    GridRow{Text("Duur");TextField("Seconden",value:$s.passageLength,format:.number.precision(.fractionLength(1))).frame(width:90);Text("3–120 seconden")}
                }.font(.system(size:13))
                HStack(spacing:12){Button("Start bij cursor"){s.markPassageStart()};Button("Meet passages"){s.measurePassages()}}
            }}
            .onChange(of:s.passageAStart){_,_ in s.invalidatePassages()}
            .onChange(of:s.passageBStart){_,_ in s.invalidatePassages()}
            .onChange(of:s.passageLength){_,_ in s.invalidatePassages()}
            if s.comparisonMode=="Passages" {
                Toggle("Herhaal passage",isOn:$s.loopEnabled).font(.system(size:12))
                if let a=s.passageA {
                    Text("Passage A: \(display(a.integrated)) LUFS-I" + (s.passageB.map{"   /   B: \(display($0.integrated)) LUFS-I"} ?? "")).font(.system(size:12))
                    if let b=s.passageB {
                        let delta=relativeLowBands(a,b)
                        Text("A tegenover B bij gelijk passage-niveau: 20–60 Hz \(display(delta[1])) dB · 60–120 Hz \(display(delta[2])) dB · 120–250 Hz \(display(delta[3])) dB").font(.system(size:12)).foregroundStyle(accent)
                        Text("Positief = meer energie in A. Beschrijvende vergelijking, geen EQ-advies; kleine verschillen kunnen door codec, samplerate en vensterkeuze ontstaan.").font(.system(size:11)).foregroundStyle(.secondary)
                    }
                } else {Text("Kies bijvoorbeeld een refrein of drop in A en B, en meet beide passages.").font(.system(size:12)).foregroundStyle(.secondary)}
            }
            Text("Vergelijk een mix met dezelfde versie of een passende referentie. Een cover, video-edit of andere master is geen codeccontrole. Herhalen gebruikt de afspeeltimer en is niet sample-exact/gapless.").font(.system(size:11)).foregroundStyle(.secondary)
        }.padding(16).background(panel,in:RoundedRectangle(cornerRadius:8))
    }
    func levels(_ r:Analysis)->some View {
        VStack(alignment:.leading,spacing:20){
            HStack{Text("Niveaudetails").font(.headline);Spacer();HelpButton("Niveau-uitleg"){
                Text("LUFS beschrijft luidheid, geen kwaliteit. LRA beschrijft variatie tussen passages; korte bestanden zijn minder representatief. PLR is true peak minus integrated; vanaf 192 kHz gebruikt de meter samplepeak zonder interpolatie. Een premaster heeft geen verplicht release-LUFS-doel. Officiële conformancetests zijn nog niet voltooid.")
            }}
            HStack{metric("Sample peak",display(r.samplePeak),"dBFS");metric("PLR",display(r.plr),"dB")}
            HStack{metric("Momentary max",display(r.momentaryMax),"LUFS");metric("Short-term max",display(r.shortTermMax),"LUFS")}
        }
    }
    func safetyColor(_ level:MeterSafety)->Color {
        switch level {case .green:return Color(red:0.42,green:0.83,blue:0.57);case .orange:return caution;case .red:return Color(red:1,green:0.39,blue:0.43);case .unavailable:return .gray}
    }
    func safetyMetric(_ name:String,_ value:String,_ unit:String,_ verdict:MeterVerdict)->some View {
        VStack(alignment:.leading,spacing:10){
            Text(name).font(.system(size:13,weight:.medium)).foregroundStyle(.secondary)
            HStack(alignment:.firstTextBaseline,spacing:6){Text(value).font(.system(size:32,weight:.semibold)).monospacedDigit();Text(unit).font(.system(size:13))}.foregroundStyle(safetyColor(verdict.level))

        }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading).padding(16).background(panel,in:RoundedRectangle(cornerRadius:8)).help(verdict.explanation)
    }
    func stereo(_ r:Analysis)->some View {
        let verdicts=r.stereoAssessment
        return VStack(alignment:.leading,spacing:18){
            Text("Stereo & mono-compatibiliteit").font(.headline)
            HStack(alignment:.top,spacing:16){
                safetyMetric("Correlatie",display(r.correlation,3),"",verdicts["correlation"]!)
                safetyMetric("Mono-energie",r.completeMonoCancellation ? "−∞":display(r.monoLoss,2),"dB",verdicts["monoEnergy"]!)
            }
            safetyMetric("Kanaalbalans · L − R",display(r.channelBalanceDB),"dB",verdicts["channelBalance"]!)
            HStack(spacing:18){Label("Groen · geen alarmsignaal",systemImage:"circle.fill").foregroundStyle(safetyColor(.green));Label("Oranje · luistercontrole",systemImage:"circle.fill").foregroundStyle(safetyColor(.orange));Label("Rood · sterk technisch risico",systemImage:"circle.fill").foregroundStyle(safetyColor(.red))}.font(.system(size:11))
            Divider()
            Text("Crest · dynamiek, geen stereoscore").font(.headline)
            HStack(alignment:.top,spacing:16){
                safetyMetric(r.channels==1 ? "Crest mono":"Crest L",display(r.crest.first ?? nil),"dB",verdicts["crestL"]!)
                if r.channels==2{safetyMetric("Crest R",display(r.crest.count>1 ? r.crest[1]:nil),"dB",verdicts["crestR"]!)}
            }
            HelpButton("Stereo-uitleg"){
                Text("Kanaalbalans: positief = links sterker. Kleuren zijn luisterhints, geen kwaliteitsscore. Correlatie: groen vanaf 0; negatief is oranje. Rood alleen bij ≤ −0,5 én mono-energie ≤ −6,02 dB. Mono-energie: groen vanaf −3,01 dB; oranje tot −6,02 dB; daaronder rood. Formule: 10 log₁₀[2E((L+R)/2)/(E(L)+E(R))]. Kanaalbalans: oranje vanaf 6 dB RMS-verschil, rood vanaf 30 dB of één stil kanaal; alleen bij minstens één seconde en een actief kanaal boven −60 dBFS. Globale maat, geen lokale uitvaldetectie. Dit zijn praktische triagegrenzen, geen industrienorm. Crest: samplepiek minus ongewogen RMS over het hele bestand, zonder AES17-offset; een sinus meet 3,01 dB. Onder 6 dB is een voorzichtige luisterhint, nooit op zichzelf rood. Geen bovengrens: pauzes en losse pieken verhogen deze globale maat. Ontbrekende metingen blijven grijs.").font(.system(size:12)).foregroundStyle(.secondary).padding(.top,10)
            }
        }
    }
    func spectrum(_ r:Analysis)->some View{VStack(alignment:.leading,spacing:14){Text("Gemiddeld spectrum").font(.headline);Text("Energie per Hz • A: blauw • referentie: zandkleur, bij gelijk integrated niveau").font(.system(size:12)).foregroundStyle(.secondary)
        Canvas{ctx,size in
            for level in stride(from:-100,through:-20,by:20){let y=Double(-20-level)/100*size.height;var p=Path();p.move(to:CGPoint(x:0,y:y));p.addLine(to:CGPoint(x:size.width,y:y));ctx.stroke(p,with:.color(.white.opacity(0.08)),lineWidth:1);ctx.draw(Text("\(level)").font(.system(size:9)).foregroundColor(.gray),at:CGPoint(x:12,y:y+7))}
            func draw(_ points:[SpectrumPoint],gain:Double,color:Color){var p=Path();var active=false;for point in points{guard let db=point.db else{active=false;continue};let x=log10(point.hz/20)/3*size.width,y=max(0,min(size.height,(-20-db-gain)/100*size.height));if active{p.addLine(to:CGPoint(x:x,y:y))}else{p.move(to:CGPoint(x:x,y:y));active=true}};ctx.stroke(p,with:.color(color),lineWidth:1.7)}
            draw(r.spectrum,gain:0,color:accent)
            if let ref=s.reference,let a=r.integrated,let b=ref.integrated{draw(ref.spectrum,gain:a-b,color:caution)}
        }.frame(height:180)
        Canvas { ctx,size in
            for (hz,label) in [(20.0,"20 Hz"),(100.0,"100"),(1000.0,"1k"),(10000.0,"10k"),(20000.0,"20k")] {
                let x=log10(hz/20.0)/3.0*size.width
                let anchor:UnitPoint = hz==20 ? .topLeading:(hz==20000 ? .topTrailing:.top)
                ctx.draw(Text(label).font(.system(size:11)).foregroundColor(.gray),at:CGPoint(x:x,y:0),anchor:anchor)
            }
        }.frame(height:16)
        Divider();HStack{ForEach(0..<5,id:\.self){i in VStack(alignment:.leading){Text(["<20 Hz","20–60","60–120","120–250","250–500"][i]).font(.system(size:11));Text("\(display(r.lowBandDBFS[i])) dBFS").font(.system(size:12)).foregroundStyle(.secondary)}.frame(maxWidth:.infinity,alignment:.leading)}}
        Text("Laagenergie is beschrijvend. Deze build geeft geen mud-waarschuwing.").font(.system(size:12)).foregroundStyle(.secondary)}}
    func details(_ r:Analysis)->some View{VStack(alignment:.leading,spacing:12){Text("\(r.frames) frames • \(r.codec.hasPrefix("MP3") ? "MP3 → float32" : "\(r.bitDepth)-bit\(r.floatingPoint ? " float":"")") • \(display(r.elapsedSeconds,2)) s analysetijd");Text("Bron-SHA256").foregroundStyle(.secondary);Text(r.sha256).font(.system(size:11,design:.monospaced)).textSelection(.enabled);Text("\(r.incidents.count) overrange- en \(r.clipping.events.count) plateau-intervallen opgeslagen (maximaal 512 per type). De waveform gebruikt de volledige tijdlijn, niet deze begrensde lijst.");Text("JSON-rapport bevat meetdefinities, beperkingen en bronidentiteit. Export naar 24-bit WAV volgt na de exporttests.").foregroundStyle(.secondary)}.font(.system(size:13))}
}
final class AppDelegate:NSObject,NSApplicationDelegate {
    var window:NSWindow?
    var session:Session?
    func applicationWillTerminate(_ notification:Notification){session?.cleanup()}
    @MainActor func applicationDidFinishLaunching(_ notification:Notification){let s=Session();session=s;let w=NSWindow(contentRect:NSRect(x:0,y:0,width:1080,height:840),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false);w.title="YA-MixCheck";w.contentView=NSHostingView(rootView:MainView(s:s));w.center();w.makeKeyAndOrderFront(nil);window=w;NSApp.activate(ignoringOtherApps:true)
        if let p=ProcessInfo.processInfo.environment["YA_MIXCHECK_OPEN"]{s.load(URL(fileURLWithPath:p))}
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool{true}
}
@main struct Entry {
    @MainActor static func main(){
        let args=CommandLine.arguments
        if args.count>1 {
            do {
                if args[1]=="--engineer-test",args.count==4{FileHandle.standardOutput.write(try validateEngineerMusic(URL(fileURLWithPath:args[2]),genre:args[3]));exit(0)}
                if args[1]=="--dynamics",args.count==3 {
                    let a=try Analyzer.run(URL(fileURLWithPath:args[2]),makePreview:false)
                    let data:[String:Any]=["sha256":a.sha256,"modes":try JSONSerialization.jsonObject(with:JSONEncoder().encode(dynamicsModes(a.dynamics)))]
                    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:data,options:[.sortedKeys]));exit(0)
                }
                if args[1]=="--review",args.count==4 {
                    let a=try Analyzer.run(URL(fileURLWithPath:args[2]),makePreview:false);FileHandle.standardOutput.write(try a.json(genre:args[3]));exit(0)
                }
                if args[1]=="--preview-check",args.count==4{FileHandle.standardOutput.write(try validatePreviewFile(URL(fileURLWithPath:args[2]),genre:args[3]));exit(0)}
                if args[1]=="--features",args.count==3 {let r=try analyzeFeatures(URL(fileURLWithPath:args[2]));let e=JSONEncoder();e.outputFormatting=[.sortedKeys];FileHandle.standardOutput.write(try e.encode(r));exit(0)}
                if args[1]=="--assess",args.count==4 {let data=try Data(contentsOf:URL(fileURLWithPath:args[2]));let r=try JSONDecoder().decode(FeatureDocument.self,from:data);let e=JSONEncoder();e.outputFormatting=[.prettyPrinted,.sortedKeys];FileHandle.standardOutput.write(try e.encode(assessTone(r.slices,genre:args[3],hash:r.sha256)));exit(0)}
                if args[1]=="--self-test"{let outcomes=try runValidation();let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys];FileHandle.standardOutput.write(try encoder.encode(outcomes));exit(outcomes.allSatisfy{$0.passed} ? 0:1)}
                if args[1]=="--analyze-region",args.count==5,let start=Double(args[3]),let duration=Double(args[4]){let r=try Analyzer.run(URL(fileURLWithPath:args[2]),startSeconds:start,durationSeconds:duration,makePreview:false);FileHandle.standardOutput.write(try r.json());exit(0)}
                if args[1]=="--analyze",args.count==3{let r=try Analyzer.run(URL(fileURLWithPath:args[2]));FileHandle.standardOutput.write(try r.json());r.decodedAudio?.remove();exit(0)}
                if args[1]=="--demo",args.count==3{let rate=48000;let samples=(0..<rate*8).flatMap{n->[Float] in let t=Double(n)/Double(rate);let env=0.5+0.5*sin(Double.pi*t/8);let v=Float(env*(0.22*sin(2*Double.pi*60*t)+0.08*sin(2*Double.pi*1000*t)));return[v,v]};try writeTestAudio(URL(fileURLWithPath:args[2]),samples:samples,rate:48000,channels:2);exit(0)}
                throw QCFailure(message:"Gebruik --self-test, --analyze <audio> of --demo <nieuw wav-pad>.")
            }catch{FileHandle.standardError.write(Data((error.localizedDescription+"\n").utf8));exit(1)}
        }
        let app=NSApplication.shared;app.setActivationPolicy(.regular)
        let menu=NSMenu(),appItem=NSMenuItem(),appMenu=NSMenu();appMenu.addItem(withTitle:"Stop YA-MixCheck",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q");appItem.submenu=appMenu;menu.addItem(appItem);app.mainMenu=menu
        let delegate=AppDelegate();app.delegate=delegate;app.run();withExtendedLifetime(delegate){}
    }
}
