import Foundation

func validateReports(_ original:Analysis)throws->[TestOutcome] {
    var outcomes=[TestOutcome]()
    func check(_ name:String,_ passed:Bool){outcomes.append(TestOutcome(name:"Report: "+name,passed:passed,detail:""))}
    var a=original
    a.originalSource="/private/example/hidden/=mix,\"<script>test.wav"
    a.integrated=nil;a.monoLoss=nil;a.completeMonoCancellation=true
    a.windowStartFrame=Int64(a.sampleRate*10)
    a.anomalies=[AudioAnomaly(id:1,kind:"silence",startFrame:Int64(a.sampleRate),endFrame:Int64(a.sampleRate*1.25),channel:1)]
    a.incidents=[Incident(id:0,startFrame:0,endFrame:0,channel:0)]
    let r=ReportSnapshot(a,genre:"Unknown <genre>",purpose:"Mix voor mastering",bounds:nil,created:Date(timeIntervalSince1970:0))
    let html=r.html(), csv=String(decoding:try r.data(.csv),as:UTF8.self)
    let json=try JSONSerialization.jsonObject(with:r.data(.json)) as! [String:Any]
    check("HTML escapes names and context",html.contains("&lt;script&gt;") && !html.contains("<script>") && html.contains("Unknown &lt;genre&gt;"))
    check("No source-directory disclosure",!html.contains("/private/example") && !csv.contains("/private/example") && json["originalSource"]==nil && json["inputSnapshot"]==nil && json["decodedAudio"]==nil)
    check("Missing values and complete mono cancellation explicit",html.contains("Niet beschikbaar") && html.contains("Volledige uitdoving") && json["integrated"] is NSNull)
    check("CSV escaping and formula neutralization",ReportSnapshot.csvCell("=1,\"2\"")=="\"'=1,\"\"2\"\"\"" && ReportSnapshot.csvCell("  @SUM(A1)").hasPrefix("\"'"))
    let marker=r.markers.first{$0.kind=="silence"}!
    check("Marker offset and channels",abs(marker.start-11)<1e-10 && abs(marker.end-11.25)<1e-10 && marker.channel==2)
    let over=r.markers.first{$0.kind=="overrange"}!
    check("Inclusive overrange frame becomes exclusive endpoint",abs(over.start-10)<1e-10 && abs(over.end-10-1/a.sampleRate)<1e-10)
    check("Provenance and marker cap",csv.contains(a.sha256) && csv.contains("512") && html.contains(ToneLibrary.shared.version))
    check("Advice matches GUI model and cap",r.advice.map{$0.id}==Array(mixRecommendations(a,genre:r.genre,purpose:r.purpose).prefix(3)).map{$0.id} && r.advice.count<=3)
    check("JSON preserves chosen context",(json["adviceContext"] as? [String:String])?["genre"]==r.genre && json["reportScope"] != nil)
    check("Exact source interval included",(json["analyzedSourceInterval"] as? [String:Double])?["startSeconds"]==10)
    check("Missing measurements have no success claim",a.measurementStatuses["integrated"]=="insufficient_or_below_gate" && a.measurementClaims.first{$0.id=="integrated"}?.value==nil)
    check("Build identity and print layout present",json["reportBuild"] != nil && html.contains("thead{display:table-header-group}") && html.contains("overflow-wrap:anywhere"))
    let known=MeasurementClaims.testedMeterSources
    check("Validation source guard",MeasurementClaims.meterSourcesMatch(known)==true && MeasurementClaims.meterSourcesMatch([:])==false && MeasurementClaims.meterSourcesMatch(nil)==nil)
    var scope=a;scope.sampleRate=44100
    check("44.1 kHz never marked officially tested",scope.truePeakInterpolationFactor==4 && scope.validationEvidence["currentRateAndChannelsWithinSuite"] as? Bool==false && scope.validationEvidence["allSampleRatesValidated"] as? Bool==false && scope.validationEvidence["certified"] as? Bool==false && !scope.measurementStatuses.values.contains{$0.contains("suite_passed")})
    scope.sampleRate=48000;scope.channels=2
    check("48 kHz suite scope explicit",scope.validationEvidence["currentRateAndChannelsWithinSuite"] as? Bool==true)
    scope.channels=6
    check("Surround outside minimum test scope",scope.validationEvidence["currentRateAndChannelsWithinSuite"] as? Bool==false)
    scope.frames=Int64(scope.sampleRate*3);scope.lra=0
    check("Short-program LRA distinguished",scope.measurementStatuses["lra"]=="measured_short_program")
    var highRate=a;highRate.sampleRate=192000;highRate.samplePeak = -3.25;highRate.truePeakEstimate = -3.25
    highRate.integrated = -20
    let highRateReport=ReportSnapshot(highRate,genre:r.genre,purpose:r.purpose)
    let highRateHTML=highRateReport.html()
    check("192 kHz HTML labels sample peak without true-peak claim",highRateHTML.contains("<td>Samplepeak · geen true-peakinterpolatie</td><td>-3.25 dBFS</td>") && !highRateHTML.contains("<td>True peak</td>"))
    let highRateJSON=try JSONSerialization.jsonObject(with:highRateReport.data(.json)) as! [String:Any]
    check("192 kHz JSON excludes sample-only true peak and PLR",highRateJSON["truePeakEstimate"] is NSNull && highRateJSON["plr"] is NSNull && highRateJSON["samplePeakToLoudness"] as? Double==16.75 && highRateJSON["truePeakInterpolationFactor"] as? Int==1 && highRate.measurementStatuses["truePeakEstimate"]=="not_measured_no_interpolation")
    check("192 kHz sample gap consistently labeled",highRateHTML.contains("<td>Samplepiek − LUFS</td><td>16.75 dB</td>") && highRate.measurementClaims.first{$0.id=="peak"}?.unit=="dBFS")
    highRate.sampleRate=176400;highRate.truePeakEstimate = -2.75
    let interpolatedHTML=ReportSnapshot(highRate,genre:r.genre,purpose:r.purpose).html()
    check("176.4 kHz HTML keeps separate interpolated and sample peaks",interpolatedHTML.contains("<td>True peak</td><td>-2.75 dBTP</td>") && interpolatedHTML.contains("<td>Samplepeak</td><td>-3.25 dBFS</td>"))
    let interpolatedJSON=try JSONSerialization.jsonObject(with:highRate.json()) as! [String:Any]
    check("176.4 kHz JSON retains true peak and PLR",interpolatedJSON["truePeakEstimate"] as? Double == -2.75 && interpolatedJSON["plr"] as? Double==17.25 && highRate.truePeakInterpolationFactor==2)
    check("M/S maxima exported in readable report",interpolatedHTML.contains("<td>Momentary max</td>") && interpolatedHTML.contains("<td>Short-term max</td>"))
    if let genre=ToneLibrary.shared.references.first?.genre {
        let tone=assessTone(original.toneSlices,genre:genre,hash:original.assessmentHash)
        let tonalHTML=ReportSnapshot(original,genre:genre,purpose:r.purpose).html()
        let bands=tone.bands.filter{$0.delta != nil && $0.lower != nil && $0.upper != nil && $0.median != nil}
        check("Report tonal values use GUI median-centered scale",!bands.isEmpty && bands.allSatisfy{b in
            let cells="<td>"+ReportSnapshot.htmlEscape(b.name)+"</td><td>"+display(b.delta,2)+" dB</td><td>"+display(b.lower!-b.median!,2)+" tot "+display(b.upper!-b.median!,2)+" dB</td>"
            return tonalHTML.contains(cells)
        })
    }
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent("ya-report-test-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:directory)}
    let output=directory.appendingPathComponent("report.html"), data=Data(html.utf8)
    try writeNewReport(data,to:output)
    do{try writeNewReport(Data("overwrite".utf8),to:output);check("Existing report protected",false)}catch{check("Existing report protected",try Data(contentsOf:output)==data)}
    let link=directory.appendingPathComponent("link.html");try FileManager.default.createSymbolicLink(at:link,withDestinationURL:output)
    do{try writeNewReport(Data("overwrite".utf8),to:link);check("Symlink protected",false)}catch{check("Symlink protected",try Data(contentsOf:output)==data)}
    return outcomes
}
