import Foundation
import Darwin

struct InputReceipt:Codable,Sendable {
    var bytes:Int64;var cloudStatus:String;var sourceModifiedAt:Date?
}
// Own a local snapshot for the entire analysis/playback lifetime. Never remove the source.
final class PreparedInput:Encodable,@unchecked Sendable {
    let snapshotModifiedAt:Date?
    let directory:URL,url:URL,original:URL,receipt:InputReceipt
    init(directory:URL,url:URL,original:URL,receipt:InputReceipt){self.directory=directory;self.url=url;self.original=original;self.receipt=receipt;self.snapshotModifiedAt=(try? FileManager.default.attributesOfItem(atPath:url.path))?[.modificationDate] as? Date}
    func remove(){SnapshotStorage.remove(directory)}
    deinit{remove()}
    // Provider metadata is read in a bounded child, never on the main thread.
    func originalIsUnchanged(timeout:Double=3)->Bool {
        let p=Process();p.executableURL=Bundle.main.executableURL
        p.arguments=["--check-input-worker",original.path,String(receipt.bytes),String(receipt.sourceModifiedAt?.timeIntervalSince1970 ?? -1)]
        p.standardOutput=FileHandle.nullDevice;p.standardError=FileHandle.nullDevice
        do{try p.run()}catch{return false}
        let deadline=ProcessInfo.processInfo.systemUptime+timeout
        while p.isRunning && ProcessInfo.processInfo.systemUptime<deadline{Thread.sleep(forTimeInterval:0.02)}
        if p.isRunning{kill(p.processIdentifier,SIGKILL);return false}
        return p.terminationStatus==0
    }
    func snapshotIsIntact()->Bool {
        guard let a=try? FileManager.default.attributesOfItem(atPath:url.path) else{return false}
        return (a[.size] as? NSNumber)?.int64Value==receipt.bytes && (a[.modificationDate] as? Date)==snapshotModifiedAt
    }
    func encode(to encoder:Encoder)throws{try receipt.encode(to:encoder)}
    static func prepare(_ source:URL,cancellation:Cancellation,timeout:Double=180,status:(String)->Void={_ in},workerArguments:[String]?=nil)throws->PreparedInput {
        try cancellation.check()
        let fm=FileManager.default
        let directory=SnapshotStorage.temporaryDirectory.appendingPathComponent("ya-mixcheck-input-"+UUID().uuidString,isDirectory:true)
        try fm.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        do {try SnapshotStorage.register(directory)} catch {try? fm.removeItem(at:directory);throw error}
        var keep=false;defer{if !keep{SnapshotStorage.remove(directory)}}
        // All provider-dependent metadata, coordination and reads occur in a killable process.
        let destination=directory.appendingPathComponent(source.lastPathComponent)
        let process=Process();process.executableURL=Bundle.main.executableURL
        process.arguments=workerArguments ?? ["--prepare-input-worker",source.path,destination.path]
        let logURL=directory.appendingPathComponent("worker.log")
        fm.createFile(atPath:logURL.path,contents:nil)
        let log=try FileHandle(forWritingTo:logURL);defer{try? log.close()}
        process.standardOutput=log;process.standardError=log;process.standardInput=FileHandle.nullDevice
        status("Bestand beschikbaar maken…")
        try process.run()
        func stop(){
            guard process.isRunning else{return}
            process.terminate()
            let until=ProcessInfo.processInfo.systemUptime+0.3
            while process.isRunning && ProcessInfo.processInfo.systemUptime<until {Thread.sleep(forTimeInterval:0.02)}
            if process.isRunning{kill(process.processIdentifier,SIGKILL)}
            // No unbounded waitUntilExit: cleanup stays bounded even if the OS cannot reap promptly.
            let end=ProcessInfo.processInfo.systemUptime+1
            while process.isRunning && ProcessInfo.processInfo.systemUptime<end{Thread.sleep(forTimeInterval:0.02)}
        }
        let deadline=ProcessInfo.processInfo.systemUptime+timeout
        var previous=""
        do {
            while process.isRunning {
                try cancellation.check()
                guard ProcessInfo.processInfo.systemUptime<deadline else{throw QCFailure(message:"Bestand niet op tijd beschikbaar. Download het eerst in Finder en probeer opnieuw; de bron is niet gewijzigd.")}
                if let text=try? String(contentsOf:directory.appendingPathComponent("status.txt"),encoding:.utf8),text != previous {previous=text;status(text)}
                Thread.sleep(forTimeInterval:0.05)
            }
            try cancellation.check()
        }catch{stop();throw error}
        guard process.terminationStatus==0 else {
            let text=(try? String(contentsOf:logURL,encoding:.utf8)) ?? ""
            throw QCFailure(message:text.isEmpty ? "Bestand kon niet lokaal worden voorbereid. Download het in Finder en probeer opnieuw.":String(text.suffix(1500)).trimmingCharacters(in:.whitespacesAndNewlines))
        }
        let receipt=try JSONDecoder().decode(InputReceipt.self,from:Data(contentsOf:directory.appendingPathComponent("receipt.json")))
        let bytes=(try fm.attributesOfItem(atPath:destination.path)[.size] as? NSNumber)?.int64Value
        guard bytes==receipt.bytes,receipt.bytes>0 else{throw QCFailure(message:"De lokale kopie is onvolledig; analyse afgebroken.")}
        keep=true;status("Bestand analyseren…")
        return PreparedInput(directory:directory,url:destination,original:source,receipt:receipt)
    }
}

