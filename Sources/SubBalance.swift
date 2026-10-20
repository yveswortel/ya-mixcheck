import Foundation

struct SubSlice:Codable {var start:Double;var duration:Double;var sub:Double;var rest:Double}
struct SubEvent:Codable {var start:Double;var end:Double;var dominance:Double;var excess:Double}
// RBJ Butterworth sections. Independent channel energies: no cancellation from stereo summing.
private struct SubFilter {
    var b0:Double,b1:Double,b2:Double,a1:Double,a2:Double
    var z1=0.0,z2=0.0
    init(rate:Double,hz:Double,high:Bool){
        let w=2*Double.pi*hz/rate,c=cos(w),alpha=sin(w)/sqrt(2),a0=1+alpha
        b0=(high ? 1+c:1-c)/2/a0;b1=(high ? -(1+c):1-c)/a0;b2=b0
        a1 = -2*c/a0;a2=(1-alpha)/a0
    }
    mutating func push(_ x:Double)->Double{let y=b0*x+z1;z1=b1*x-a1*y+z2;z2=b2*x-a2*y;return y}
}
final class SubDetector {
    let rate:Double,channels:Int,hop:Int
    private var hp:[SubFilter],lp:[SubFilter],restHP:[SubFilter]
    private var n=0,frames=0,subEnergy=0.0,restEnergy=0.0
    var slices=[SubSlice]()
    init(rate:Double,channels:Int){
        self.rate=rate;self.channels=channels;hop=Int((rate*0.1).rounded())
        hp=Array(repeating:SubFilter(rate:rate,hz:20,high:true),count:channels)
        lp=Array(repeating:SubFilter(rate:rate,hz:80,high:false),count:channels)
        restHP=Array(repeating:SubFilter(rate:rate,hz:120,high:true),count:channels)
    }
    func push(_ p:UnsafePointer<Float>,frames count:Int){
        for i in 0..<count{
            for c in 0..<channels{
                let x=Double(p[i*channels+c]),s=lp[c].push(hp[c].push(x)),r=restHP[c].push(x)
                subEnergy+=s*s;restEnergy+=r*r
            }
            n+=1;frames+=1;if n==hop{emit()}
        }
    }
    func emit(){
        guard n>0 else{return}
        let divisor=Double(n*channels)
        slices.append(SubSlice(start:Double(frames-n)/rate,duration:Double(n)/rate,sub:10*log10(max(1e-20,subEnergy/divisor)),rest:10*log10(max(1e-20,restEnergy/divisor))))
        n=0;subEnergy=0;restEnergy=0
    }
}
func localSubEvents(_ slices:[SubSlice])->[SubEvent]{
    // Candidates, not clipping/masking diagnoses. Require an unusual sub rise, not a gap in vocals.
    let gate=max(-65,(quantile(slices.map{max($0.sub,$0.rest)},0.9) ?? -200)-25)
    var hits=[SubEvent]()
    for (i,s) in slices.enumerated() where s.duration>=0.09 && s.start>=1 && s.sub>gate {
        let neighborhood=slices[max(0,i-50)..<min(slices.count,i+51)].filter{abs($0.start-s.start)>0.5 && $0.duration>=0.09 && max($0.sub,$0.rest)>gate}
        guard neighborhood.count>=40,
              let typical=quantile(neighborhood.map{$0.sub-$0.rest},0.9),
              let typicalSub=quantile(neighborhood.map{$0.sub},0.9),
              let typicalRest=quantile(neighborhood.map{$0.rest},0.5) else{continue}
        let dominance=s.sub-s.rest,excess=dominance-typical
        guard dominance>3,excess>6,s.sub>typicalSub+3,s.rest>typicalRest-6 else{continue}
        if let last=hits.last,s.start-last.end<0.15{
            hits[hits.count-1].end=s.start+s.duration
            hits[hits.count-1].dominance=max(last.dominance,dominance)
            hits[hits.count-1].excess=max(last.excess,excess)
        }else{hits.append(SubEvent(start:s.start,end:s.start+s.duration,dominance:dominance,excess:excess))}
    }
    return hits.filter{$0.end-$0.start>=0.19}.sorted{$0.excess>$1.excess}
}
func localSubRecommendation(_ a:Analysis)->MixRecommendation?{
    let events=localSubEvents(a.subSlices)
    guard let strongest=events.first else{return nil}
    let moments=events.prefix(3).map{String(format:"%.1f–%.1f s",$0.start,$0.end)}.joined(separator:", ")
    return MixRecommendation(id:"local-sub",title:"Korte uitschieters in het sublaag",evidence:"Luister bij \(moments). Het 20–80 Hz-filter domineert hier tijdelijk sterker tegenover >120 Hz dan in de omliggende tien seconden (sterkste extra contrast: \(display(strongest.excess)) dB). Filtergebieden overlappen; dit is geen meting van clipping, sidechain of een afzonderlijke kick.",action:"Luister of die lage slagen de rest kort wegdrukken of juist bewust accent geven. Alleen bij hoorbare onrust: vergelijk de uitspringende basnoten of kickstaarten in niveau en lengte voordat je het hele laag terugneemt.",start:strongest.start)
}
