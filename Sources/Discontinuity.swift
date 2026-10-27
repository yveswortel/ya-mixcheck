import Foundation

struct AudioAnomaly: Codable, Identifiable, Sendable {
    var id:Int; var kind:String; var startFrame:Int64; var endFrame:Int64; var channel:Int
}
// Conservative candidates, never proof of an export failure. Constant-memory streaming.
final class DiscontinuityDetector {
    let rate:Double, channels:Int, block:Int
    var frame:Int64=0, filled=0
    var previous:[Double], older:[Double], noise:[Double], square:[Double]
    var lastDB:[Double], gapStart:[Int64?], gapActive:[Bool], lastClick:[Int64]
    struct Candidate {var frame:Int64;var edge:Double;var sum=0.0;var samples=0}
    var pending:[Candidate?]
    var slowPower:[Double],zeroAbrupt:[Bool]
    var exactFrames:[Int64],maxExactFrames:[Int64]
    var power:[Double],zeroStart:[Int64?],zeroBefore:[Double]
    struct ShortGap {var start:Int64;var end:Int64;var before:Double;var energy=0.0;var samples=0}
    var shortGap:[ShortGap?]
    var events=[AudioAnomaly](), count=0
    init(rate:Double,channels:Int) {
        self.rate=rate;self.channels=channels;pending=Array(repeating:nil,count:channels);block=max(1,Int(rate*0.01))
        previous=Array(repeating:0,count:channels);older=previous;noise=previous;square=previous
        slowPower=previous;exactFrames=Array(repeating:0,count:channels);maxExactFrames=exactFrames;zeroAbrupt=Array(repeating:false,count:channels)
        power=previous;zeroBefore=previous;zeroStart=Array(repeating:nil,count:channels);shortGap=Array(repeating:nil,count:channels)
        lastDB=Array(repeating:-200,count:channels);gapStart=Array(repeating:nil,count:channels)
        gapActive=Array(repeating:false,count:channels);lastClick=Array(repeating:-1000000,count:channels)
    }
    func add(_ kind:String,_ start:Int64,_ end:Int64,_ c:Int) {
        // Exact-zero and block-energy paths may describe the same gap. Merge by
        // overlap and channel so boundary alignment cannot duplicate a marker.
        if kind=="silence",let i=events.lastIndex(where:{$0.kind==kind && $0.channel==c && $0.startFrame<=end && $0.endFrame>=start}) {
            events[i].startFrame=min(events[i].startFrame,start)
            events[i].endFrame=max(events[i].endFrame,end)
            return
        }
        count+=1
        if events.count<512 {events.append(AudioAnomaly(id:count,kind:kind,startFrame:start,endFrame:end,channel:c))}
    }
    func push(_ p:UnsafePointer<Float>,frames:Int) {
        let alpha=1-exp(-1/(rate*0.003)),slowAlpha=1-exp(-1/(rate*0.03))
        for n in 0..<frames {
            for c in 0..<channels {
                let x=Double(p[n*channels+c]),a=previous[c]-older[c],b=x-previous[c]
                if var gap=shortGap[c] {
                    gap.energy+=x*x;gap.samples+=1
                    if gap.samples>=max(1,Int(rate*0.003)) {
                        if gap.energy/Double(gap.samples)>max(3.1623e-5,gap.before*0.0631) {
                            add("silence",gap.start,gap.end,c);shortGap[c]=nil
                        } else if gap.samples<Int(rate*0.03) {
                            shortGap[c]=gap
                        } else {shortGap[c]=nil}
                    } else {shortGap[c]=gap}
                }
                if abs(x)<=0.0000316227766 {
                    if zeroStart[c]==nil {exactFrames[c]=0;maxExactFrames[c]=0;zeroStart[c]=frame;zeroBefore[c]=power[c]
                        // Extended recovery is reserved for relatively abrupt loss of
                        // active audio. A fading envelope is not evidence of a dropout.
                        zeroAbrupt[c]=power[c]>slowPower[c]*0.1}
                    exactFrames[c]=x==0 ? exactFrames[c]+1:0;maxExactFrames[c]=max(maxExactFrames[c],exactFrames[c])
                } else if let start=zeroStart[c] {
                    let length=frame-start
                    if length>=max(32,Int64((rate*(maxExactFrames[c]>=max(32,Int64(rate*0.001)) ? 0.001:0.020)).rounded())),length<=Int64(rate*10),zeroBefore[c]>3.1623e-5,zeroAbrupt[c] {
                        shortGap[c]=ShortGap(start:start,end:frame,before:zeroBefore[c],energy:x*x,samples:1)
                    }
                    zeroStart[c]=nil
                }
                power[c]+=alpha*(x*x-power[c]);slowPower[c]+=slowAlpha*(x*x-slowPower[c])
                if var candidate=pending[c] {
                    candidate.sum+=abs(b);candidate.samples+=1
                    if candidate.samples>=Int(rate*0.003) {
                        if candidate.edge>16*candidate.sum/Double(candidate.samples) {add("click",candidate.frame,candidate.frame+1,c)}
                        pending[c]=nil
                    }else{pending[c]=candidate}
                }
                // Isolated one-sample impulse: two large opposite edges, close neighbours,
                // and much larger than the preceding local derivative envelope.
                if frame>Int64(rate*0.02),a*b<0,min(abs(a),abs(b))>max(0.04,noise[c]*16),abs(x-older[c])<min(abs(a),abs(b))*0.25,frame-lastClick[c]>Int64(rate*0.02) {
                    pending[c]=Candidate(frame:frame-1,edge:min(abs(a),abs(b)));lastClick[c]=frame
                }
                // A splice can be a single large step without an immediate return.
                // Both derivative neighborhoods must be quiet relative to the step.
                if frame>Int64(rate*0.02),abs(b)>max(0.004,noise[c]*24),frame-lastClick[c]>Int64(rate*0.02) {
                    pending[c]=Candidate(frame:frame,edge:abs(b));lastClick[c]=frame
                }
                noise[c]+=alpha*(abs(b)-noise[c]);older[c]=previous[c];previous[c]=x;square[c]+=x*x
            }
            frame+=1;filled+=1
            if filled==block {
                for c in 0..<channels {
                    let db=10*log10(max(1e-20,square[c]/Double(block)))
                    if db < -90 {
                        if gapStart[c]==nil {gapStart[c]=frame-Int64(block);gapActive[c]=lastDB[c] > -45 && (zeroStart[c]==nil || zeroAbrupt[c])}
                    } else if let start=gapStart[c] {
                        let length=Double(frame-Int64(block)-start)/rate
                        if gapActive[c],db > -45,length>=0.02,length<=10 {add("silence",start,frame-Int64(block),c)}
                        gapStart[c]=nil;gapActive[c]=false
                    }
                    lastDB[c]=db;square[c]=0
                }
                filled=0
            }
        }
    }
}
extension Analysis {
    var anomalyOpinions:[Opinion] {
        ["click","silence"].compactMap{kind in
            let matches=anomalies.filter{$0.kind==kind}
            guard let first=matches.first else{return nil}
            return Opinion(id:kind,category:"Luistercontrole",title:kind=="click" ? "Mogelijke losse kliks":"Abrupte stilte tussen actieve audio",evidence:"\(matches.count) opgeslagen kandidaatmomenten (kanaalsgewijs). "+(kind=="click" ? "Zeer korte uitschieters ten opzichte van de lokale golfvorm.":"Digitale gaten van 1 ms–10 s of bijna stilte van 20 ms–10 s, met actieve audio ervoor en erna."),action:"Beluister de markeringen en vergelijk met je project. Transiënten, edits en bewuste stops kunnen hetzelfde patroon geven. Uitval van één instrument terwijl andere doorspelen wordt hiermee niet betrouwbaar herkend.",startFrame:first.startFrame)
        }
    }
}
