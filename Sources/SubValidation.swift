import Foundation
func validateSubBalance()->[TestOutcome]{
    var out=[TestOutcome]()
    func check(_ name:String,_ pass:Bool){out.append(TestOutcome(name:"Sub context: "+name,passed:pass,detail:"Controlled signal; no perceptual quality claim"))}
    func render(_ rate:Double,_ mode:Int,_ gain:Double=1,_ chunk:Int=8192)->[SubSlice]{
        let count=Int(rate*16),d=SubDetector(rate:rate,channels:2)
        var samples=[Float](repeating:0,count:count*2)
        for i in 0..<count{
            let t=Double(i)/rate
            let burst=t>=8 && t<8.5
            let bass=mode==1 && burst ? 0.65:0.08
            let rest=mode==2 && burst ? 0.001:0.08
            let x=gain*(bass*sin(2*Double.pi*45*t)+rest*sin(2*Double.pi*1000*t))
            samples[i*2]=Float(x);samples[i*2+1]=Float(-x)
        }
        samples.withUnsafeBufferPointer{p in for start in stride(from:0,to:count,by:chunk){d.push(p.baseAddress!.advanced(by:start*2),frames:min(chunk,count-start))}}
        d.emit();return d.slices
    }
    for rate in [44100.0,48000,96000,192000]{
        let normal=render(rate,0),burst=render(rate,1),drop=render(rate,2)
        let events=localSubEvents(burst)
        check("steady bass not an outlier at \(rate)",localSubEvents(normal).isEmpty)
        check("sub burst detected at \(rate)",events.contains{$0.start>=7.9 && $0.start<8.5})
        check("missing mids alone not a sub burst at \(rate)",localSubEvents(drop).isEmpty)
        let quieter=localSubEvents(render(rate,1,0.25,137))
        check("gain/chunk invariance at \(rate)",events.count==quieter.count && zip(events,quieter).allSatisfy{abs($0.start-$1.start)<0.001 && abs($0.excess-$1.excess)<0.001})
    }
    check("insufficient audio",localSubEvents([]).isEmpty)
    return out
}