func prepareInputWorker(source:URL,destination:URL)throws {
    let fm=FileManager.default,directory=destination.deletingLastPathComponent()
    let parent=getppid(),deadline=ProcessInfo.processInfo.systemUptime+190
    DispatchQueue.global(qos:.utility).async {
        while getppid()==parent && ProcessInfo.processInfo.systemUptime<deadline {Thread.sleep(forTimeInterval:0.5)}
        // A parent crash/quit must not leave an indefinitely blocked provider worker.
        _exit(124)
    }
    func status(_ s:String){try? s.write(to:directory.appendingPathComponent("status.txt"),atomically:true,encoding:.utf8)}
    let scoped=source.startAccessingSecurityScopedResource();defer{if scoped{source.stopAccessingSecurityScopedResource()}}
    var url=source
    let keys:Set<URLResourceKey>=[.isUbiquitousItemKey,.ubiquitousItemDownloadingStatusKey,.ubiquitousItemDownloadingErrorKey]
    var values=try url.resourceValues(forKeys:keys)
    var cloudStatus="local"
    if values.isUbiquitousItem==true {
        if values.ubiquitousItemDownloadingStatus == .notDownloaded {
            status("Wachten op iCloud-download…")
            try fm.startDownloadingUbiquitousItem(at:source)
            repeat {
                Thread.sleep(forTimeInterval:0.2)
                url.removeAllCachedResourceValues();values=try url.resourceValues(forKeys:keys)
                if let error=values.ubiquitousItemDownloadingError{throw error}
            }while values.ubiquitousItemDownloadingStatus == .notDownloaded
        }
        // 'downloaded' is readable; it need not equal 'current'. Record which version we used.
        cloudStatus=values.ubiquitousItemDownloadingStatus == .current ? "current":"downloaded-or-unknown"
    }
    status("Lokale analysekopie maken…")
    let coordinator=NSFileCoordinator(filePresenter:nil)
    var coordinationError:NSError?,copyError:Error?,receipt:InputReceipt?
    coordinator.coordinate(readingItemAt:source,options:[],error:&coordinationError){readURL in
        do {
            let before=try fm.attributesOfItem(atPath:readURL.path)
            guard before[.type] as? FileAttributeType == .typeRegular else{throw QCFailure(message:"Selecteer een regulier audiobestand.")}
            let input=try FileHandle(forReadingFrom:readURL);defer{try? input.close()}
            guard fm.createFile(atPath:destination.path,contents:nil,attributes:[.posixPermissions:0o600]) else{throw QCFailure(message:"Geen ruimte of rechten voor een lokale analysekopie.")}
            let output=try FileHandle(forWritingTo:destination);defer{try? output.close()}
            var bytes:Int64=0
            while try autoreleasepool(invoking: { () throws -> Bool in
                let data=try input.read(upToCount:1<<20) ?? Data()
                guard !data.isEmpty else{return false}
                try output.write(contentsOf:data);bytes+=Int64(data.count)
                return true
            }) {}
            try output.synchronize()
            let after=try fm.attributesOfItem(atPath:readURL.path)
            guard bytes>0,bytes==(before[.size] as? NSNumber)?.int64Value,
                  before[.size] as? NSNumber == after[.size] as? NSNumber,
                  before[.modificationDate] as? Date == after[.modificationDate] as? Date else{throw QCFailure(message:"Bron gewijzigd of onvolledig gelezen; probeer de export opnieuw.")}
            receipt=InputReceipt(bytes:bytes,cloudStatus:cloudStatus,sourceModifiedAt:before[.modificationDate] as? Date)
        }catch{copyError=error}
    }
    if let error=coordinationError{throw error};if let error=copyError{throw error}
    guard let receipt else{throw QCFailure(message:"Bestandscoördinatie leverde geen lokale kopie op.")}
    try JSONEncoder().encode(receipt).write(to:directory.appendingPathComponent("receipt.json"),options:.atomic)
}

