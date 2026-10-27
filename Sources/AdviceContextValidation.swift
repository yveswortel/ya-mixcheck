import Foundation
func validateAdviceContext()->[TestOutcome] {
    var out=[TestOutcome]()
    func check(_ n:String,_ p:Bool){out.append(TestOutcome(name:"Advice context: "+n,passed:p,detail:"Controlled time-support and direction fixtures"))}
    let high=MixRecommendation(id:"tone-5",title:"High · meer nadruk",evidence:"",action:"")
    let low=MixRecommendation(id:"tone-5",title:"High · minder nadruk",evidence:"",action:"")
    func windows(_ hits:Set<Int>,_ gain:Double=0)->[AdviceWindow]{(0..<10).map{i in AdviceWindow(start:Double(i*8),seconds:8,level:Double(i)-25+gain,advice:hits.contains(i) ? [high]:[])}}
    let local=supportedAdvice(windows([4]))
    check("single window stays local",local.count==1 && local[0].scope=="Lokaal / wisselend" && local[0].start==32 && abs(local[0].supportFraction!-0.1)<1e-9)
    let sustained=supportedAdvice(windows(Set(0..<8)))
    check("recurring windows sustained",sustained[0].scope=="Aanhoudend" && sustained[0].start==24)
    check("gain invariant selection",supportedAdvice(windows(Set(0..<8),12))[0].start==sustained[0].start)
    var alternating=windows([])
    for i in alternating.indices{alternating[i].advice=[i%2==0 ? high:low]}
    check("opposite directions do not merge",supportedAdvice(alternating).count==2 && supportedAdvice(alternating).allSatisfy{$0.scope=="Lokaal / wisselend"})
    check("no evidence no advice",supportedAdvice(windows([])).isEmpty)
    check("short track not persistent",supportedAdvice(Array(windows([0,1]).prefix(2))).allSatisfy{$0.scope != "Aanhoudend"})
    let repeated=supportedAdvice(windows(Set(0..<8)))
    check("deterministic tie break",repeated[0].start==sustained[0].start)
    var closeA=high;closeA.contrast=0.51
    var closeB=low;closeB.contrast=0.48
    let original=supportedAdvice([AdviceWindow(start:0,seconds:8,level:-20,advice:[closeA,closeB])])
    closeA.contrast=0.49;closeB.contrast=0.50
    let changed=supportedAdvice([AdviceWindow(start:0,seconds:8,level:-20,advice:[closeA,closeB])])
    check("near-equal salience ordering stable",original.map{adviceKey($0)}==changed.map{adviceKey($0)})
    return out
}
