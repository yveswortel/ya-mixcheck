import Foundation

// A deliberately sparse level suggestion, not a loudness standard or quality grade.
// Never red/green. Absolute guards only prevent nuisance hints on normal exports;
// they are not recommended targets. Genre context is dynamic, not a LUFS target.
struct LoudnessReview:Codable {
    enum State:String,Codable {case neutral,orange}
    var policy="cautious-level-context-20261026"
    var state:State = .neutral
    var reason:String
    var advice:MixRecommendation? = nil
}
func assessLoudness(integrated:Double?,shortTermMax:Double?,peak:Double?,lra:Double?,duration:Double,
                    dynamics:TrackDynamics?,purpose:String)->LoudnessReview {
    func neutral(_ reason:String)->LoudnessReview{LoudnessReview(reason:reason)}
    guard purpose=="Release/master" else{return neutral("mastering_headroom_allowed")}
    guard duration.isFinite,duration>=60,let integrated,let shortTermMax,let peak,let lra,
          [integrated,shortTermMax,peak,lra].allSatisfy({$0.isFinite}),lra>=0 else{return neutral("insufficient_measurement")}
    // A modestly quieter master is normal. A loud chorus also protects a track
    // whose integrated number is reduced by its intro or arrangement.
    guard integrated < -20,shortTermMax < -17 else{return neutral("no_strong_low_level_pattern")}
    guard let dynamics,dynamics.referenceCount>=5,dynamics.summary.seconds.isFinite,dynamics.summary.seconds>=30,
          let density=dynamics.metrics.first(where:{$0.id=="density"}),let dv=density.value,let dl=density.lower,
          let punch=dynamics.metrics.first(where:{$0.id=="punch"}),let pv=punch.value,let ph=punch.upper,
          let movement=dynamics.metrics.first(where:{$0.id=="movement"}),let mv=movement.value,let mh=movement.upper,
          [dv,dl,pv,ph,mv,mh].allSatisfy({$0.isFinite}) else{return neutral("insufficient_genre_context")}
    guard lra<=10,shortTermMax-integrated<=6,mv<=max(8,mh+2) else{return neutral("arrangement_contrast_allowed")}

    if peak <= -8,dv>=dl-1,pv<=ph+2.5,integrated-peak-1 >= -18 {
        let tip=MixRecommendation(id:"level-export",title:"Controleer het exportniveau",
            evidence:"\(display(integrated)) LUFS-I en ook de luidste 3 seconden blijven zacht (\(display(shortTermMax)) LUFS). Er is circa \(display(-peak)) dB piekruimte; de dichtheid is niet duidelijk lager dan bij de genrevoorbeelden.",
            action:"Dit kan vooral een laag uitgangsniveau zijn. Controleer de masterfader en exportgain als dit de definitieve release is. Een beetje extra gain kan voldoende zijn; geen reden om alleen hiervoor extra compressie toe te voegen. Bewust zacht geëxporteerd? Dan kun je dit laten staan.",scope:"Trackcontext")
        return LoudnessReview(state:.orange,reason:"low_export_with_headroom",advice:tip)
    }
    if peak >= -2,peak <= 1,peak-integrated>18,dv<dl-3,pv>ph+3 {
        let tip=MixRecommendation(id:"level-peaks",title:"Controleer uitspringende aanzetten",
            evidence:"\(display(integrated)) LUFS-I, maar weinig piekruimte. Ook de luidste 3 seconden blijven zacht (\(display(shortTermMax)) LUFS). Minder dichtheid én meer aanzetcontrast dan de genrevoorbeelden ondersteunen deze luistercontrole.",
            action:"Luister of enkele slagen de pieken bepalen terwijl de rest ver terugligt. Alleen als dat onbedoeld voelt: vergelijk hun niveau of envelope voordat je de hele mix harder limiteert. Een open, dynamische klank mag zo blijven.",scope:"Trackcontext")
        return LoudnessReview(state:.orange,reason:"low_level_with_prominent_attacks",advice:tip)
    }
    return neutral("low_level_without_combined_evidence")
}
extension Analysis {
    func loudnessReview(purpose:String,dynamics:TrackDynamics?)->LoudnessReview {
        assessLoudness(integrated:integrated,shortTermMax:shortTermMax,
                      peak:sampleRate>=192000 ? samplePeak:truePeakEstimate,lra:lra,duration:duration,
                      dynamics:dynamics,purpose:purpose)
    }
}
