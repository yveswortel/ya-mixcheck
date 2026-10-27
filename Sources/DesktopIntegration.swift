import AppKit

func audioOpenIssue(_ urls:[URL])->String? {
    guard urls.count==1 else{return "Open één audiobestand tegelijk."}
    guard let url=urls.first,url.isFileURL,["wav","wave","aif","aiff","mp3","flac"].contains(url.pathExtension.lowercased()) else{return "Kies een WAV-, AIFF-, FLAC- of MP3-bestand."}
    return nil
}

func validateDesktopFileSelection()->[TestOutcome] {
    let cases:[(String,[URL],Bool)]=[
        ("Single WAV",[URL(fileURLWithPath:"/tmp/mix.WAV")],true),
        ("AIFF",[URL(fileURLWithPath:"/tmp/mix.aif")],true),
        ("FLAC",[URL(fileURLWithPath:"/tmp/mix.flac")],true),
        ("MP3",[URL(fileURLWithPath:"/tmp/mix.mp3")],true),
        ("No files",[],false),
        ("Multiple files",[URL(fileURLWithPath:"/tmp/a.wav"),URL(fileURLWithPath:"/tmp/b.wav")],false),
        ("Unsupported format",[URL(fileURLWithPath:"/tmp/mix.m4a")],false),
        ("Remote URL",[URL(string:"https://example.invalid/mix.wav")!],false)
    ]
    return cases.map{name,urls,valid in TestOutcome(name:"Desktop selection: "+name,passed:(audioOpenIssue(urls)==nil)==valid,detail:"")}
}

// Keep the exclusive-write guarantee visible in the native save panel as well.
final class NewReportDestinationDelegate:NSObject,NSOpenSavePanelDelegate {
    func panel(_ sender:Any,validate url:URL)throws {
        if FileManager.default.fileExists(atPath:url.path) || (try? FileManager.default.destinationOfSymbolicLink(atPath:url.path)) != nil {
            throw NSError(domain:"audio.yves.mixcheck.report",code:1,userInfo:[NSLocalizedDescriptionKey:"Dit bestand bestaat al. Kies een andere naam; bestaande bestanden blijven ongewijzigd."])
        }
    }
}

@MainActor extension AppDelegate {
    func installMenus(){
        let bar=NSMenu()
        func menu(_ title:String)->NSMenu {let item=NSMenuItem(title:title,action:nil,keyEquivalent:"");let child=NSMenu(title:title);item.submenu=child;bar.addItem(item);return child}
        func command(_ menu:NSMenu,_ title:String,_ action:Selector,_ key:String="",target:AnyObject?=nil,modifiers:NSEvent.ModifierFlags=[.command]){
            let item=NSMenuItem(title:title,action:action,keyEquivalent:key);item.target=target;item.keyEquivalentModifierMask=modifiers;menu.addItem(item)
        }
        let app=menu("YA-MixCheck")
        command(app,"Over YA-MixCheck",#selector(NSApplication.orderFrontStandardAboutPanel(_:)),target:NSApp)
        app.addItem(.separator());command(app,"Verberg YA-MixCheck",#selector(NSApplication.hide(_:)),"h",target:NSApp)
        app.addItem(.separator());command(app,"Stop YA-MixCheck",#selector(NSApplication.terminate(_:)),"q",target:NSApp)
        let file=menu("Bestand")
        command(file,"Open audio…",#selector(openAudio(_:)),"o",target:self)
        command(file,"Referentie toevoegen…",#selector(openReference(_:)),"o",target:self,modifiers:[.command,.shift])
        file.addItem(.separator());command(file,"Bewaar rapport (HTML)…",#selector(exportHTML(_:)),"s",target:self,modifiers:[.command,.shift])
        command(file,"Bewaar luistermarkers (CSV)…",#selector(exportCSV(_:)),target:self)
        command(file,"Bewaar metingen (JSON)…",#selector(exportJSON(_:)),target:self)
        file.addItem(.separator());command(file,"Sluit venster",#selector(NSWindow.performClose(_:)),"w")
        let edit=menu("Wijzig")
        command(edit,"Herstel",Selector(("undo:")),"z");command(edit,"Opnieuw",Selector(("redo:")),"z",modifiers:[.command,.shift])
        edit.addItem(.separator());command(edit,"Knip",#selector(NSText.cut(_:)),"x");command(edit,"Kopieer",#selector(NSText.copy(_:)),"c");command(edit,"Plak",#selector(NSText.paste(_:)),"v");command(edit,"Selecteer alles",#selector(NSText.selectAll(_:)),"a")
        let window=menu("Venster")
        command(window,"Minimaliseer",#selector(NSWindow.performMiniaturize(_:)),"m");command(window,"Zoom",#selector(NSWindow.performZoom(_:)))
        NSApp.mainMenu=bar;NSApp.windowsMenu=window
    }
}
