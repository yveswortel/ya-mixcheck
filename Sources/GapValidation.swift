import Foundation
func validateGapBoundaries()->[TestOutcome] {
    var tests=[TestOutcome]()
    for rate in [44100.0,48000.0,96000.0] {
        for ms in [1.0,5,10,19,20,21,29,30,100] {
            for offset in [0.0,0.003,0.009] {
                let n=Int(rate*0.5),start=Int(rate*(0.2+offset)),length=Int((rate*ms/1000).rounded())
                var x=(0..<n).map{Float(0.2*sin(2*Double.pi*173*Double($0)/rate))}
                for i in start..<start+length{x[i]=0}
                let d=DiscontinuityDetector(rate:rate,channels:1)
                x.withUnsafeBufferPointer{b in
                    var pos=0
                    while pos<n {let size=min(257,n-pos);d.push(b.baseAddress!+pos,frames:size);pos+=size}
                }
                let gaps=d.events.filter{$0.kind=="silence"}
                let correct=gaps.count==1 && abs(gaps[0].startFrame-Int64(start))<=1 && abs(gaps[0].endFrame-Int64(start+length))<=1
                tests.append(TestOutcome(name:"Digital gap \(ms)ms / \(Int(rate))Hz / offset \(offset)",passed:correct,detail:"Exactly one sample-aligned gap across 257-frame input chunks; got \(gaps.count)"))
            }
        }
    }
    // Silent files and deliberate fades must not become an export-failure signal.
    let sr=48000.0
    for kind in ["silent","fade-stop","sub-sine"] {
        let n=48000
        let x=(0..<n).map { i -> Float in
            let t=Double(i)/sr
            let env=kind=="silent" ? 0 : kind=="fade-stop" ? max(0,min(1,(0.4-t)/0.1)) : 1
            return Float(env*0.2*sin(2*Double.pi*40*t))
        }
        let d=DiscontinuityDetector(rate:sr,channels:1)
        x.withUnsafeBufferPointer{d.push($0.baseAddress!,frames:n)}
        tests.append(TestOutcome(name:"Gap negative control: \(kind)",passed:d.events.filter{$0.kind=="silence"}.isEmpty,detail:"No abrupt internal silence"))
    }
    // Same zero interval, varied recovery envelope; not tied to the user's edit.
    for rate in [44100.0,48000.0,96000.0] {
        for fadeOutMS in [0.0,1.0,20.0,50.0,100.0] {
            for fadeInMS in [5.0,15.0,30.0] {
              for gapMS in [12.0,100.0] {
                let start=Int(rate*0.25),end=start+Int(rate*gapMS/1000),n=Int(rate*0.5)
                let down=Int(rate*fadeOutMS/1000),up=Int(rate*fadeInMS/1000)
                var x=[Float](repeating:0,count:n)
                for i in 0..<n {
                    var envelope=1.0
                    if i>=start && i<end {envelope=0}
                    else if down>0 && i>=start-down && i<start {envelope=Double(start-i)/Double(down)}
                    else if i>=end && i<end+up {envelope=Double(i-end)/Double(up)}
                    x[i]=Float(envelope*0.2*sin(2*Double.pi*233*Double(i)/rate))
                }
                let d=DiscontinuityDetector(rate:rate,channels:1)
                x.withUnsafeBufferPointer { b in
                    var pos=0
                    while pos<n {let size=min(127,n-pos);d.push(b.baseAddress!+pos,frames:size);pos+=size}
                }
                let gaps=d.events.filter{$0.kind=="silence"}
                let expected=fadeOutMS<=1
                tests.append(TestOutcome(name:"Recovery \(fadeInMS)ms after \(fadeOutMS)ms fade-out, gap \(gapMS)ms / \(Int(rate))Hz",passed:expected ? gaps.count==1 : gaps.isEmpty,detail:"Abrupt losses flagged, smooth intentional fades unflagged"))
              }
            }
        }
    }
    // Quantized near-silence, offset boundaries and microfades: independent of music labels.
    for rate in [44100.0,48000.0,96000.0] {
      for gapMS in [20.0,25.0,29.0,100.0] {
       for fadeMS in [0.0,2.0,5.0,10.0,50.0] {
        for offset in [0.001,0.007] {
         let n=Int(rate*0.6),start=Int(rate*(0.25+offset)),end=start+Int((rate*gapMS/1000).rounded()),down=Int(rate*fadeMS/1000)
         var x=[Float](repeating:0,count:n)
         for i in 0..<n {
           let env=i>=start && i<end ? 0.0 : (down>0 && i>=start-down && i<start ? Double(start-i)/Double(down):1.0)
           let noise=i%3==0 ? 1.0/65536 : -1.0/65536
           x[i]=Float(0.2*sin(2*Double.pi*233*Double(i)/rate)*env+noise)
         }
         let d=DiscontinuityDetector(rate:rate,channels:1)
         x.withUnsafeBufferPointer{b in var pos=0;while pos<n{let count=min(127,n-pos);d.push(b.baseAddress!+pos,frames:count);pos+=count}}
         let gaps=d.events.filter{$0.kind=="silence"}
         // 2–10ms edits are intentionally ambiguous: record, don't invent ground-truth intent.
         let ok=fadeMS==0 ? gaps.count==1 : fadeMS>=50 ? gaps.isEmpty : true
         tests.append(TestOutcome(name:"Near-silent gap \(gapMS)ms fade \(fadeMS)ms / \(Int(rate)) offset \(offset)",passed:ok,detail:"candidates=\(gaps.count); microfade intent ambiguous"))
        }
       }
      }
    }
    return tests
}
