import Foundation
func validateStereoPolicy()->[TestOutcome]{
 var results=[TestOutcome]()
 func check(_ name:String,_ ok:Bool){results.append(TestOutcome(name:name,passed:ok,detail:"Display policy; not auditory proof"))}
 check("Stereo policy: identical channels green",correlationVerdict(1,mono:0).level == .green && monoVerdict(0).level == .green)
 check("Stereo policy: independent channels normal -3.01 dB",correlationVerdict(0,mono:stereoHalfEnergyDB).level == .green && monoVerdict(stereoHalfEnergyDB).level == .green)
 check("Stereo policy: one-sided is not antiphase",correlationVerdict(nil,mono:stereoHalfEnergyDB).level == .unavailable && monoVerdict(stereoHalfEnergyDB).level == .green)
 check("Stereo policy: moderate negative correlation orange",correlationVerdict(-0.2,mono:10*log10(0.4)).level == .orange && monoVerdict(10*log10(0.4)).level == .orange)
 check("Stereo policy: quarter energy boundary red",correlationVerdict(-0.5,mono:stereoQuarterEnergyDB).level == .red && monoVerdict(stereoQuarterEnergyDB).level == .red)
 check("Stereo policy: above quarter energy orange",monoVerdict(stereoQuarterEnergyDB+0.001).level == .orange)
 check("Stereo policy: full cancellation red",correlationVerdict(-1,mono:nil,complete:true).level == .red && monoVerdict(nil,complete:true).level == .red)
 // Opposite polarity at 10:1 amplitude: rho=-1 but only ~4 dB normalized mono loss.
 let unequalMono=10*log10(0.9*0.9/(2*1.01))
 check("Stereo policy: unequal antiphase not automatic red",correlationVerdict(-1,mono:unequalMono).level == .orange)
 check("Stereo policy: mono source neutral",correlationVerdict(nil,mono:nil,channels:1).level == .unavailable && monoVerdict(nil,channels:1).level == .unavailable)
 check("Stereo policy: silence neutral",correlationVerdict(nil,mono:nil).level == .unavailable && monoVerdict(nil).level == .unavailable && crestVerdict(nil).level == .unavailable)
 check("Stereo policy: short audio neutral",correlationVerdict(1,mono:0,seconds:0.5).level == .unavailable && monoVerdict(0,seconds:0.5).level == .unavailable && crestVerdict(10,seconds:0.5).level == .unavailable)
 check("Crest policy: dense master only orange",crestVerdict(4).level == .orange)
 check("Crest policy: ordinary and sparse not condemned",crestVerdict(6).level == .green && crestVerdict(14).level == .green && crestVerdict(30).level == .green)
 check("Crest policy: no standalone red",(0...50).allSatisfy{crestVerdict(Double($0)).level != .red})
 check("Stereo policy: nonfinite neutral",correlationVerdict(.nan,mono:nil).level == .unavailable && monoVerdict(.nan).level == .unavailable && crestVerdict(.nan).level == .unavailable)
 return results
}
