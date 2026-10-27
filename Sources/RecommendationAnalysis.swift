import Foundation

// Request-local reuse, never a global cache: one immutable source/genre/section set.
// Confined to the caller's worker. A new request cannot reuse another request's state.
final class RecommendationAnalysis {
    let analysis:Analysis,genre:String,sections:[ArrangementSection],library:DynamicsLibrary
    init(_ analysis:Analysis,genre:String,sections:[ArrangementSection]?=nil,library:DynamicsLibrary = .shared) {
        self.analysis=analysis;self.genre=genre;self.library=library
        self.sections=sections ?? arrangement(analysis.toneSlices,duration:analysis.duration)
    }
    lazy var tone=assessTone(analysis.toneSlices,genre:genre,hash:analysis.assessmentHash)
    lazy var dynamics=trackDynamics(analysis,genre:genre,library:library)
    lazy var index=DynamicsSliceIndex(analysis.dynamics)
    lazy var passages=passageDynamics(analysis,sections:sections,genre:genre,library:library,index:index)
}

// The extractor emits ordered features. Binary bounds avoid rescanning the full
// track for every section/8-second advice window; preserve the old end tolerance.
struct DynamicsSliceIndex {
    let slices:[DynamicsSlice]
    let ordered:Bool
    init(_ slices:[DynamicsSlice]) {
        self.slices=slices
        ordered=slices.allSatisfy{$0.start.isFinite && $0.duration.isFinite && $0.duration>=0} &&
            zip(slices,slices.dropFirst()).allSatisfy{$0.start <= $1.start}
    }
    func within(start:Double,end:Double)->[DynamicsSlice] {
        guard ordered,start.isFinite,end.isFinite else {
            return slices.filter{$0.start>=start && $0.start+$0.duration<=end+0.001}
        }
        func bound(_ value:Double)->Int {
            var lo=0,hi=slices.count
            while lo<hi {let mid=(lo+hi)/2;if slices[mid].start<value{lo=mid+1}else{hi=mid}}
            return lo
        }
        let lower=bound(start),upper=bound((end+0.001).nextUp)
        guard lower<upper else{return []}
        return slices[lower..<upper].filter{$0.start+$0.duration<=end+0.001}
    }
}
