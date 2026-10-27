import Foundation

struct AdviceWindow {
    var start:Double;var seconds:Double;var level:Double;var advice:[MixRecommendation]
}
func adviceKey(_ a:MixRecommendation)->String {a.id+"|"+a.title}
func representativeActiveStart(_ slices:[ToneSlice])->Double? {
    let active=usableSlices(slices)
    guard let median=quantile(active.compactMap{$0.rms},0.5) else{return nil}
    return active.min{abs(($0.rms ?? median)-median)<abs(($1.rms ?? median)-median)}?.start
}
// Disjoint windows: duration support cannot be inflated by overlapping analysis.
// Match direction as well as ID, so alternating too much/too little never becomes persistent.
func supportedAdvice(_ windows:[AdviceWindow])->[MixRecommendation] {
    let total=windows.reduce(0){$0+$1.seconds}
    guard total>=8 else{return []}
    var candidates=[String:MixRecommendation]()
    for w in windows {for a in w.advice{candidates[adviceKey(a)]=a}}
    var results=[MixRecommendation]()
    for key in candidates.keys.sorted() {
        let matching=windows.filter{$0.advice.contains{adviceKey($0)==key}}
        let seconds=matching.reduce(0){$0+$1.seconds},fraction=seconds/total
        guard seconds>=8,let median=quantile(matching.map{$0.level},0.5) else{continue}
        // A typical supporting window, not the single loudest outlier. Stable tie break.
        let chosen=matching.sorted{
            let x=abs($0.level-median),y=abs($1.level-median)
            return abs(x-y)<1e-9 ? $0.start<$1.start:x<y
        }[0]
        var advice=candidates[key]!
        advice.start=chosen.start;advice.supportFraction=fraction
        advice.contrast=quantile(matching.compactMap{w in w.advice.first{adviceKey($0)==key}?.contrast},0.5)
        advice.scope=seconds>=24 && fraction>=0.6 ? "Aanhoudend":"Lokaal / wisselend"
        advice.evidence="\(advice.scope!): dit patroon verschijnt in \(Int((fraction*100).rounded()))% van de beoordeelde actieve venstertijd. Luisterfragment \(Int(chosen.start))–\(Int(chosen.start+chosen.seconds)) s; geen sample-exacte probleemgrens. "+advice.evidence
        results.append(advice)
    }
    // Joint explanations before isolated bands; then recurring patterns before rare ones.
    let joint:Set<String>=["air-body-mids","balance-weight-presence","dense-soft-attacks","open-with-attacks"]
    return results.sorted{
        if joint.contains($0.id) != joint.contains($1.id){return joint.contains($0.id)}
        if $0.supportFraction != $1.supportFraction{return ($0.supportFraction ?? 0)>($1.supportFraction ?? 0)}
        // Half-dB buckets avoid shuffling equivalent tips on tiny normalization changes.
        let x=Int((($0.contrast ?? 0)*2).rounded()),y=Int((($1.contrast ?? 0)*2).rounded())
        if x != y{return x>y}
        return adviceKey($0)<adviceKey($1)
    }
}
func temporalRecommendations(_ a:Analysis,genre:String,purpose:String,sections:[ArrangementSection])->[MixRecommendation] {
    temporalRecommendations(RecommendationAnalysis(a,genre:genre,sections:sections),purpose:purpose)
}
func temporalRecommendations(_ context:RecommendationAnalysis,purpose:String)->[MixRecommendation] {
    let a=context.analysis,genre=context.genre,sections=context.sections
    let globalTone=context.tone,globalDynamics=context.dynamics
    let global=contextualRecommendations(tone:globalTone,d:globalDynamics,passages:context.passages,purpose:purpose)
    let globalKeys=Set(global.map{adviceKey($0)})
    let active=usableSlices(a.toneSlices), activeStarts=Set(active.map{$0.start})
    let median=quantile(active.compactMap{$0.rms},0.5) ?? -70
    let groups=Dictionary(grouping:a.toneSlices,by:{Int($0.start/8)})
    let refs=DynamicsLibrary.shared.references.filter{$0.genre==genre && !$0.hashes.contains(a.assessmentHash)}
    var windows=[AdviceWindow]()
    for key in groups.keys.sorted() {
        let slices=groups[key]!.sorted{$0.start<$1.start}
        // All four 2s slices must be active: quiet tails/partial windows do not dilute support.
        guard slices.count>=4,slices.allSatisfy({activeStarts.contains($0.start)}),let first=slices.first,let last=slices.last else{continue}
        let end=last.start+last.duration,seconds=end-first.start
        guard seconds>=8 else{continue}
        let level=quantile(slices.compactMap{$0.rms},0.5) ?? median,quiet=level<median-3
        // Choose reference population without gating this already-selected window again.
        var windowLibrary=ToneLibrary.shared
        if quiet {windowLibrary.references=windowLibrary.references.map{var r=$0;r.active=r.quiet;return r}}
        let tone=assessTone(slices,genre:genre,hash:a.assessmentHash,library:windowLibrary)
        let ds=summarizeDynamics(context.index.within(start:first.start,end:end))
        let d=TrackDynamics(referenceCount:refs.count,summary:ds,metrics:dynamicsMetrics(ds,targets:refs.map{quiet ? $0.quiet:$0.loud}))
        // Movement describes transitions over the track, not eight-second extracts.
        let tips=contextualRecommendations(tone:tone,d:d,passages:[],purpose:purpose).filter{tip in
            if tip.id=="dynamics-movement" {return false}
            if globalKeys.contains(adviceKey(tip)) {return true}
            // A quieter intro/break can intentionally omit bass or brightness.
            // Do not introduce a new corrective tip from that arrangement alone.
            if quiet {return false}
            // A local genre excursion alone is often arrangement, not useful advice.
            // New local tonal tips also require a substantial departure from this track.
            let bands:[Int]
            if tip.id.hasPrefix("tone-"),let b=Int(tip.id.dropFirst(5)){bands=[b]}
            else if tip.id=="air-body-mids"{bands=[3,4,6]}
            else if tip.id=="balance-weight-presence"{bands=[0,1]}
            else{return false} // Short-window dynamics needs separate calibration.
            return bands.contains{b in
                guard let local=tone.bands.first(where:{$0.id==b})?.value,
                      let whole=globalTone.bands.first(where:{$0.id==b})?.value else{return false}
                return abs(local-whole)>=4
            }
        }
        let ranked=tips.map{tip -> MixRecommendation in
            var r=tip
            if tip.id.hasPrefix("tone-"),let b=Int(tip.id.dropFirst(5)),
               let local=tone.bands.first(where:{$0.id==b})?.value,
               let whole=globalTone.bands.first(where:{$0.id==b})?.value {r.contrast=abs(local-whole)}
            return r
        }
        windows.append(AdviceWindow(start:first.start,seconds:seconds,level:level,advice:ranked))
    }
    var supported=supportedAdvice(windows)
    // Prevent a compound balance tip and its component EQ tips taking all three places.
    let ids=Set(supported.map{$0.id})
    supported.removeAll{r in
        (ids.contains("air-body-mids") && ["tone-3","tone-4"].contains(r.id)) ||
        (ids.contains("balance-weight-presence") && r.id.hasPrefix("tone-")) ||
        (ids.contains("dense-soft-attacks") && ["dynamics-density","dynamics-punch"].contains(r.id)) ||
        (ids.contains("open-with-attacks") && ["dynamics-density","dynamics-punch"].contains(r.id))
    }
    // Whole-track movement keeps its own meaning; choose a transition, not a loudest peak.
    for var tip in global where tip.id=="arrangement-contrast" || tip.id=="dynamics-movement" {
        tip.scope="Trackcontext"
        tip.start=sections.dropFirst().first?.start ?? representativeActiveStart(active)
        supported.append(tip)
    }
    if windows.isEmpty {
        return global.map{var tip=$0;tip.scope="Onvoldoende tijdcontext";tip.start=representativeActiveStart(active);return tip}
    }
    return supported
}
