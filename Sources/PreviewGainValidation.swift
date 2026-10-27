import Foundation

private final class PreviewGainTestHandle:@unchecked Sendable {
    // Only qcg_set_targets crosses threads; the render state stays on the caller.
    let value:OpaquePointer
    init(_ value:OpaquePointer){self.value=value}
}

func validatePreviewGain()->[TestOutcome] {
    var out=[TestOutcome]()
    func check(_ name:String,_ pass:Bool){out.append(TestOutcome(name:"Preview gain: "+name,passed:pass,detail:""))}
    check("invalid rate rejected",qcg_create(0,0.05)==nil)
    check("nonfinite fade rejected",qcg_create(48000,Double.nan)==nil)
    if let state=qcg_create(48000,0.05) {
        let fresh=qcg_has_rendered(state)==0
        qcg_set_rendered(state,1);let rendered=qcg_has_rendered(state)==1
        qcg_set_rendered(state,0)
        check("silent priming flag starts clear and can be reset",fresh && rendered && qcg_has_rendered(state)==0)
        qcg_destroy(state)
    }else{check("silent priming flag starts clear and can be reset",false)}
    for rate in [44100,48000,96000,192000] {for block in [1,127,512,4096] {
        let label="\(rate) Hz / block \(block)"
        guard let s=qcg_create(Double(rate),0.05) else{check(label+" lock-free state available",false);continue}
        defer{qcg_destroy(s)}
        let duration=UInt32((Double(rate)*0.05).rounded())
        var r=QCGainRamp(),count:UInt32=0,monotone=true,previous:Float=0
        qcg_set_targets(s,1,0)
        while count<duration {
            qcg_next(s,UInt32(block),&r)
            monotone = monotone && r.startA==previous && r.endA>=previous && r.endA<=1 && r.endB==0 && r.rampFrames<=UInt32(block) && r.remainingFrames==duration-count
            count+=r.rampFrames;previous=r.endA
        }
        check(label+" bounded fade reaches exact endpoint",monotone && count==duration && r.endA==1)
        qcg_set_targets(s,0,1);qcg_next(s,0,&r)
        check(label+" zero-frame call does not advance",r.startA==1 && r.endA==1 && r.rampFrames==0)
        count=0;var complementary=true
        while count<duration {
            qcg_next(s,UInt32(block),&r)
            complementary = complementary && abs(r.startA+r.startB-1)<0.000002 && abs(r.endA+r.endB-1)<0.000002 && r.targetA==0 && r.targetB==1
            count+=r.rampFrames
        }
        check(label+" complementary pair and final partial block",complementary && count==duration && r.endA==0 && r.endB==1)
        qcg_set_targets(s,1,0);qcg_next(s,max(1,duration/3),&r)
        let a=r.endA,b=r.endB
        qcg_set_targets(s,0,1);qcg_next(s,1,&r)
        check(label+" reversal continues from current levels",r.startA==a && r.startB==b && r.endA<=a && r.endB>=b && r.remainingFrames==duration)
        qcg_set_targets(s,Float.nan,-3);qcg_next(s,duration,&r)
        check(label+" invalid gains settle safely to silence",r.endA==0 && r.endB==0)
        qcg_set_targets(s,2,2);qcg_next(s,duration,&r);qcg_next(s,UInt32(block),&r)
        check(label+" gain bounded at unity and steady after ramp",r.startA==1 && r.startB==1 && r.endA==1 && r.endB==1 && r.rampFrames==0)
    }}
    if let s=qcg_create(48000,0.05) {
        defer{qcg_destroy(s)}
        var r=QCGainRamp();qcg_set_targets(s,1,0);qcg_next(s,2400,&r)
        let done=DispatchSemaphore(value:0),handle=PreviewGainTestHandle(s)
        DispatchQueue.global(qos:.userInitiated).async {
            for i in 0..<100000 {qcg_set_targets(handle.value,i%2==0 ? 0:1,i%2==0 ? 1:0)}
            done.signal()
        }
        var coherent=true
        for _ in 0..<100000 {qcg_next(s,127,&r);coherent = coherent && abs(r.endA+r.endB-1)<0.000002}
        let finished=done.wait(timeout:.now()+5) == .success
        check("concurrent target publication preserves paired gains",finished && coherent)
        // The writer is bounded; never free state while it still uses the pointer.
        if !finished {done.wait()}
    }else{check("concurrent target publication preserves paired gains",false)}
    return out
}
