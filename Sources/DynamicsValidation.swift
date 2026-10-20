import Foundation
func validateDynamics()->[TestOutcome]{
    var outcomes=[TestOutcome]()
    func check(_ name:String,_ passed:Bool,_ detail:String=""){outcomes.append(TestOutcome(name:name,passed:passed,detail:detail))}
    func measure(_ x:[Float],rate:Int,chunk:Int=8192)->DynamicsSummary{
        let d=DynamicsDetector(rate:Double(rate),channels:1)
        x.withUnsafeBufferPointer{p in var at=0;while at<x.count{let n=min(chunk,x.count-at);d.push(p.baseAddress!+at,frames:n);at+=n}}
        d.emit();return summarizeDynamics(d.slices)
    }
    for rate in [44100,48000,88200,96000,176400,192000]{
        let x=(0..<rate*20).map{n ->Float in
            let t=Double(n)/Double(rate),phase=t.truncatingRemainder(dividingBy:0.5)
            let env=0.08+0.65*exp(-phase*24)
            return Float(env*(0.7*sin(2*Double.pi*100*t)+0.3*sin(2*Double.pi*1700*t)))
        }
        let a=measure(x,rate:rate),gain=measure(x.map{$0*0.25},rate:rate),chunk=measure(x,rate:rate,chunk:127)
        guard a.density != nil,a.punch != nil,a.movement != nil,gain.density != nil,gain.punch != nil,gain.movement != nil else{check("Dynamics \(rate): sufficient fixture",false,"seconds \(a.seconds)");continue}
        check("Dynamics \(rate): gain invariant",abs(a.density!-gain.density!)<0.0001 && abs(a.punch!-gain.punch!)<0.0001 && abs(a.movement!-gain.movement!)<0.0001)
        check("Dynamics \(rate): chunk invariant",a.density==chunk.density && a.punch==chunk.punch && a.movement==chunk.movement)
        var envelope=0.0
        let compressed=x.map{v ->Float in
            let level=abs(Double(v)),coefficient=exp(-1/(Double(rate)*(level>envelope ? 0.002:0.08)))
            envelope=coefficient*envelope+(1-coefficient)*level
            let g=envelope>0.06 ? pow(envelope/0.06,-0.75):1
            return Float(Double(v)*g)
        }
        let c=measure(compressed,rate:rate)
        check("Dynamics \(rate): controlled 4:1 compression reduces onset",(c.punch ?? 999)<a.punch!-6,"density \(a.density!) → \(String(describing:c.density)); punch \(a.punch!) → \(String(describing:c.punch))")
        let clipped=measure(x.map{max(-0.12,min(0.12,$0))},rate:rate)
        check("Dynamics \(rate): hard clipping raises density",(clipped.density ?? -999)>a.density!+3)
        let leveled=x.enumerated().map{n,v in v*(n<rate*10 ? 0.25:1)}
        let movement=measure(leveled,rate:rate)
        check("Dynamics \(rate): section level change increases movement",(movement.movement ?? -999)>a.movement!+8)
    }
    let silence=measure(Array(repeating:0,count:48000*12),rate:48000)
    check("Dynamics silence unavailable",silence.density==nil && silence.punch==nil && silence.movement==nil)
    let short=measure(Array(repeating:Float(0.1),count:48000*4),rate:48000)
    check("Dynamics short passage unavailable",short.density==nil)
    return outcomes
}
