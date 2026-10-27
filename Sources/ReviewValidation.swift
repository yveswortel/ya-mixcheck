import Foundation
func validateEQPreviewPolicy() throws->[TestOutcome] {
    var out=[TestOutcome]()
    func check(_ name:String,_ pass:Bool,_ detail:String=""){out.append(TestOutcome(name:"EQ preview policy: "+name,passed:pass,detail:detail))}
    var tone=ToneAssessment(genre:"test",mode:"active",referenceCount:9,referenceTitles:[],summary:ToneSummary(bands:[],lowRatio:nil,lowContrast:nil,lowMono:nil,seconds:20,rms:-20),bands:[],advice:[],conclusion:"",limitation:"")
    func band(_ id:Int,_ value:Double,_ attention:Bool)->ToneBandVerdict{ToneBandVerdict(id:id,name:toneNames[id],range:toneRanges[id],value:value,median:0,lower:-2,upper:2,delta:value,status:"test",attention:attention)}
    tone.bands=[band(0,9,true),band(2,-9,true),band(3,-6,false),band(4,-8,true),band(5,7,false)]
    let preview=previewBands(tone)
    check("dominant bass preview does not boost relative deficits",preview.count==1 && preview[0].hz==35 && preview[0].gain<0)
    tone.bands=[band(3,-9,true),band(4,-9,true),band(6,12,false)]
    check("air-body contrast does not blindly boost body/mids",previewBands(tone).isEmpty)
    tone.bands=[band(5,2.8,false)]
    check("unflagged pilot-range excursion gets no EQ",previewBands(tone).isEmpty)
    tone.bands=[band(4,-9,true)]
    check("independent flagged deficit can be auditioned",previewBands(tone).first?.gain==3)
    let active=tone
    var louder=tone;louder.bands=[band(5,8,true)]
    let activePlan=eqPreviewPlan(active:active,louder:louder)
    check("whole-track active evidence takes precedence",activePlan.bands.count==1 && activePlan.bands.first?.hz==1000 && activePlan.context=="Actieve muziek · hele track" && activePlan.unavailableReason==nil)
    var neutral=active;neutral.bands=[band(5,2.8,false)]
    let louderPlan=eqPreviewPlan(active:neutral,louder:louder)
    check("supported louder fallback is explicit",louderPlan.bands.count==1 && louderPlan.bands.first?.hz==5000 && louderPlan.context=="Luidere passages · hele track" && louderPlan.unavailableReason==nil)
    let neutralPlan=eqPreviewPlan(active:neutral,louder:neutral)
    check("no evidence stays disabled with explanation",neutralPlan.bands.isEmpty && neutralPlan.unavailableReason?.contains("Geen onderbouwde")==true)
    var sparse=active;sparse.referenceCount=4
    check("preview plan retains independent-reference minimum",eqPreviewPlan(active:sparse,louder:sparse).bands.isEmpty && eqPreviewPlan(active:sparse,louder:sparse).unavailableReason?.contains("genrevoorbeelden")==true)
    var brief=active;brief.summary.seconds=7.9
    check("preview plan retains active-duration minimum",eqPreviewPlan(active:brief,louder:brief).bands.isEmpty && eqPreviewPlan(active:brief,louder:brief).unavailableReason?.contains("8 s")==true)
    return out
}
