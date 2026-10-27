import Foundation
import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

private let paper=DashboardStyle.text
private let panel=DashboardStyle.panel
private let accent=DashboardStyle.accent
private let caution=DashboardStyle.amber

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
    @Published var result:Analysis? {didSet{eqPlanCacheKey="";reconcileEQPreview();refreshEngineer()}}
    @Published var reference:Analysis?
    @Published var busy=false
    @Published var progress=0.0
    @Published var message=""
    @Published var eqEnabled=false
    @Published var eqPreview:EQPreviewResult?
    private var eqPreviewKey:EQPreviewKey?
    @Published var playing=false
    @Published private(set) var playbackChecking=false
    @Published private(set) var eqSwitchChecking=false
    @Published var position=0.0
    @Published var usingReference=false
    @Published var tab="Toonbalans"
    @Published var tonalLoud=false
    @Published var selectedSection = -1
    @Published var manualBounds:[Double]? {didSet{refreshEngineer()}}
    @Published var boundaryText=""
    @Published var genre=UserDefaults.standard.string(forKey:"genre") ?? "Anders/onbekend" {didSet{UserDefaults.standard.set(genre,forKey:"genre");if genre != oldValue{reconcileEQPreview()};refreshEngineer()}}
    @Published var purpose=UserDefaults.standard.string(forKey:"purpose") ?? "Release/master" {didSet{UserDefaults.standard.set(purpose,forKey:"purpose");refreshEngineer()}}
    @Published var comparisonMode="Hele nummer" {didSet{
        guard comparisonMode != oldValue else{return}
        stop()
        // Passage A/B uses its own level match. Keep the whole-track EQ render
        // cached, but don't imply it was level-matched to the selected passage.
        if comparisonMode=="Passages"{eqEnabled=false}
    }}
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
    private var playbackCancellation:Cancellation?
    private var eqSwitchCancellation:Cancellation?
    private var eqSwitchTarget:Bool?
    let queue=DispatchQueue(label:"audio.yves.mixcheck.analysis",qos:.userInitiated)
    let transport=PreviewTransport()
    var timer:Timer?
    var active:Analysis? {usingReference ? reference:result}
    var pairedPlaybackGains:(original:Double,preview:Double,reference:Double) {
        guard let original=result else{return (0,0,0)}
        let levelsA=comparisonMode=="Passages" ? passageA:result
        let levelsB=comparisonMode=="Passages" ? passageB:reference
        let gains=comparisonGains(original,reference,levelA:levelsA?.integrated,levelB:levelsB?.integrated)
        if let eqPreview {
            let common=min(gains.0,eqPreview.gainDB-eqPreview.matchingDB,-max(0,eqPreview.matchingDB))
            return (common,common+eqPreview.matchingDB,gains.1+common-gains.0)
        }
        return (gains.0,gains.0,gains.1)
    }
    var playbackGain:Double {let gains=pairedPlaybackGains;return usingReference ? gains.reference:(eqEnabled ? gains.preview:gains.original)}
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
                DispatchQueue.main.async{guard let self,self.cancellation === token else{return};self.busy=false
                    guard (try? token.check()) != nil else{self.message="Analyse geannuleerd.";return}
                    guard self.result?.sha256==hashA,self.reference?.sha256==hashB,self.result?.source==urlA.path,self.reference?.source==urlB?.path,self.passageAStart==sa,self.passageBStart==sb,self.passageLength==len else{return}
                    self.passageA=pa;self.passageB=pb;self.comparisonMode="Passages";self.position=self.activeBounds.0}
            } catch {DispatchQueue.main.async{guard let self,self.cancellation === token else{return};self.busy=false;self.message=error.localizedDescription}}
        }
    }
    func choose(reference:Bool=false){guard !busy else{return};let p=NSOpenPanel();p.allowedContentTypes=[.wav,.aiff,.mp3,UTType(filenameExtension:"flac")!];p.allowsMultipleSelection=false;p.canChooseDirectories=false;if p.runModal() == .OK,let u=p.url{load(u,reference:reference)}}
    func load(_ url:URL,reference isRef:Bool=false){
        guard !busy else{return};if !isRef{clearEQ()};invalidatePassages();comparisonMode="Hele nummer";usingReference=false;busy=true;progress=0;message="";cancellation=Cancellation();let token=cancellation
        // Clear stale results so a failed file can never play a previously analyzed source.
        if isRef { reference=nil;passageBStart=0 } else { result=nil;reference=nil;usingReference=false;passageAStart=0;passageBStart=0;manualBounds=nil;boundaryText="";selectedSection = -1 }
        queue.async { [weak self] in
            do {
                let snapshot=try PreparedInput.prepare(url,cancellation:token,status:{text in DispatchQueue.main.async{self?.message=text}})
                var r=try Analyzer.run(snapshot.url,cancellation:token,progress:{p in DispatchQueue.main.async{self?.progress=p}})
                r.inputSnapshot=snapshot;r.originalSource=url.path;r.modifiedAt=snapshot.receipt.sourceModifiedAt ?? r.modifiedAt;r.byteCount=snapshot.receipt.bytes
                if snapshot.receipt.cloudStatus=="downloaded-or-unknown" {r.limitations.append("Lokale iCloud-versie gemeten; nieuwste cloudversie niet bevestigd.")}
                try token.check()
                DispatchQueue.main.async{guard let self,self.cancellation === token else{return};guard (try? token.check()) != nil else{self.busy=false;self.message="Analyse geannuleerd.";return};if isRef{self.reference=r}else{self.result=r};self.busy=false;self.position=0;self.message=""}
            }catch{DispatchQueue.main.async{guard let self,self.cancellation === token else{return};self.busy=false;self.message=error.localizedDescription}}
        }
    }
    func setReferenceIdentity(_ hash:String) {
        guard !busy,var r=result else{return}
        var overrides=UserDefaults.standard.dictionary(forKey:"referenceIdentityOverrides") as? [String:String] ?? [:]
        if hash=="auto" {overrides.removeValue(forKey:r.sha256)} else {overrides[r.sha256]=hash}
        UserDefaults.standard.set(overrides,forKey:"referenceIdentityOverrides")
        r.referenceIdentity=ReferenceIdentities.shared.resolve(hash:r.sha256,duration:r.duration,slices:r.toneSlices)
        result=r
    }
    private var sectionCacheKey=""
    private var sectionCache=[ArrangementSection]()
    private var toneCacheKey=""
    private var toneCache:ToneAssessment?
    private var eqPlanCacheKey=""
    private var eqPlanCache:EQPreviewPlan?
    var eqPlan:EQPreviewPlan {
        guard let r=result else{return EQPreviewPlan(bands:[],context:"Hele track",unavailableReason:"Open eerst een audiobestand.")}
        let key=r.sha256+r.assessmentHash+genre
        if key != eqPlanCacheKey || eqPlanCache==nil {
            eqPlanCache=eqPreviewPlan(active:assessTone(r.toneSlices,genre:genre,hash:r.assessmentHash),louder:assessTone(r.toneSlices,genre:genre,hash:r.assessmentHash,loud:true))
            eqPlanCacheKey=key
        }
        return eqPlanCache!
    }
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
        let key=(result?.sha256 ?? "")+(result?.assessmentHash ?? "")+genre+String(tonalLoud)+String(selectedSection)+String(describing:manualBounds)
        if key != toneCacheKey || toneCache==nil {toneCache=assessTone(selectedToneSlices,genre:genre,hash:result?.assessmentHash ?? "",loud:tonalLoud,quiet:sections.first(where:{$0.id==selectedSection})?.label=="Rustiger");toneCacheKey=key}
        return toneCache!
    }
    private var engineerKey=""
    private let engineerQueue=DispatchQueue(label:"audio.yves.mixcheck.advice",qos:.userInitiated)
    private var engineerCancellation=Cancellation()
    @Published private var engineerDynamics:TrackDynamics?
    @Published private var engineerAdvice=[ListeningAdvice]()
    @Published private var recommendationCache=[MixRecommendation]()
    @Published var engineerComputing=false
    func refreshEngineer(){
        engineerCancellation.cancel();engineerCancellation=Cancellation()
        let token=engineerCancellation,key=UUID().uuidString;engineerKey=key
        engineerDynamics=nil;engineerAdvice=[];recommendationCache=[]
        guard let result else{engineerComputing=false;return}
        engineerComputing=true
        let genre=genre,purpose=purpose,bounds=manualBounds
        engineerQueue.async { [weak self] in
            guard (try? token.check()) != nil else{return}
            // Preserve the existing policy: main recommendations use automatic sections;
            // manual section edits only affect the separate listening review.
            let context=RecommendationAnalysis(result,genre:genre)
            let sections=bounds == nil ? context.sections:arrangement(result.toneSlices,duration:result.duration,manual:bounds)
            let dynamics=context.dynamics
            guard (try? token.check()) != nil else{return}
            let recommendations=mixRecommendations(context,purpose:purpose)
            guard (try? token.check()) != nil else{return}
            let advice=bounds == nil ? listeningAdvice(context,purpose:purpose):listeningAdvice(result,sections:sections,genre:genre,purpose:purpose)
            DispatchQueue.main.async {
                guard let self,self.engineerKey==key else{return}
                self.engineerDynamics=dynamics;self.recommendationCache=recommendations
                self.engineerAdvice=advice;self.engineerComputing=false
            }
        }
    }
    var dynamicsReview:TrackDynamics?{engineerDynamics}
    var recommendations:[MixRecommendation]{recommendationCache}
    var listeningReview:[ListeningAdvice]{engineerAdvice}
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
    func cleanup(){engineerCancellation.cancel();cancellation.cancel();stop();transport.stop(immediate:true);eqPreview?.remove();eqPreview=nil;eqPreviewKey=nil;result?.decodedAudio?.remove();reference?.decodedAudio?.remove();SnapshotStorage.cleanup()}
    private func cancelEQSwitch(){eqSwitchCancellation?.cancel();eqSwitchCancellation=nil;eqSwitchTarget=nil;eqSwitchChecking=false}
    func stop(){
        if playing{position=transport.currentTime}
        playbackCancellation?.cancel();playbackCancellation=nil;playbackChecking=false;cancelEQSwitch()
        transport.stop();playing=false;timer?.invalidate();timer=nil
    }
    private func startPlaybackTimer(){
        timer?.invalidate()
        timer=Timer.scheduledTimer(withTimeInterval:0.03,repeats:true){[weak self] _ in Task{@MainActor in
            guard let self,self.transport.isConfigured else{return}
            let bounds=self.activeBounds
            self.position=self.transport.currentTime
            if self.playing,self.comparisonMode=="Passages",!self.transport.isTransitioning,
               self.position>=bounds.1 || (self.playing && !self.transport.isPlaying) {
                if self.loopEnabled {
                    do{try self.transport.play(at:bounds.0)}catch{self.message=error.localizedDescription;self.stop()}
                }else{self.stop();self.position=bounds.1;return}
            }
            if !self.transport.isPlaying && !self.transport.isTransitioning {
                self.playing=false;self.timer?.invalidate();self.timer=nil
            }
        }}
    }
    func play(){playChecked(false)}
    private func playChecked(_ verified:Bool){
        if !verified,playbackChecking{stop();return}
        if playing{cancelEQSwitch();transport.pause();position=transport.currentTime;playing=false;return}
        guard !busy,let r=active else{return}
        reconcileEQPreview()
        guard comparisonMode != "Passages" || passagesReady else{message="Meet eerst de gekozen passages voor een gelijkgetrokken vergelijking.";return}
        if !verified {
            // Source verification must not unmount the results or change the footer height.
            let token=Cancellation();playbackCancellation=token;playbackChecking=true
            queue.async{[weak self] in
                guard (try? token.check()) != nil else{return}
                let unchanged=r.sourceIsUnchanged()
                DispatchQueue.main.async{guard let self,self.playbackCancellation === token else{return}
                    self.playbackCancellation=nil;self.playbackChecking=false
                    guard (try? token.check()) != nil,!self.busy,
                          self.active?.sha256==r.sha256,self.active?.source==r.source else{return}
                    guard unchanged else{self.message="Origineel gewijzigd of niet controleerbaar. Analyseer het opnieuw vóór playback.";return}
                    self.playChecked(true)
                }
            };return
        }
        do {
            let gains=pairedPlaybackGains
            transport.onFailure={[weak self] text in self?.stop();self?.message=text}
            try transport.configure(originalURL:r.playbackURL,previewURL:usingReference ? nil:eqPreview?.url,
                originalGain:Float(pow(10,(usingReference ? gains.reference:gains.original)/20)),
                previewGain:Float(pow(10,gains.preview/20)),previewEnabled:eqEnabled && !usingReference)
            let bounds=activeBounds
            try transport.play(at:position>=bounds.0 && position<bounds.1 ? position:bounds.0)
            playing=true;startPlaybackTimer()
        }catch{stop();message=error.localizedDescription}
    }
    func seek(_ time:Double){position=max(0,min(time.isFinite ? time:0,active?.duration ?? 0));transport.seek(to:position)}
    func listenToAnomaly(at time:Double){
        stop();usingReference=false;comparisonMode="Hele nummer";eqEnabled=false
        seek(max(0,time-1));play()
    }
    func switchSource(){
        let resume=playing,offset=max(0,(playing ? transport.currentTime:position)-activeBounds.0);stop();usingReference.toggle()
        let bounds=activeBounds;position=min(bounds.0+offset,max(bounds.0,bounds.1-0.05));if resume{play()}
    }
    private var desiredEQPreviewKey:EQPreviewKey? {result.map{EQPreviewKey($0,bands:eqPlan.bands)}}
    private func reconcileEQPreview() {
        guard let preview=eqPreview else{return}
        guard let key=eqPreviewKey,key==desiredEQPreviewKey,
              FileManager.default.fileExists(atPath:preview.url.path) else{clearEQ();return}
    }
    func clearEQ(){stop();eqEnabled=false;eqPreview?.remove();eqPreview=nil;eqPreviewKey=nil}
    func toggleEQ(){
        guard !busy,!usingReference,let r=result else{return}
        reconcileEQPreview()
        let resumeAfterScopeChange=playing && comparisonMode=="Passages"
        if comparisonMode=="Passages"{comparisonMode="Hele nummer"}
        if let preview=eqPreview {
            let target = !(eqSwitchTarget ?? eqEnabled)
            cancelEQSwitch()
            guard playing else{eqEnabled=target;transport.setPreviewEnabled(target);if resumeAfterScopeChange{play()};return}
            // Keep the synchronized pair running while checking the source. A/B only ramps gains.
            let token=Cancellation();eqSwitchCancellation=token;eqSwitchTarget=target;eqSwitchChecking=true
            queue.async{[weak self] in
                guard (try? token.check()) != nil else{return}
                let unchanged=r.sourceIsUnchanged()
                DispatchQueue.main.async {
                    guard let self,self.eqSwitchCancellation === token else{return}
                    self.cancelEQSwitch()
                    guard !self.busy,!self.usingReference,self.result?.sha256==r.sha256,
                          self.result?.source==r.source,self.eqPreview?.url==preview.url else{return}
                    guard unchanged else{self.stop();self.message="Origineel gewijzigd of niet controleerbaar. Analyseer het opnieuw vóór playback.";return}
                    self.eqEnabled=target;self.transport.setPreviewEnabled(target)
                }
            };return
        }
        let bands=eqPlan.bands,source=PreviewSource(r),renderKey=EQPreviewKey(r,bands:eqPlan.bands)
        guard !bands.isEmpty else{message=eqPlan.unavailableReason ?? "Geen onderbouwde preview beschikbaar.";return}
        stop();usingReference=false;comparisonMode="Hele nummer";busy=true;progress=0;message="EQ-preview voorbereiden…";cancellation=Cancellation();let token=cancellation
        queue.async{[weak self] in
            do{let preview=try renderEQPreview(source,bands:bands,cancellation:token,progress:{p in DispatchQueue.main.async{self?.progress=p}})
                DispatchQueue.main.async{guard let self,self.cancellation === token else{preview.remove();return};self.busy=false
                    guard (try? token.check()) != nil,self.desiredEQPreviewKey==renderKey else{preview.remove();self.message="Preview geannuleerd.";return}
                    self.eqPreviewKey=renderKey;self.eqPreview=preview;self.eqEnabled=true;self.message=""}
            }catch{DispatchQueue.main.async{guard let self,self.cancellation === token else{return};self.busy=false;self.message=error.localizedDescription}}
        }
    }
    func report(_ format:ReportFormat){
        guard !busy,let r=result else{return}
        let snapshot=ReportSnapshot(r,reference:reference,genre:genre,purpose:purpose,bounds:manualBounds)
        let p=NSSavePanel();p.nameFieldStringValue=URL(fileURLWithPath:snapshot.name).deletingPathExtension().lastPathComponent+"-mixcheck."+format.rawValue
        p.title="Bewaar rapport";p.message="Kies een nieuwe bestandsnaam. Bestaande bestanden worden niet overschreven."
        let validation=NewReportDestinationDelegate();p.delegate=validation
        p.allowedContentTypes=[UTType(filenameExtension:format.rawValue)!]
        guard p.runModal() == .OK,let destination=p.url else{return};withExtendedLifetime(validation){}
        busy=true;progress=0;message="Rapport voorbereiden…";cancellation=Cancellation();let token=cancellation
        queue.async{[weak self] in
            do{try token.check();let data=try snapshot.data(format);try token.check()
                DispatchQueue.main.async{guard let self,self.cancellation === token else{return};self.busy=false
                    do{try token.check();try writeNewReport(data,to:destination);self.message="Rapport opgeslagen: "+destination.lastPathComponent}
                    catch{self.message=error.localizedDescription}}
            }catch{DispatchQueue.main.async{guard let self,self.cancellation === token else{return};self.busy=false;self.message=error.localizedDescription}}
        }
    }
}
struct MainView:View {
    @ObservedObject var s:Session
    @State private var drop=false
    @State private var detail:DashboardDetail?
    enum DashboardDetail:String,Identifiable {
        case tone,dynamics,stereo,technical,comparison,settings,evidence,methodology
        var id:String{rawValue}
        var title:String {switch self{case .tone:return "Toonbalans & passages";case .dynamics:return "Dynamics";case .stereo:return "Stereo & mono";case .technical:return "Technische controle";case .comparison:return "Referentie vergelijken";case .settings:return "Afspelen & meetinstellingen";case .evidence:return "Onderbouwing van het advies";case .methodology:return "Meetmethode & referenties"}}
    }
    var body:some View {
        GeometryReader{geometry in
            VStack(alignment:.leading,spacing:0){
                header.padding(.bottom,4)
                if let r=s.result {
                    transportBar.padding(.bottom,15)
                    waveform(r).frame(height:62)
                        .overlay(alignment:.bottom){sectionStrip(r)}
                    timeline.padding(.top,5).padding(.bottom,12)
                    summary(r,compact:geometry.size.width<1150).padding(.bottom,18)
                    GeometryReader{space in
                        ScrollView {
                            dashboard(r,width:space.size.width,height:max(475,space.size.height))
                        }.scrollIndicators(.automatic)
                    }
                }else{
                    emptyState.frame(maxWidth:.infinity,maxHeight:.infinity)
                }
                if !s.message.isEmpty && !s.busy {
                    HStack(alignment:.top){Text(s.message).font(.system(size:13)).foregroundStyle(caution).textSelection(.enabled);Spacer();Button{ s.message="" }label:{Image(systemName:"xmark").frame(width:22,height:22)}.buttonStyle(.plain).accessibilityLabel("Melding sluiten")}
                        .padding(.top,12)
                }
            }.padding(24)
                .frame(width:geometry.size.width,height:geometry.size.height,alignment:.topLeading)
                .overlay{if s.busy{busyOverlay}}
        }.frame(minWidth:940,minHeight:640)
            .foregroundStyle(DashboardStyle.text).background(DashboardStyle.background).tint(accent).preferredColorScheme(.dark)
            .buttonStyle(DashboardButtonStyle())
            .disclosureGroupStyle(WideDisclosureStyle())
            .sheet(item:$detail){item in detailSheet(item)}
            .overlay{if drop{RoundedRectangle(cornerRadius:12).stroke(accent,lineWidth:3).padding(5).allowsHitTesting(false)}}
            .onDrop(of:[UTType.fileURL.identifier],isTargeted:$drop){providers in guard !s.busy else{return false};guard providers.count==1,let p=providers.first else{s.message="Open één audiobestand tegelijk.";return false};_ = p.loadObject(ofClass:URL.self){url,_ in if let url{DispatchQueue.main.async{if let error=audioOpenIssue([url]){s.message=error}else{s.load(url)}}}};return true}
    }
    private var header:some View {
        HStack(alignment:.center,spacing:12){
            VStack(alignment:.leading,spacing:7){
                HStack(spacing:10){
                    Text(s.result.map{URL(fileURLWithPath:$0.originalSource ?? $0.source).lastPathComponent} ?? "YA / MixCheck")
                        .font(.system(size:23,weight:.semibold)).lineLimit(1).truncationMode(.middle)
                        .help(s.result.map{URL(fileURLWithPath:$0.originalSource ?? $0.source).lastPathComponent} ?? "YA / MixCheck")
                    Button{s.choose()}label:{Image(systemName:"folder").frame(width:28,height:28).contentShape(Rectangle())}.buttonStyle(.plain).foregroundStyle(DashboardStyle.muted)
                        .help("Open een ander audiobestand (⌘O)").accessibilityLabel("Open audio")
                }
                Text(s.result.map{r in "\(display(r.sampleRate/1000,r.sampleRate.truncatingRemainder(dividingBy:1000)==0 ? 0:1)) kHz / \(r.codec.hasPrefix("MP3") ? "MP3" : "\(r.bitDepth)-bit\(r.floatingPoint ? " float":"")")    \(clock(r.duration))"} ?? "Een tweede blik op je mix")
                    .font(.system(size:13)).foregroundStyle(DashboardStyle.muted).lineLimit(1)
            }.frame(maxWidth:.infinity,alignment:.leading).layoutPriority(1)
            DashboardMenu(title:s.genre,width:181,chevron:true,
                choices:["Trap/hiphop","EDM/house","Alternative/indie","Pop/R&B","Anders/onbekend"].map{genre in
                    DashboardMenuChoice(title:genre,selected:s.genre==genre){s.genre=genre}
                },accessibilityTitle:"Genre: \(s.genre)")
            DashboardMenu(title:s.purpose,width:162,
                choices:["Release/master","Mix voor mastering"].map{purpose in
                    DashboardMenuChoice(title:purpose,selected:s.purpose==purpose){s.purpose=purpose}
                },accessibilityTitle:"Doel: \(s.purpose)")
            DashboardMenu(title:"Rapport…",width:120,choices:[
                DashboardMenuChoice(title:"Leesbaar rapport (HTML)…"){s.report(.html)},
                DashboardMenuChoice(title:"Luistermarkers (CSV)…"){s.report(.csv)},
                DashboardMenuChoice(title:"Volledige metingen (JSON)…"){s.report(.json)}
            ]).disabled(s.result==nil)

        }.frame(height:48).disabled(s.busy)
    }
    private var transportBar:some View {
        HStack(spacing:8){
            Button{s.play()}label:{Image(systemName:s.playbackChecking ? "xmark":s.playing ? "pause.fill":"play.fill").font(.system(size:16,weight:.semibold)).frame(width:18)}
                .buttonStyle(DashboardButtonStyle(selected:true)).keyboardShortcut(.space,modifiers:[])
                .accessibilityLabel(s.playbackChecking ? "Broncontrole annuleren":s.playing ? "Pauzeren":"Afspelen")
                .help("Afspelen of pauzeren (spatie)")
            Text("\(clock(s.position)) / \(clock(s.active?.duration ?? 0))").font(.system(size:15)).monospacedDigit().frame(width:126,alignment:.leading).padding(.leading,6)
            Button{
                if s.usingReference{s.switchSource()}
                if s.eqEnabled{s.toggleEQ()}
            }label:{Text("Origineel").frame(minWidth:82)}.buttonStyle(DashboardButtonStyle(selected:!s.usingReference && !s.eqEnabled))
                .accessibilityValue(!s.usingReference && !s.eqEnabled ? "Geselecteerd":"")
            Button("EQ-preview"){
                if s.usingReference{s.switchSource()}
                if !s.eqEnabled{s.toggleEQ()}
            }.buttonStyle(DashboardButtonStyle(selected:!s.usingReference && s.eqEnabled))
                .help(s.eqPlan.unavailableReason ?? "Beluister een subtiele EQ-preview op gelijk niveau. Metingen blijven van het origineel.")
                .accessibilityValue(!s.usingReference && s.eqEnabled ? "Geselecteerd":"")
            if s.reference != nil {
                Button("Referentie B"){if !s.usingReference{s.switchSource()}}
                    .buttonStyle(DashboardButtonStyle(selected:s.usingReference)).accessibilityValue(s.usingReference ? "Geselecteerd":"")
                Button{detail = .comparison}label:{Image(systemName:"slider.horizontal.3").frame(width:16)}.help("Referentie en passages instellen").accessibilityLabel("Referentie vergelijken")
            }else{
                Button("Referentie toevoegen"){s.choose(reference:true)}.padding(.leading,12)
            }
            Spacer(minLength:4)
            ViewThatFits(in:.horizontal){
                Text(s.playbackChecking || s.eqSwitchChecking ? "Bronversie controleren…":s.usingReference ? "Je hoort B · metingen blijven A":"Vergelijken op gelijk niveau")
                Text(s.usingReference ? "Je hoort B":"Gelijk niveau")
            }.font(.system(size:12)).foregroundStyle(DashboardStyle.muted)
                .help("Luistergain \(display(s.playbackGain)) dB. Metingen blijven van het origineel A.")
        }.frame(height:34).disabled(s.busy)
    }
    private var timeline:some View {
        GeometryReader{g in
            let duration=s.active?.duration ?? 0
            ForEach(0..<4){i in
                Text(clock(duration*Double(i)/3)).font(.system(size:11)).foregroundStyle(DashboardStyle.muted)
                    .position(x:12+(g.size.width-28)*Double(i)/3,y:8)
            }
        }.frame(height:16).accessibilityHidden(true)
    }
    private func summary(_ r:Analysis,compact:Bool)->some View {
        HStack(spacing:20){
            DashboardLoudness(value:r.integrated,review:r.loudnessReview(purpose:s.purpose,dynamics:s.dynamicsReview))
            summaryMetric(r.peakIsInterpolated ? "True peak":"Sample peak",display(r.reportedPeak),r.peakIsInterpolated ? "dBTP":"dBFS")
            summaryMetric("LRA",display(r.lra),"LU")
            Button(compact ? "Meetinstellingen…":"Afspeel- en meetinstellingen…"){detail = .settings}
                .accessibilityLabel("Afspeel- en meetinstellingen").fixedSize()
        }.frame(height:42)
    }
    private func summaryMetric(_ title:String,_ value:String,_ unit:String)->some View {
        HStack(alignment:.firstTextBaseline,spacing:10){
            Text(title).font(.system(size:13)).foregroundStyle(DashboardStyle.muted)
            Text(value).font(.system(size:29,weight:.semibold)).monospacedDigit().fixedSize()
            Text(unit).font(.system(size:12)).foregroundStyle(DashboardStyle.muted)
        }.frame(maxWidth:.infinity,alignment:.leading).accessibilityElement(children:.combine)
    }
    private func dashboard(_ r:Analysis,width:CGFloat,height:CGFloat)->some View {
        let gap:CGFloat=width<1100 ? 16:24
        let left=(width-gap)*0.6211
        let right=width-left-gap
        let toneHeight=max(268,height-207)
        let bottomHeight:CGFloat=191
        let dynamicsFraction:CGFloat=width<1100 ? 0.50:0.595
        return HStack(alignment:.top,spacing:gap){
            VStack(spacing:16){
                DashboardTone(assessment:s.toneReview,selection:s.selectedSection>=0 ? "Passage geselecteerd":s.tonalLoud ? "Luidere passages":"Hele track"){detail = .tone}
                    .frame(height:toneHeight)
                HStack(spacing:16){
                    DashboardDynamics(dynamics:s.dynamicsReview,computing:s.engineerComputing){detail = .dynamics}.frame(width:(left-16)*dynamicsFraction)
                    DashboardStereo(result:r){detail = .stereo}
                }.frame(height:bottomHeight)
            }.frame(width:left)
            VStack(spacing:16){
                DashboardAdvice(advice:s.recommendations,computing:s.engineerComputing){detail = .evidence}.frame(height:height-168)
                DashboardTechnical(result:r,purpose:s.purpose,listen:{s.listenToAnomaly(at:$0)},open:{detail = .technical}).frame(height:152)
            }.frame(width:right)
        }.frame(height:height,alignment:.top)
    }
    private var emptyState:some View {
        VStack(spacing:20){
            Image(systemName:"waveform.path").font(.system(size:60,weight:.ultraLight)).foregroundStyle(accent)
            Text("Leg je mix onder de loep.").font(.system(size:30,weight:.medium))
            Text("Sleep een WAV, AIFF, FLAC of MP3 hierheen.").foregroundStyle(DashboardStyle.muted)
            Button("Kies een audiobestand…"){s.choose()}
            Text("Lokaal op je Mac · Je origineel blijft ongewijzigd").font(.system(size:12)).foregroundStyle(DashboardStyle.muted)
            Button("Meetmethode & referenties"){detail = .methodology}
                .buttonStyle(.plain).font(.system(size:13)).foregroundStyle(accent).padding(.top,12)
        }
    }
    private var methodology:some View {
        VStack(alignment:.leading,spacing:20){
            VStack(alignment:.leading,spacing:8){
                Text("Metingen en validatie").font(.headline)
                Text(MeasurementClaims.suite)
                Text(MeasurementClaims.peak)
                Text(MeasurementClaims.lra)
                Text(MeasurementClaims.integrity)
            }
            DisclosureGroup("Niveau en stereo"){
                VStack(alignment:.leading,spacing:12){Text(MeasurementClaims.loudness);Text(MeasurementClaims.stereo)}.padding(.top,10)
            }
            DisclosureGroup("Toonbalans, dynamics en preview"){
                VStack(alignment:.leading,spacing:12){Text(MeasurementClaims.tone);Text(MeasurementClaims.dynamics);Text(MeasurementClaims.spectrum);Text(MeasurementClaims.preview)}.padding(.top,10)
            }
            DisclosureGroup("Rapporten"){
                Text(MeasurementClaims.reports).padding(.top,10)
            }
            VStack(alignment:.leading,spacing:12){
                Text("Genrevoorbeelden").font(.headline)
                Text("Eén gewicht per track. Herkende versies van dezelfde opname worden bij de analyse uit hun eigen referentiegroep uitgesloten.")
                if let issue=ToneLibrary.shared.loadIssue {Text(issue).foregroundStyle(caution)}
                ForEach(Array(Set(ToneLibrary.shared.references.map{ $0.genre })).sorted(),id:\.self){genre in
                    let titles=ToneLibrary.shared.references.filter{$0.genre==genre}.map{$0.title}.sorted()
                    DisclosureGroup("\(genre) · \(titles.count) tracks"){
                        VStack(alignment:.leading,spacing:8){ForEach(titles,id:\.self){Text($0)}}.padding(.top,10)
                    }
                }
            }
        }.font(.system(size:13)).foregroundStyle(DashboardStyle.muted).lineSpacing(3).textSelection(.enabled)
    }
    private var busyOverlay:some View {
        ZStack{
            DashboardStyle.background.opacity(0.86).contentShape(Rectangle())
            VStack(alignment:.leading,spacing:20){
                Text(s.message.isEmpty ? "Bestand analyseren…":s.message).font(.system(size:19,weight:.semibold)).fixedSize(horizontal:false,vertical:true)
                ProgressView(value:s.progress).tint(accent)
                HStack{Text("\(Int(s.progress*100))%").monospacedDigit().foregroundStyle(DashboardStyle.muted);Spacer();Button("Annuleren"){s.cancellation.cancel()}}
            }.padding(28).frame(width:480).background(panel,in:RoundedRectangle(cornerRadius:12))
        }.accessibilityAddTraits(.isModal)
    }
    private func detailSheet(_ item:DashboardDetail)->some View {
        VStack(alignment:.leading,spacing:18){
            HStack{Text(item.title).font(.system(size:23,weight:.semibold));Spacer();Button("Gereed"){detail=nil}.keyboardShortcut(.cancelAction)}
            Divider()
            ScrollView {
                VStack(alignment:.leading,spacing:20){
                    if item == .methodology {
                        methodology
                    }else if let r=s.result {
                        switch item {
                        case .tone:
                            TonalPanel(s:s,r:r)
                            ArrangementPanel(s:s)
                            DisclosureGroup("Gemiddeld spectrum"){spectrum(r)}
                        case .dynamics:DynamicsPanel(s:s,r:r)
                        case .stereo:stereo(r)
                        case .technical:findings(r)
                        case .comparison:comparisonPanel;spectrum(r)
                        case .settings:
                            levels(r)
                            DisclosureGroup("Referentie & afspelen"){comparisonPanel}
                            ArrangementPanel(s:s)
                            DisclosureGroup("Bestandscontrole"){details(r)}
                        case .evidence:
                            Text("\(s.genre) · hele track").foregroundStyle(DashboardStyle.muted)
                            ForEach(s.recommendations){a in
                                VStack(alignment:.leading,spacing:10){
                                    Text(a.title).font(.headline)
                                    if let scope=a.scope{Text(scope).font(.caption).foregroundStyle(accent)}
                                    Text(a.action);Text(a.evidence).foregroundStyle(DashboardStyle.muted)
                                }.textSelection(.enabled)
                                Divider()
                            }
                        case .methodology:EmptyView()
                        }
                    }
                }.frame(maxWidth:.infinity,alignment:.leading).padding(.trailing,8)
            }
        }.padding(24).frame(width:760,height:620).background(DashboardStyle.background)
            .foregroundStyle(DashboardStyle.text).buttonStyle(DashboardButtonStyle()).preferredColorScheme(.dark)
            .disclosureGroupStyle(WideDisclosureStyle())
            .overlay{if s.busy{busyOverlay}}
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
                            .fill(section.id.isMultiple(of:2) ? DashboardStyle.zone:DashboardStyle.accent)
                            .frame(width:width,height:3)
                            .frame(height:14,alignment:.bottom)
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
            let mid=size.height/2,ceiling=max(1,Double(a.waveform.max() ?? 1))
            let bars=max(1,min(Int(size.width/3),a.waveform.count))
            var before=Path(),after=Path()
            for i in 0..<bars {
                let j=i*a.waveform.count/bars,end=min(a.waveform.count,max(j+1,(i+1)*a.waveform.count/bars))
                guard j<end else{continue}
                let h=Double(a.waveform[j..<end].max() ?? 0)/ceiling*(mid-9),x=(Double(i)+0.5)/Double(bars)*size.width
                if x<size.width*s.position/max(0.001,a.duration){before.move(to:CGPoint(x:x,y:mid-h));before.addLine(to:CGPoint(x:x,y:mid+h))}
                else{after.move(to:CGPoint(x:x,y:mid-h));after.addLine(to:CGPoint(x:x,y:mid+h))}
            }
            ctx.stroke(before,with:.color(accent),lineWidth:1.25)
            ctx.stroke(after,with:.color(DashboardStyle.muted),lineWidth:1.25)
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
        }.frame(height:62).background(panel,in:RoundedRectangle(cornerRadius:8)).overlay{GeometryReader{geo in Color.clear.contentShape(Rectangle()).gesture(DragGesture(minimumDistance:0).onChanged{s.seek($0.location.x/geo.size.width*a.duration)})}}.accessibilityLabel("Waveform. Klik om een tijdstip te kiezen.")
    }
    @ViewBuilder func findings(_ r:Analysis)->some View {
        VStack(alignment:.leading,spacing:14){
            if r.secondOpinion(purpose:s.purpose).allSatisfy({$0.category=="Context, geen fout"}) {Text("Geen prioritaire technische melding. Toonbalans, stereo en dynamics kunnen nog luisterpunten bevatten.").font(.system(size:12)).foregroundStyle(.secondary)}
            if !r.anomalies.isEmpty {
                DisclosureGroup("Kliks en stiltes · luisterpunten (\(r.anomalies.count))") {
                    ForEach(r.anomalies){event in
                        Button("\(clock(Double(event.startFrame)/r.sampleRate)) · \(event.kind=="click" ? "Mogelijke klik":"Abrupte stilte") · kanaal \(event.channel+1)") {
                            s.listenToAnomaly(at:Double(event.startFrame)/r.sampleRate)
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
                    if let frame=item.startFrame{Button("Beluister bij \(clock(Double(frame)/r.sampleRate))"){s.listenToAnomaly(at:Double(frame)/r.sampleRate)}}
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
                    GridRow{Text("Start A");TextField("Seconden",value:$s.passageAStart,format:.number.precision(.fractionLength(1))).frame(width:90).accessibilityLabel("Start passage A in seconden");Text("seconden")}
                    if s.reference != nil {GridRow{Text("Start B");TextField("Seconden",value:$s.passageBStart,format:.number.precision(.fractionLength(1))).frame(width:90).accessibilityLabel("Start passage B in seconden");Text("seconden")}}
                    GridRow{Text("Duur");TextField("Seconden",value:$s.passageLength,format:.number.precision(.fractionLength(1))).frame(width:90).accessibilityLabel("Passageduur in seconden").accessibilityHint("3 tot 120 seconden, binnen beide bestanden");Text("3–120 seconden")}
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
            Text("Niveaudetails").font(.headline)
            HStack{metric("Sample peak",display(r.samplePeak),"dBFS");metric(r.peakIsInterpolated ? "PLR":"Samplepiek − LUFS",display(r.reportedPeakGap),"dB")}
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
        }}
    func details(_ r:Analysis)->some View{VStack(alignment:.leading,spacing:12){
        Picker("Zelfreferentie",selection:Binding(get:{(UserDefaults.standard.dictionary(forKey:"referenceIdentityOverrides") as? [String:String])?[r.sha256] ?? "auto"},set:{s.setReferenceIdentity($0)})) {
            Text("Automatisch herkennen").tag("auto")
            Text("Andere mix / geen zelfreferentie").tag("none")
            ForEach(ToneLibrary.shared.references.indices,id:\.self){i in let ref=ToneLibrary.shared.references[i];Text(ref.title).tag(ref.hashes.first ?? "none")}
        }.disabled(s.busy)
        if let identity=r.referenceIdentity {Text(identity.method=="manual-distinct" ? "Zelfreferentie: handmatig uitgeschakeld" : "Uitgesloten referentie: \(identity.title)").foregroundStyle(.secondary)}
        Text("\(r.frames) frames • \(r.codec.hasPrefix("MP3") ? "MP3 → float32" : "\(r.bitDepth)-bit\(r.floatingPoint ? " float":"")") • \(display(r.elapsedSeconds,2)) s analysetijd");Text("Bron-SHA256").foregroundStyle(.secondary);Text(r.sha256).font(.system(size:11,design:.monospaced)).textSelection(.enabled);Text("\(r.incidents.count) overrange- en \(r.clipping.events.count) plateau-intervallen opgeslagen.")}.font(.system(size:13))}
}
@MainActor final class AppDelegate:NSObject,NSApplicationDelegate,NSMenuItemValidation {
    var window:NSWindow?
    var session:Session?
    private var pendingOpen:[URL]?
    func applicationWillTerminate(_ notification:Notification){session?.cleanup()}
    func applicationDidFinishLaunching(_ notification:Notification){SnapshotStorage.recover();let s=Session();session=s;installMenus();let visible=NSScreen.main?.visibleFrame ?? NSRect(x:0,y:0,width:1280,height:800);let w=NSWindow(contentRect:NSRect(x:0,y:0,width:min(1360,visible.width-32),height:min(780,visible.height-32)),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false);w.title="YA / MixCheck";w.titlebarAppearsTransparent=true;w.backgroundColor=NSColor(red:0.078,green:0.098,blue:0.118,alpha:1);w.contentView=NSHostingView(rootView:MainView(s:s));w.contentMinSize=NSSize(width:940,height:640);w.center();w.makeKeyAndOrderFront(nil);window=w;NSApp.activate(ignoringOtherApps:true)
        if let urls=pendingOpen {pendingOpen=nil;_ = openAudioURLs(urls)}
        else if let p=ProcessInfo.processInfo.environment["YA_MIXCHECK_OPEN"]{_ = openAudioURLs([URL(fileURLWithPath:p)])}
    }
    @discardableResult func openAudioURLs(_ urls:[URL])->Bool {
        guard let s=session else{pendingOpen=urls;return true}
        window?.makeKeyAndOrderFront(nil)
        if let error=audioOpenIssue(urls){s.message=error;return false}
        guard !s.busy else{s.message="Er loopt nog een taak. Annuleer die eerst of open het bestand daarna opnieuw.";return false}
        s.load(urls[0]);return true
    }
    func application(_ sender:NSApplication,openFiles filenames:[String]){sender.reply(toOpenOrPrint:openAudioURLs(filenames.map{URL(fileURLWithPath:$0)}) ? .success:.failure)}
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool{window?.makeKeyAndOrderFront(nil);return true}
    @objc func openAudio(_ sender:Any?){session?.choose()}
    @objc func openReference(_ sender:Any?){session?.choose(reference:true)}
    @objc func exportHTML(_ sender:Any?){session?.report(.html)}
    @objc func exportCSV(_ sender:Any?){session?.report(.csv)}
    @objc func exportJSON(_ sender:Any?){session?.report(.json)}
    func validateMenuItem(_ item:NSMenuItem)->Bool {
        guard let s=session else{return false}
        if item.action == #selector(openAudio(_:)){return !s.busy}
        return !s.busy && s.result != nil
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool{true}
}
@main struct Entry {
    @MainActor static func main(){
        let args=CommandLine.arguments
        if args.count>1 {
            do {
                if args[1]=="--check-input-worker",args.count==5 {
                    let a=try FileManager.default.attributesOfItem(atPath:args[2])
                    let same=(a[.size] as? NSNumber)?.int64Value==Int64(args[3]) && (a[.modificationDate] as? Date)?.timeIntervalSince1970==Double(args[4])
                    exit(same ? 0:2)
                }
                if args[1]=="--prepare-input-worker",args.count==4{try prepareInputWorker(source:URL(fileURLWithPath:args[2]),destination:URL(fileURLWithPath:args[3]));exit(0)}
                if args[1]=="--input-worker-stall"{Thread.sleep(forTimeInterval:60);exit(0)}
                if args[1]=="--stability-probe",args.count==5{try runStabilityProbe(mode:args[2],source:URL(fileURLWithPath:args[3]),output:URL(fileURLWithPath:args[4]));exit(0)}
                if args[1]=="--stability-test"{let tests=try validateSessionStability();let e=JSONEncoder();e.outputFormatting=[.prettyPrinted,.sortedKeys];FileHandle.standardOutput.write(try e.encode(tests));exit(tests.allSatisfy{$0.passed} ? 0:1)}
                if args[1]=="--input-test"{let e=JSONEncoder();e.outputFormatting=[.prettyPrinted,.sortedKeys];let tests=try validatePreparedInput();FileHandle.standardOutput.write(try e.encode(tests));exit(tests.allSatisfy{$0.passed} ? 0:1)}
                if args[1]=="--performance-test" {let tests=try validatePerformanceLifecycle(decodedFixture:args.count==3 ? URL(fileURLWithPath:args[2]):nil);let e=JSONEncoder();e.outputFormatting=[.prettyPrinted,.sortedKeys];FileHandle.standardOutput.write(try e.encode(tests));exit(tests.allSatisfy{$0.passed} ? 0:1)}
                if args[1]=="--session-test",args.count==3{FileHandle.standardOutput.write(try validateSessionRegression(URL(fileURLWithPath:args[2])));exit(0)}
                if args[1]=="--eq-cache-test"{let tests=try validateEQPreviewCache();let e=JSONEncoder();e.outputFormatting=[.prettyPrinted,.sortedKeys];FileHandle.standardOutput.write(try e.encode(tests));exit(tests.allSatisfy{$0.passed} ? 0:1)}
                if args[1]=="--transport-test"{let tests=try validatePreviewTransport();let e=JSONEncoder();e.outputFormatting=[.prettyPrinted,.sortedKeys];FileHandle.standardOutput.write(try e.encode(tests));exit(tests.allSatisfy{$0.passed} ? 0:1)}
                if args[1]=="--transport-device-test"{let tests=try validatePreviewTransportDevice();let e=JSONEncoder();e.outputFormatting=[.prettyPrinted,.sortedKeys];FileHandle.standardOutput.write(try e.encode(tests));exit(tests.allSatisfy{$0.passed} ? 0:1)}
                if args[1]=="--mixer-render-test"{let tests=try validateNativeMixerRamps();let e=JSONEncoder();e.outputFormatting=[.prettyPrinted,.sortedKeys];FileHandle.standardOutput.write(try e.encode(tests));exit(tests.allSatisfy{$0.passed} ? 0:1)}
                if args[1]=="--report",args.count==6,let format=ReportFormat(rawValue:args[4]) {
                    let r=try Analyzer.run(URL(fileURLWithPath:args[2]),makePreview:false)
                    let snapshot=ReportSnapshot(r,genre:args[3],purpose:"Release/master")
                    try writeNewReport(snapshot.data(format),to:URL(fileURLWithPath:args[5]));exit(0)
                }
                if args[1]=="--engineer-test",args.count==4{FileHandle.standardOutput.write(try validateEngineerMusic(URL(fileURLWithPath:args[2]),genre:args[3]));exit(0)}
                if args[1]=="--loudness-test",args.count==4{
                    let data=try validateLoudnessMusic(URL(fileURLWithPath:args[2]),genre:args[3])
                    FileHandle.standardOutput.write(data)
                    let result=try JSONSerialization.jsonObject(with:data) as? [String:Any]
                    exit(result?["passed"] as? Bool == true ? 0:1)
                }
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
                if args[1]=="--assess",args.count==4 {let data=try Data(contentsOf:URL(fileURLWithPath:args[2]));let r=try JSONDecoder().decode(FeatureDocument.self,from:data);let e=JSONEncoder();e.outputFormatting=[.prettyPrinted,.sortedKeys];FileHandle.standardOutput.write(try e.encode(assessTone(r.slices,genre:args[3],hash:r.referenceIdentity?.hash ?? ReferenceIdentities.shared.resolve(hash:r.sha256,duration:r.duration,slices:r.slices)?.hash ?? r.sha256)));exit(0)}
                if args[1]=="--self-test"{let outcomes=try runValidation();let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys];FileHandle.standardOutput.write(try encoder.encode(outcomes));exit(outcomes.allSatisfy{$0.passed} ? 0:1)}
                if args[1]=="--analyze-region",args.count==5,let start=Double(args[3]),let duration=Double(args[4]){let r=try Analyzer.run(URL(fileURLWithPath:args[2]),startSeconds:start,durationSeconds:duration,makePreview:false);FileHandle.standardOutput.write(try r.json());exit(0)}
                if args[1]=="--advice",args.count==4{let r=try Analyzer.run(URL(fileURLWithPath:args[2]),makePreview:false);let e=JSONEncoder();e.outputFormatting=[.prettyPrinted,.sortedKeys];FileHandle.standardOutput.write(try e.encode(mixRecommendations(r,genre:args[3],purpose:"Release/master")));r.decodedAudio?.remove();exit(0)}
                if args[1]=="--analyze",args.count==3{let r=try Analyzer.run(URL(fileURLWithPath:args[2]));FileHandle.standardOutput.write(try r.json());r.decodedAudio?.remove();exit(0)}
                if args[1]=="--demo",args.count==3{let rate=48000;let samples=(0..<rate*8).flatMap{n->[Float] in let t=Double(n)/Double(rate);let env=0.5+0.5*sin(Double.pi*t/8);let v=Float(env*(0.22*sin(2*Double.pi*60*t)+0.08*sin(2*Double.pi*1000*t)));return[v,v]};try writeTestAudio(URL(fileURLWithPath:args[2]),samples:samples,rate:48000,channels:2);exit(0)}
                throw QCFailure(message:"Gebruik --self-test, --analyze <audio> of --demo <nieuw wav-pad>.")
            }catch{FileHandle.standardError.write(Data((error.localizedDescription+"\n").utf8));exit(1)}
        }
        let app=NSApplication.shared;app.setActivationPolicy(.regular)
        let delegate=AppDelegate();app.delegate=delegate;app.run();withExtendedLifetime(delegate){}
    }
}
