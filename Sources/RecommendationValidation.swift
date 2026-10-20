import Foundation
func validateRecommendations()->[TestOutcome]{
    var out=[TestOutcome]()
    func check(_ name:String,_ pass:Bool){out.append(TestOutcome(name:"Advice: "+name,passed:pass,detail:"Controlled verdict fixture; not perceptual validation"))}
    var tone=ToneAssessment(genre:"test",mode:"active",referenceCount:9,referenceTitles:[],summary:ToneSummary(bands:[],lowRatio:nil,lowContrast:nil,lowMono:nil,seconds:20,rms:-20),bands:[],advice:[],conclusion:"",limitation:"")
    for b in 0..<7 {
        for direction in [-1.0,1.0] {
            tone.bands=[ToneBandVerdict(id:b,name:toneNames[b],range:toneRanges[b],value:direction*10,median:0,lower:-2,upper:2,delta:direction*10,status:direction>0 ? "Duidelijk meer":"Duidelijk minder",attention:true)]
            let a=tonalRecommendations(tone)
            check("band \(b), direction \(direction)",b==6 ? a.isEmpty:a.count==1 && a[0].action==(direction>0 ? toneSuggestions[b].high:toneSuggestions[b].low))
        }
    }
    tone.referenceCount=4;check("too few references",tonalRecommendations(tone).isEmpty)
    tone.referenceCount=9;tone.summary.seconds=4;check("too little audio",tonalRecommendations(tone).isEmpty)
    for id in ["density","punch","movement"] {
        for value in [-10.0,0,10] {
            let d=TrackDynamics(referenceCount:9,summary:DynamicsSummary(density:0,punch:0,movement:0,seconds:20),metrics:[DynamicsMetric(id:id,name:id,value:value,lower:-2,median:0,upper:2,label:"test")])
            check("\(id) \(value)",dynamicsRecommendations(d).count==(value==0 ? 0:1))
        }
        let missing=TrackDynamics(referenceCount:0,summary:DynamicsSummary(density:nil,punch:nil,movement:nil,seconds:0),metrics:[DynamicsMetric(id:id,name:id,value:nil,lower:nil,median:nil,upper:nil,label:"test")])
        check("\(id) missing",dynamicsRecommendations(missing).isEmpty)
    }
    tone.referenceCount=9;tone.summary.seconds=40
    tone.bands=[0,4].map{b in ToneBandVerdict(id:b,name:toneNames[b],range:toneRanges[b],value:b==0 ? 5:-5,median:0,lower:-2,upper:2,delta:b==0 ? 5:-5,status:"Duidelijk",attention:true)}
    var d=TrackDynamics(referenceCount:9,summary:DynamicsSummary(density:-15,punch:7,movement:10,seconds:40),metrics:[DynamicsMetric(id:"density",name:"Dichtheid",value:-15,lower:-12,median:-10,upper:-8,label:"Luchtiger"),DynamicsMetric(id:"punch",name:"Punch",value:7,lower:4,median:6,upper:9,label:"Binnen spreiding"),DynamicsMetric(id:"movement",name:"Beweging",value:10,lower:2,median:4,upper:6,label:"Meer beweging")])
    let passages=(0..<2).map{i in PassageDynamics(id:i,start:Double(i*20),end:Double(i*20+20),mode:"test",referenceCount:9,summary:DynamicsSummary(density:-15,punch:7,movement:3,seconds:20),metrics:[])}
    let joint=contextualRecommendations(tone:tone,d:d,passages:passages,purpose:"Mix voor mastering")
    check("coupled bass/presence replaces two tips",joint.contains{$0.id=="balance-weight-presence"} && !joint.contains{$0.id=="tone-0" || $0.id=="tone-4"})
    check("open premaster protects attacks",joint.contains{$0.id=="open-with-attacks"} && !joint.contains{$0.id=="dynamics-density"})
    check("section contrast replaces movement tip",joint.contains{$0.id=="arrangement-contrast"} && !joint.contains{$0.id=="dynamics-movement"})
    let noSections=contextualRecommendations(tone:tone,d:d,passages:[],purpose:"Release/master")
    check("no section evidence no contrast claim",!noSections.contains{$0.id=="arrangement-contrast"})
    d.metrics[0].value = -5;d.metrics[1].value=1
    let dense=contextualRecommendations(tone:tone,d:d,passages:[],purpose:"Release/master")
    check("density with reduced onset grouped",dense.contains{$0.id=="dense-soft-attacks"} && !dense.contains{$0.id=="dynamics-density" || $0.id=="dynamics-punch"})
    tone.bands=[3,4,6].map{b in ToneBandVerdict(id:b,name:toneNames[b],range:toneRanges[b],value:b==6 ? 12:-10,median:0,lower:-2,upper:2,delta:b==6 ? 12:-10,status:"test",attention:b != 6)}
    let air=contextualRecommendations(tone:tone,d:d,passages:[],purpose:"Release/master")
    check("air/body/mids grouped",air.contains{$0.id=="air-body-mids"} && !air.contains{$0.id=="tone-3" || $0.id=="tone-4"})
    tone.bands[0].attention=false
    check("air alone insufficient",!contextualRecommendations(tone:tone,d:d,passages:[],purpose:"Release/master").contains{$0.id=="air-body-mids"})
    return out
}
