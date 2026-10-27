import Foundation
func validateReferenceIdentity()->[TestOutcome] {
    var out=[TestOutcome]()
    func check(_ name:String,_ ok:Bool){out.append(TestOutcome(name:name,passed:ok,detail:"reference identity exclusion"))}
    let refs=ReferenceIdentities.shared.references
    check("Identity asset covers all tonal references",ToneLibrary.shared.references.allSatisfy{r in refs.contains{r.hashes.contains($0.hash)}})
    check("Identity hashes cover dynamics references",DynamicsLibrary.shared.references.allSatisfy{r in refs.contains{r.hashes.contains($0.hash)}})
    for ref in refs {
        var gain=ref;gain.hash="different-container";gain.frames=ref.frames.map{$0.map{$0-7}}
        check("Identity gain invariant: \(ref.title)",ref.matches(gain))
        var eq=ref;eq.frames=ref.frames.map{v in var v=v;v[2]+=2;return v}
        check("Identity rejects changed EQ: \(ref.title)",!ref.matches(eq))
    }
    var falseMatches=[String]()
    for a in refs {for b in refs where a.hash != b.hash {if a.matches(b){falseMatches.append(a.title+" / "+b.title)}}}
    out.append(TestOutcome(name:"Identity distinct reference recordings",passed:falseMatches.isEmpty,detail:falseMatches.joined(separator:"; ")))
    if let ref=refs.first {
        var shuffled=ref;shuffled.frames.reverse()
        check("Identity rejects reordered arrangement",!ref.matches(shuffled))
        var short=ref;short.frames=Array(short.frames.prefix(5))
        check("Identity rejects insufficient evidence",!ref.matches(short))
        var invalid=ref;invalid.frames=ref.frames.map{_ in [Double.nan]}
        check("Identity rejects malformed values",!ref.matches(invalid))
    }
    return out
}
