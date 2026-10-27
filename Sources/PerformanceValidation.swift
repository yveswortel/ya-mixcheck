import Foundation

// Optional, slower lifecycle regression. Uses only generated scratch audio; it
// never plays audio or removes another session's cache. Long-stream RSS/time is
// measured separately by scripts/performance_release_check.py.
func validatePerformanceLifecycle(decodedFixture:URL? = nil)throws->[TestOutcome] {
    let fm=FileManager.default
    let root=fm.temporaryDirectory.appendingPathComponent("ya-performance-test-"+UUID().uuidString)
    try fm.createDirectory(at:root,withIntermediateDirectories:false)
    defer{try? fm.removeItem(at:root)}
    var results=[TestOutcome]()
    func check(_ name:String,_ passed:Bool,_ detail:String="") {
        results.append(TestOutcome(name:"Performance lifecycle: "+name,passed:passed,detail:detail))
    }
    func cachePaths()->Set<String> {
        Set(((try? fm.contentsOfDirectory(atPath:fm.temporaryDirectory.path)) ?? []).filter {
            $0.hasPrefix("ya-mixcheck-decode-") || $0.hasPrefix("YA-MixCheck-EQ-")
        })
    }
    let source=root.appendingPathComponent("scratch.wav"),rate=44100
    let samples=(0..<rate*8).flatMap{n->[Float] in
        let t=Double(n)/Double(rate)
        let left=Float(0.14*sin(2*Double.pi*83*t)+0.08*sin(2*Double.pi*997*t))
        let right=Float(0.13*sin(2*Double.pi*83*t)+0.07*sin(2*Double.pi*1009*t))
        return [left,right]
    }
    try writeTestAudio(source,samples:samples,rate:Double(rate),channels:2)
    let hash=try sha256(source)
    let before=cachePaths()
    for iteration in 1...3 {
        let token=Cancellation()
        var requestedAt:Double?,caught=false,detail="No cancellation error"
        do {
            let unexpected=try Analyzer.run(source,cancellation:token,progress:{p in
                if p>=0.1 && requestedAt==nil {
                    requestedAt=ProcessInfo.processInfo.systemUptime;token.cancel()
                }
            })
            unexpected.decodedAudio?.remove()
        } catch {
            caught=(error as? QCFailure)?.message=="Analyse geannuleerd."
            detail=error.localizedDescription
        }
        let latency=requestedAt.map{ProcessInfo.processInfo.systemUptime-$0}
        check("analysis cancellation \(iteration)",caught && latency != nil && latency!<1,
              "After progress callback: \(latency ?? -1) s; \(detail)")
    }
    let analysis=try Analyzer.run(source,makePreview:false)
    let previewSource=PreviewSource(analysis)
    let bands=[PreviewBand(hz:350,gain:2),PreviewBand(hz:5000,gain:-1.5)]
    for iteration in 1...3 {
        let token=Cancellation()
        var requestedAt:Double?,caught=false,detail="No cancellation error"
        do {
            let unexpected=try renderEQPreview(previewSource,bands:bands,cancellation:token,progress:{p in
                if p>=0.1 && requestedAt==nil {
                    requestedAt=ProcessInfo.processInfo.systemUptime;token.cancel()
                }
            })
            unexpected.remove()
        } catch {
            caught=(error as? QCFailure)?.message=="Analyse geannuleerd."
            detail=error.localizedDescription
        }
        let latency=requestedAt.map{ProcessInfo.processInfo.systemUptime-$0}
        check("EQ cancellation \(iteration)",caught && latency != nil && latency!<1,
              "After progress callback: \(latency ?? -1) s; \(detail)")
        check("cancelled EQ cache removed \(iteration)",cachePaths().subtracting(before).isEmpty)
    }
    var firstPreview:Analysis?
    for iteration in 1...3 {
        let preview=try renderEQPreview(previewSource,bands:bands,cancellation:Cancellation(),progress:{_ in})
        // Compare actual analysis values; container metadata is irrelevant.
        let rendered=try Analyzer.run(preview.url,makePreview:false)
        if let first=firstPreview {
            check("repeated EQ metrics identical \(iteration)",rendered.frames==first.frames &&
                  rendered.integrated==first.integrated && rendered.samplePeak==first.samplePeak &&
                  rendered.spectrum.count==first.spectrum.count &&
                  zip(rendered.spectrum,first.spectrum).allSatisfy{$0.hz==$1.hz && $0.db==$1.db})
        } else {firstPreview=rendered}
        check("completed EQ preserves frame count \(iteration)",rendered.frames==analysis.frames)
        preview.remove()
        check("completed EQ cache removed \(iteration)",cachePaths().subtracting(before).isEmpty)
    }
    if let decodedFixture {
        guard decodedFixture.pathExtension.lowercased()=="mp3" else {
            throw QCFailure(message:"Performance decoded fixture must be a generated MP3.")
        }
        let fixtureHash=try sha256(decodedFixture)
        for iteration in 1...3 {
            let token=Cancellation()
            var requestedAt:Double?,caught=false,sawCache=false,detail="No cancellation error"
            do {
                let unexpected=try Analyzer.run(decodedFixture,cancellation:token,progress:{p in
                    if p>=0.1 && requestedAt==nil {
                        sawCache = !cachePaths().subtracting(before).isEmpty
                        requestedAt=ProcessInfo.processInfo.systemUptime;token.cancel()
                    }
                })
                unexpected.decodedAudio?.remove()
            } catch {
                caught=(error as? QCFailure)?.message=="Analyse geannuleerd."
                detail=error.localizedDescription
            }
            let latency=requestedAt.map{ProcessInfo.processInfo.systemUptime-$0}
            check("MP3 cancellation \(iteration)",caught && latency != nil && latency!<1,
                  "After progress callback: \(latency ?? -1) s; \(detail)")
            check("MP3 cache existed before cancellation \(iteration)",sawCache)
            check("cancelled MP3 cache removed \(iteration)",cachePaths().subtracting(before).isEmpty)
        }
        let recovered=try Analyzer.run(decodedFixture)
        check("MP3 analysis recovers after cancellation",recovered.decodedAudio != nil && recovered.frames>0)
        recovered.decodedAudio?.remove()
        check("completed MP3 cache explicitly removed",cachePaths().subtracting(before).isEmpty)
        check("MP3 fixture unchanged",try sha256(decodedFixture)==fixtureHash)
    }
    let recovered=try Analyzer.run(source,makePreview:false)
    check("analysis values unchanged after cancellation and previews",
          recovered.frames==analysis.frames && recovered.integrated==analysis.integrated &&
          recovered.samplePeak==analysis.samplePeak && recovered.truePeakEstimate==analysis.truePeakEstimate)
    check("scratch source unchanged",try sha256(source)==hash)
    check("no owned caches left",cachePaths().subtracting(before).isEmpty)
    return results
}
