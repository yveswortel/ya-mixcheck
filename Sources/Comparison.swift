import Foundation

// Attenuation-only matching. Full-file peaks preserve headroom even when leaving a selected loop.
func comparisonGains(_ a:Analysis,_ b:Analysis?,levelA:Double?,levelB:Double?) -> (Double,Double) {
    guard let b,let la=levelA,let lb=levelB else{return (a.previewGainDB,b?.previewGainDB ?? 0)}
    let target=min(la,lb),ga=target-la,gb=target-lb
    let common=min(0,-1-(a.truePeakEstimate ?? a.samplePeak ?? -120)-ga,
                     -1-(b.truePeakEstimate ?? b.samplePeak ?? -120)-gb)
    return (ga+common,gb+common)
}
func relativeLowBands(_ a:Analysis,_ b:Analysis) -> [Double?] {
    guard let la=a.integrated,let lb=b.integrated else{return Array(repeating:nil,count:5)}
    return zip(a.lowBandDBFS,b.lowBandDBFS).map { x,y in
        guard let x,let y,x > -90,y > -90 else{return nil}
        return x-y-(la-lb)
    }
}
