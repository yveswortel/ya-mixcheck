import Foundation
func validateTonal() throws->[TestOutcome]{
 var out=[TestOutcome]()
 func check(_ n:String,_ b:Bool,_ d:String=""){out.append(TestOutcome(name:n,passed:b,detail:d))}
 func features(_ x:[Float],rate:Int=48000,ch:Int=2,chunk:Int=4096)->[ToneSlice]{
  let q=qct_create(Int32(rate),Int32(ch),Int64(x.count/ch))!;defer{qct_destroy(q)}
  x.withUnsafeBufferPointer{p in var pos=0;while pos<x.count/ch{let n=min(chunk,x.count/ch-pos);_ = qct_push(q,p.baseAddress!+pos*ch,Int32(n));pos+=n}}
  return extractSlices(q)
 }
 func signal(seconds:Int,rate:Int=48000,gain:Double=1,bass:Double=1,anti:Bool=false)->[Float]{
  var x=[Float]();x.reserveCapacity(seconds*rate*2)
  for n in 0..<(seconds*rate){let t=Double(n)/Double(rate),low=0.07*bass*sin(2*Double.pi*80*t),mid=0.03*sin(2*Double.pi*1000*t),high=0.01*sin(2*Double.pi*7000*t);x.append(Float((low+mid+high)*gain));x.append(Float(((anti ? -low:low)+mid+high)*gain))};return x
 }
 let x=signal(seconds:12),base=features(x),summary=summarizeTone(base)
 let gain=features(x.map{$0*0.25}),gainSummary=summarizeTone(gain)
 check("Tonal gain invariance",zip(summary.bands,gainSummary.bands).allSatisfy{a,b in if let a,let b{return abs(a-b)<1e-5};return a==nil && b==nil})
 let chunks=features(x,chunk:127)
 check("Tonal windows chunk invariant",base.count==chunks.count && zip(base,chunks).allSatisfy{$0.bands==$1.bands && $0.rms==$1.rms && $0.lowMono==$1.lowMono})
 check("Tonal identical stereo preserves low mono",abs(summary.lowMono ?? 10)<1e-8)
 let anti=summarizeTone(features(signal(seconds:12,anti:true)))
 check("Low mono catches anti-phase bass despite centered mids",(anti.lowMono ?? 0)<(-60))
 let boosted=summarizeTone(features(signal(seconds:12,bass:2)))
 check("Bass boost changes low-to-mid ratio by 6 dB",abs((boosted.bands[1]!-boosted.bands[4]!)-(summary.bands[1]!-summary.bands[4]!)-6.0206)<0.03)
 for rate in [44100,96000,192000]{let s=summarizeTone(features(signal(seconds:10,rate:rate),rate:rate));check("Broad tone bands stable at \(rate)",abs(s.bands[1]!-summary.bands[1]!)<0.1 && abs(s.bands[4]!-summary.bands[4]!)<0.1)}
 let quiet=features([Float](repeating:0,count:48000*2*10))
 check("Silence gets no tonal verdict",summarizeTone(quiet).seconds==0 && assessTone(quiet,genre:"Test",hash:"").advice.isEmpty)
 // Independent analytic 80 Hz power A²/2; not a copy of FFT implementation.
 check("Low-band energy agrees with analytic sine",abs(pow(10,base[1].bands[1]!/10)-0.07*0.07/2)<1e-6)
 var pulsed=x
 for i in 0..<(pulsed.count/2) {let g=(i%96000)<19200 ? Float(1):Float(0.05);pulsed[i*2]*=g;pulsed[i*2+1]*=g}
 let pulseSummary=summarizeTone(features(pulsed))
 check("Low envelope distinguishes bursts from sustain",(pulseSummary.lowContrast ?? 0)>(summary.lowContrast ?? 0)+2.5)
 let fakeRefs=(0..<7).map{ToneReference(title:"Reference \($0)",genre:"Test",hashes:["\($0)"],active:summary,loud:summary,quiet:summary)}
 let library=ToneLibrary(version:"0.4.0",method:"synthetic fixture",references:fakeRefs)
 var quietRefs=fakeRefs
 for i in quietRefs.indices{quietRefs[i].quiet.bands[4]=(quietRefs[i].quiet.bands[4] ?? 0)+4}
 let quietLibrary=ToneLibrary(version:"0.4.0",method:"scope fixture",references:quietRefs)
 let quietAssessment=assessTone(base,genre:"Test",hash:"",quiet:true,library:quietLibrary)
 check("Quiet section selects quiet reference distribution",abs((quietAssessment.bands[4].median ?? 0)-(summary.bands[4]!+4))<1e-9 && quietAssessment.mode=="Rustigere referentiepassages")
 check("Self reference excluded",assessTone(base,genre:"Test",hash:"0",library:library).referenceCount==6)
 check("Missing genre is not a pass",assessTone(base,genre:"Unknown",hash:"",library:library).referenceCount==0)
 let a=assessTone(base,genre:"Test",hash:"",library:library),b=assessTone(gain,genre:"Test",hash:"",library:library)
 check("Advice does not change after gain",a.bands.map{$0.status}==b.bands.map{$0.status})
 check("Baseline within matching references",!a.bands.contains{$0.attention})
 var edited=base
 for i in edited.indices {edited[i].bands[4]=(edited[i].bands[4] ?? -100)+9}
 check("Known broad mid emphasis creates targeted advice",assessTone(edited,genre:"Test",hash:"",library:library).bands[4].attention)
 var levelStep=base+base+base
 for i in levelStep.indices{levelStep[i].start=Double(i)*2;if i>=6 && i<12{levelStep[i].rms=(levelStep[i].rms ?? 0)+8}}
 let sections=arrangement(levelStep,duration:36)
 check("Arrangement finds sustained level steps",sections.contains{abs($0.start-12)<=2} && sections.contains{abs($0.start-24)<=2},sections.map{String($0.start)}.joined(separator:","))
 let shapeStep=base+edited+base
 var shapeTimeline=shapeStep;for i in shapeTimeline.indices{shapeTimeline[i].start=Double(i)*2}
 check("Arrangement finds tone-only changes",arrangement(shapeTimeline,duration:36).count>=2)
 check("Steady audio is one section",arrangement(base,duration:12).count==1)
 check("Manual arrangement bounds respected",arrangement(levelStep,duration:36,manual:[10,25]).map{$0.start}==[0,10,25])
 // High is an energy sum per track, never an average of dB values or percentile endpoints.
 let raw:[Double?]=[-20,-10,-12,-14,-16,-20,-30,-40]
 let merged=sevenToneBands(raw)
 check("Seven bands preserve coverage and merge High energy",merged.count==7 && abs(merged[5]!-10*log10(0.011))<1e-10 && merged[6]==raw[7])
 check("Seven bands handle silence",sevenToneBands([Double?](repeating:nil,count:8)).allSatisfy{$0==nil})
 check("Assessment exposes requested seven names",a.bands.map{$0.name}==["Sub","Bass","Low-mid","Body","Mids","High","Air"] && !a.bands[6].attention)
 var combinedRefs=fakeRefs
 for i in combinedRefs.indices{combinedRefs[i].active.bands[5]=i<3 ? -10:-30;combinedRefs[i].active.bands[6]=i<3 ? -30:-10}
 let combined=assessTone(base,genre:"Test",hash:"",library:ToneLibrary(version:"0.4.0",method:"energy fixture",references:combinedRefs))
 check("High reference distribution sums each track before quantiles",abs(combined.bands[5].median!-10*log10(0.101))<1e-10 && abs(combined.bands[5].upper!-combined.bands[5].lower!)<1e-10)
 return out
}
