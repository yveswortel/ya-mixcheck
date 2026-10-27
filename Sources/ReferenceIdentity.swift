import Foundation

// This is an exclusion heuristic, never a merger of recordings or source hashes.
// Keep the complete time sequence: an average spectrum cannot identify a recording.
struct ReferenceSignature: Codable, Sendable {
    var title:String; var hash:String; var duration:Double; var frames:[[Double]]
    static func make(title:String,hash:String,duration:Double,slices:[ToneSlice])->Self {
        let frames=slices.filter{$0.duration>=1.99}.map{s -> [Double] in
            // Ignore air (codec sensitive), retain level and six independent bands.
            [s.rms ?? -120] + s.bands.prefix(6).map{max(-100,$0 ?? -100)}
        }
        return Self(title:title,hash:hash,duration:duration,frames:frames)
    }
    func matches(_ other:Self)->Bool {
        guard abs(duration-other.duration)<=0.15,frames.count>=20,
              abs(frames.count-other.frames.count)<=1 else{return false}
        let pairs=zip(frames,other.frames).filter{$0.count==7 && $1.count==7 && $0.allSatisfy{$0.isFinite} && $1.allSatisfy{$0.isFinite} && $0[0] > -65 && $1[0] > -65}
        guard pairs.count>=20,Double(pairs.count)>=0.8*Double(min(frames.count,other.frames.count)) else{return false}
        let offsets=pairs.map{$0[0]-$1[0]}
        guard let gain=quantile(offsets,0.5),let spread=quantile(pairs.map{$0.0[0]},0.9),let bottom=quantile(pairs.map{$0.0[0]},0.1),spread-bottom>1 else{return false}
        // One global gain offset only: EQ/limiting changes must not be normalized away.
        let errors=pairs.flatMap{a,b in zip(a,b).map{abs($0-$1-gain)}}
        let levelErrors=offsets.map{abs($0-gain)}
        // Full temporal level agreement is stricter than spectral agreement. The existing
        // filterbank varies slightly with sample rate; never loosen the envelope to match it.
        return (quantile(levelErrors,0.5) ?? 999)<0.025 && (quantile(levelErrors,0.95) ?? 999)<0.12
            && (quantile(errors,0.5) ?? 999)<0.5 && (quantile(errors,0.95) ?? 999)<1.6
    }
}
struct ReferenceIdentity:Codable,Sendable {var hash:String;var title:String;var method:String}
struct ReferenceIdentities:Codable {
    var version:Int;var references:[ReferenceSignature]
    static let shared:Self = {
        guard let url=Bundle.main.url(forResource:"ReferenceIdentities",withExtension:"json"),let data=try? Data(contentsOf:url),let value=try? JSONDecoder().decode(Self.self,from:data),value.version==1 else{return Self(version:1,references:[])}
        return value
    }()
    func resolve(hash:String,duration:Double,slices:[ToneSlice])->ReferenceIdentity? {
        if let override=(UserDefaults.standard.dictionary(forKey:"referenceIdentityOverrides") as? [String:String])?[hash] {
            if override=="none" {return ReferenceIdentity(hash:"manual-distinct:"+hash,title:"Geen (handmatige correctie)",method:"manual-distinct")}
            if let ref=references.first(where:{$0.hash==override}) {return ReferenceIdentity(hash:ref.hash,title:ref.title,method:"manual")}
        }
        let candidate=ReferenceSignature.make(title:"",hash:hash,duration:duration,slices:slices)
        let matches=references.filter{$0.hash==hash || $0.matches(candidate)}
        let unique=Dictionary(grouping:matches,by:{$0.hash})
        guard unique.count==1,let match=matches.first else{return nil}
        return ReferenceIdentity(hash:match.hash,title:match.title,method:match.hash==hash ? "exact-hash":"time-spectrum-v1 (conservative heuristic)")
    }
}
