import Foundation

enum ReportFormat:String,CaseIterable {case html, csv, json}
struct ReportMarker {
    var kind:String;var start:Double;var end:Double;var channel:Int?;var title:String;var certainty:String
}
// Exports describe the analyzed snapshot. They never include audio or private paths.
struct ReportSnapshot {
    let analysis:Analysis, reference:Analysis?
    let genre:String, purpose:String
    let bounds:[Double]?
    let created:Date
    init(_ analysis:Analysis,reference:Analysis?=nil,genre:String,purpose:String,bounds:[Double]?=nil,created:Date=Date()) {
        self.analysis=analysis;self.reference=reference;self.genre=genre;self.purpose=purpose;self.bounds=bounds;self.created=created
    }
    var name:String {URL(fileURLWithPath:analysis.originalSource ?? analysis.source).lastPathComponent}
    var interval:[String:Double] {let start=Double(analysis.windowStartFrame)/analysis.sampleRate;return ["startSeconds":start,"endSeconds":start+analysis.duration]}
    var buildIdentity:[String:Any] {
        guard let m=MeasurementClaims.manifest else{return ["status":"unavailable"]}
        return ["sourceSHA256":m["sourceSHA256"] ?? NSNull(),"builtAtUTC":m["builtAtUTC"] ?? NSNull(),"release":m["release"] ?? NSNull()]
    }
    var advice:[MixRecommendation] {Array(mixRecommendations(analysis,genre:genre,purpose:purpose).prefix(3))}
    var sections:[ArrangementSection] {arrangement(analysis.toneSlices,duration:analysis.duration,manual:bounds)}
    var markers:[ReportMarker] {
        let a=analysis, offset=Double(a.windowStartFrame)/a.sampleRate
        var result=sections.map{ReportMarker(kind:"section",start:$0.start+offset,end:$0.end+offset,channel:nil,title:$0.label,certainty:$0.change)}
        result += advice.compactMap{tip in tip.start.map{ReportMarker(kind:"advice",start:$0+offset,end:$0+offset,channel:nil,title:tip.title,certainty:tip.scope ?? "Luisteradvies")}}
        result += a.anomalies.map{ReportMarker(kind:$0.kind,start:Double($0.startFrame)/a.sampleRate+offset,end:Double($0.endFrame)/a.sampleRate+offset,channel:$0.channel+1,title:$0.kind=="click" ? "Mogelijke klik":"Abrupte stilte",certainty:"Luisterkandidaat; geen bewezen exportfout")}
        result += a.incidents.map{ReportMarker(kind:"overrange",start:Double($0.startFrame)/a.sampleRate+offset,end:Double($0.endFrame+1)/a.sampleRate+offset,channel:$0.channel+1,title:"Samples buiten ±1",certainty:a.codec.hasPrefix("MP3") ? "Na MP3-decode; geen bewijs van bronclipping":"Gemeten samplewaarden; hoorbaarheid niet vastgesteld")}
        result += a.clipping.events.map{ReportMarker(kind:"plateau",start:Double($0.startFrame)/a.sampleRate+offset,end:Double($0.endFrame+1)/a.sampleRate+offset,channel:$0.channel+1,title:"Golfvormplateau",certainty:"Heuristisch clippingbewijs; luistercontrole nodig")}
        return result.sorted{($0.start,$0.kind,$0.channel ?? 0)<($1.start,$1.kind,$1.channel ?? 0)}
    }
    static func htmlEscape(_ text:String)->String {
        text.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:">",with:"&gt;").replacingOccurrences(of:"\"",with:"&quot;").replacingOccurrences(of:"'",with:"&#39;")
    }
    static func csvCell(_ text:String)->String {
        // Quoting alone does not neutralize formulas when opening a CSV in a spreadsheet.
        let first=text.trimmingCharacters(in:.whitespacesAndNewlines).first
        let safe=(first.map{"=+-@".contains($0)} ?? false) ? "'"+text:text
        return "\""+safe.replacingOccurrences(of:"\"",with:"\"\"")+"\""
    }
    func data(_ format:ReportFormat)throws->Data {
        switch format {
        case .json:
            var object=try JSONSerialization.jsonObject(with:analysis.json(purpose:purpose,genre:genre,manualBounds:bounds)) as! [String:Any]
            object["source"]=name;object.removeValue(forKey:"originalSource");object.removeValue(forKey:"inputSnapshot");object.removeValue(forKey:"decodedAudio")
            object["reportCreatedAt"]=ISO8601DateFormatter().string(from:created)
            object["reportScope"]="Analyzed snapshot; whole analyzed interval. Source not revalidated at export. No audio embedded."
            object["analyzedSourceInterval"]=interval
            object["reportBuild"]=buildIdentity
            if let reference {object["comparisonReference"]=["name":URL(fileURLWithPath:reference.originalSource ?? reference.source).lastPathComponent,"sha256":reference.sha256]}
            return try JSONSerialization.data(withJSONObject:object,options:[.prettyPrinted,.sortedKeys])
        case .csv:
            let columns=["source_name","sha256","app_version","engine","tone_library","dynamics_library","genre","purpose","kind","start_seconds","end_seconds","channel_1_based","title","certainty","stored_marker_scope"]
            let rows=markers.map{m in [name,analysis.sha256,analysis.appVersion,analysis.engine,ToneLibrary.shared.version,DynamicsLibrary.shared.version,genre,purpose,m.kind,String(format:"%.9f",locale:Locale(identifier:"en_US_POSIX"),m.start),String(format:"%.9f",locale:Locale(identifier:"en_US_POSIX"),m.end),m.channel.map(String.init) ?? "",m.title,m.certainty,"Stored intervals only; cap 512 for click+silence combined, 512 overrange, 512 plateau; source timeline seconds; end exclusive except point markers"]}
            return Data(([columns]+rows).map{$0.map(Self.csvCell).joined(separator:",")}.joined(separator:"\r\n").appending("\r\n").utf8)
        case .html:return Data(html().utf8)
        }
    }
    func html()->String {
        let a=analysis, e=Self.htmlEscape
        func row(_ cells:[String])->String {let body=cells.map{"<td>\(e($0))</td>"}.joined();return "<tr>\(body)</tr>"}
        func table(_ headings:[String],_ rows:[[String]])->String {let head=headings.map{"<th>\(e($0))</th>"}.joined();let body=rows.map(row).joined();return "<table><thead><tr>\(head)</tr></thead><tbody>\(body)</tbody></table>"}
        func value(_ x:Double?,_ unit:String)->String {x.map{display($0,2)+" "+unit} ?? "Niet beschikbaar"}
        let tone=assessTone(a.toneSlices,genre:genre,hash:a.assessmentHash), dynamics=trackDynamics(a,genre:genre)
        let tips=advice.map{t -> String in
            let time=t.start.map{" · luister bij "+display($0+Double(a.windowStartFrame)/a.sampleRate,2)+" s"} ?? ""
            let context=(t.scope ?? "Luisteradvies")+time
            return "<article><h3>\(e(t.title))</h3><p>\(e(t.evidence))</p><p>\(e(t.action))</p><small>\(e(context))</small></article>"
        }.joined()
        let technical=a.secondOpinion(purpose:purpose).filter{$0.category != "Context, geen fout"}.map{item in
            "<article><h3>\(e(item.title))</h3><p>\(e(item.evidence))</p><p>\(e(item.action))</p></article>"
        }.joined()
        // At 192 kHz libebur128 performs no interpolation. Match the GUI's
        // sample-peak labeling instead of presenting that value as true peak.
        let peakRows = !a.peakIsInterpolated
            ? [["Samplepeak · geen true-peakinterpolatie",value(a.samplePeak,"dBFS")]]
            : [["True peak",value(a.reportedPeak,"dBTP")],["Samplepeak",value(a.samplePeak,"dBFS")]]
        let levels=table(["Meting","Waarde"],[["Integrated",value(a.integrated,"LUFS")],["Momentary max",value(a.momentaryMax,"LUFS")],["Short-term max",value(a.shortTermMax,"LUFS")],["Loudness range",value(a.lra,"LU")]]+peakRows+[[a.peakIsInterpolated ? "PLR":"Samplepiek − LUFS",value(a.reportedPeakGap,"dB")],["Correlatie",value(a.correlation,"")],["Mono-energie",a.completeMonoCancellation ? "Volledige uitdoving":value(a.monoLoss,"dB")],["Kanaalbalans L−R",value(a.channelBalanceDB,"dB")]])
        let toneTable=table(["Band","Verschil met mediaan","P10–P90 t.o.v. mediaan","Context"],tone.bands.map{b in
            let range:String
            if let low=b.lower,let high=b.upper,let median=b.median {range=display(low-median,2)+" tot "+display(high-median,2)+" dB"}else{range="Niet beschikbaar"}
            return [b.name,value(b.delta,"dB"),range,b.status]
        })
        let dynamicsTable=table(["Meting","Waarde","Context"],dynamics.metrics.map{[$0.name,value($0.value,"dB"),$0.label]})
        let markerTable=table(["Begin (s)","Einde (s)","Kanaal","Luisterpunt","Zekerheid"],markers.map{[display($0.start,3),display($0.end,3),$0.channel.map(String.init) ?? "—",$0.title,$0.certainty]})
        let ref=reference.map{"<p>Geladen referentie: "+e(URL(fileURLWithPath:$0.originalSource ?? $0.source).lastPathComponent)+" · SHA256 <code>"+e($0.sha256)+"</code>. Geen A/B-luisteroordeel in dit rapport.</p>"} ?? ""
        let boundaries=Array(Set(a.limitations+MeasurementClaims.standardLimitations)).sorted()
        let build="Broncode-SHA256: "+(buildIdentity["sourceSHA256"] as? String ?? "niet beschikbaar")
        return """
        <!doctype html><html lang="nl"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'"><title>YA-MixCheck · \(e(name))</title><style>
        :root{--paper:#f2f0e9;--ink:#171917;--muted:#60665c;--line:#c9c8bf;--soft:#e8e7df}
        *{box-sizing:border-box}body{font:15px Arial,Helvetica,sans-serif;line-height:1.55;background:var(--paper);color:var(--ink);max-width:960px;margin:40px auto;padding:0 28px;overflow-wrap:anywhere}
        .report-brand{border-bottom:1px solid var(--line);padding-bottom:22px;margin-bottom:24px}.brandline,footer{display:flex;justify-content:space-between;gap:20px;flex-wrap:wrap;font:11px ui-monospace,SFMono-Regular,Menlo,monospace;color:var(--muted)}
        .brandline a,footer a{color:inherit;text-underline-offset:3px}.brandline a{text-decoration:none}.brandline{margin-bottom:22px}.report-brand h1{font-family:Georgia,serif;font-weight:400;letter-spacing:-.045em;font-size:48px;line-height:1.12;margin:0 0 14px}.report-brand p{margin:0;color:#4c5049}
        h2{font-size:20px;font-weight:500;margin:32px 0 12px}h3{font-size:16px;line-height:1.4}p{max-width:78ch}small,.muted{color:var(--muted)}article{border-left:2px solid var(--line);padding:2px 16px;margin:18px 0}
        table{width:100%;border-collapse:collapse;font-size:13px;font-variant-numeric:tabular-nums}td,th{text-align:left;padding:9px 10px;border-bottom:1px solid var(--line);vertical-align:top}th{background:var(--soft);font-weight:500}li{margin:8px 0}code{overflow-wrap:anywhere;font-size:.85em}footer{border-top:1px solid var(--line);margin-top:36px;padding-top:16px}
        a:focus-visible{outline:2px solid var(--ink);outline-offset:4px}::selection{background:var(--ink);color:var(--paper)}
        @media(max-width:600px){body{margin:24px auto;padding:0 18px}.report-brand h1{font-size:36px}table{font-size:11px}td,th{padding:7px 4px}}
        @page{size:A4;margin:16mm}
        @media print{body{background:white;margin:0;padding:0;max-width:none;font-size:10pt}.report-brand{padding-bottom:14px;margin-bottom:18px}.report-brand h1{font-size:30pt}.brandline{margin-bottom:14px}table{font-size:9pt}thead{display:table-header-group}h1,h2,h3{break-after:avoid}tr,article,.report-brand,footer{break-inside:avoid}p,li{orphans:3;widows:3}th{-webkit-print-color-adjust:exact;print-color-adjust:exact}footer{font-size:8pt}}
        </style></head><body>
        <header class="report-brand"><div class="brandline"><span>YVES WORTEL</span><a href="https://yveswortel.com" rel="noreferrer">yveswortel.com</a></div><h1>YA / MixCheck</h1><p>\(e(name)) · \(e(genre)) · \(e(purpose))</p></header>
        <p class="muted">\(display(a.duration,2)) s · \(Int(a.sampleRate)) Hz · \(a.channels) kanalen · \(e(a.codec)). Broninterval \(display(interval["startSeconds"],2))–\(display(interval["endSeconds"],2)) s. Analyse-snapshot; bron niet opnieuw gecontroleerd bij export. Geen audio ingesloten.</p>
        <h2>Luisteradvies</h2>\(tips.isEmpty ? "<p>Geen onderbouwd prioriteitsadvies beschikbaar. Dit is geen kwaliteitsgoedkeuring; referenties of meetcontext kunnen ontbreken.</p>":tips)
        <h2>Metingen</h2>\(levels)
        <h2>Technische luisterpunten</h2>\(technical.isEmpty ? "<p>Geen prioritaire technische melding. Niet alle fouten zijn detecteerbaar.</p>":technical)
        <h2>Toonbalans</h2><p>\(e(tone.conclusion)) · \(tone.referenceCount) referenties. Actieve muziek, hele geanalyseerde interval. 0 dB = genre-mediaan, dezelfde schaal als de GUI; geen aanbevolen EQ-gain.</p>\(toneTable)<p class="muted">\(e(tone.limitation))</p>
        <h2>Dynamics</h2><p>Hele track · \(dynamics.referenceCount) referenties. Beschrijvende metingen; geen compressiediagnose of kwaliteitsscore.</p>\(dynamicsTable)\(ref)
        <h2>Markers</h2><p>Seconden vanaf het bronbegin; kanaalnummer vanaf 1. Overrange/plateau-eindes exclusief; adviespunten hebben geen duur. CSV is generiek: Logic-import nog niet gevalideerd. Alleen opgeslagen intervallen, maximaal 512 kliks/stiltes samen, 512 overrange-intervallen en 512 plateaus.</p>\(markerTable)
        <h2>Meetcontext en grenzen</h2><p>\(e(a.meterValidationNote))</p><p>Rapport \(e(ISO8601DateFormatter().string(from:created))) · JSON-schema \(a.schema) · app \(e(a.appVersion)) · engine \(e(a.engine))<br>Toonlibrary \(e(ToneLibrary.shared.version)) · dynamicslibrary \(e(DynamicsLibrary.shared.version))<br>Bestands-SHA256 <code>\(e(a.sha256))</code><br><code>\(e(build))</code></p><ul>\(boundaries.map{"<li>"+e($0)+"</li>"}.joined())</ul>
        <footer><span>YA / MixCheck · Yves Audio</span><span>Een tweede blik op je mix.</span></footer>
        </body></html>
        """
    }
}
func writeNewReport(_ data:Data,to destination:URL)throws {
    // Exclusive creation prevents a late overwrite, including symlinks to source audio.
    try data.write(to:destination,options:.withoutOverwriting)
}