// Unified registry for input snapshots, decoded PCM and EQ previews.
// Only directories registered by this process are removed on normal shutdown.
// A flock lease keeps another running app's snapshots safe during crash recovery.
enum SnapshotStorage {
    // Only the explicit process-isolated stability probe sets this before work.
    // Normal GUI/CLI operation keeps the native macOS temporary directory.
    static var validationRoot:URL?
    static var temporaryDirectory:URL {validationRoot ?? FileManager.default.temporaryDirectory}
    static let lock=NSLock()
    static var leases=[URL:Int32]()
    static func register(_ directory:URL)throws{
        let fd=open(directory.appendingPathComponent("owner.lock").path,O_CREAT|O_RDWR|O_CLOEXEC,0o600)
        guard fd>=0,flock(fd,LOCK_EX|LOCK_NB)==0 else{if fd>=0{close(fd)};throw QCFailure(message:"Tijdelijke audio-opslag kon niet veilig worden gereserveerd.")}
        lock.lock();leases[directory]=fd;lock.unlock()
    }
    static func remove(_ directory:URL){
        lock.lock();defer{lock.unlock()}
        guard let fd=leases[directory] else{return}
        do {try FileManager.default.removeItem(at:directory)} catch {
            if (error as NSError).code != NSFileNoSuchFileError {
                // Keep the lease for a shutdown retry; report instead of silently forgetting it.
                NSLog("YA-MixCheck tijdelijke audio opruimen mislukt: %@",error.localizedDescription)
                return
            }
        }
        leases.removeValue(forKey:directory);close(fd)
    }
    static func cleanup(){lock.lock();let paths=Array(leases.keys);lock.unlock();for p in paths{remove(p)}}
    static func recover(in root:URL=FileManager.default.temporaryDirectory){
        let fm=FileManager.default
        guard let entries=try? fm.contentsOfDirectory(at:root,includingPropertiesForKeys:nil) else{return}
        for p in entries where ["ya-mixcheck-input-","ya-mixcheck-decode-","YA-MixCheck-EQ-"].contains(where:{p.lastPathComponent.hasPrefix($0)}) {
            guard let a=try? fm.attributesOfItem(atPath:p.path),a[.type] as? FileAttributeType == .typeDirectory,
                  let modified=a[.modificationDate] as? Date,Date().timeIntervalSince(modified)>300 else{continue}
            // Recent directories may still be acquiring their lease in another process.
            let fd=open(p.appendingPathComponent("owner.lock").path,O_RDWR|O_NOFOLLOW|O_CLOEXEC)
            guard fd>=0 else{continue};defer{close(fd)}
            if flock(fd,LOCK_EX|LOCK_NB)==0{do{try fm.removeItem(at:p)}catch{NSLog("YA-MixCheck cacheherstel mislukt: %@",error.localizedDescription)}}
        }
    }
}
