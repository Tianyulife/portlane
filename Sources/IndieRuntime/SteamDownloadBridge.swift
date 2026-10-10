import Foundation
import IndieCore
import CoreGraphics

public struct SteamBridgeDownload: Codable, Equatable, Sendable {
    public let appID: UInt64
    public let completed: Bool
    public let paused: Bool
    public let errorCode: Int
    public let progress: Double?
    public var downloadedBytes: Double? = nil
    public var totalBytes: Double? = nil
    public var bytesPerSecond: Double? = nil
}

public enum SteamBridgeInstallResult: Sendable, Equatable {
    case submitted
    case needsInteraction
    case failed(code: Int)
    case loginRequired
}

public struct SteamBridgeLibrary: Codable, Sendable, Equatable {
    public let index: Int
    public let path: String
    public let mounted: Bool
    public let isDefault: Bool
    public let freeBytes: Double?
}

/// Typed native-client operations. CDP is carried over inherited CEF pipes, never TCP.
/// Mailboxes are private to the macOS user. Do not expose `command`/`evaluate` to UI or URLs.
public actor SteamDownloadBridge {
    public static func permitsPlay(manifestReady: Bool, download: SteamBridgeDownload?) -> Bool {
        manifestReady && download?.completed != false && (download?.errorCode ?? 0) <= 1
    }
    private let root: URL
    private let steamDirectory: URL
    private var context: (directory: URL, session: String)?
    private var installing = false
    private var launchContexts: [String: String] = [:]
    private var launchDirectory: URL?
    public init(steamDirectory: URL) {
        self.steamDirectory = steamDirectory
        root = Self.mailboxRoot(steamDirectory: steamDirectory)
    }

    public static func mailboxRoot(steamDirectory: URL) -> URL {
        steamDirectory.appendingPathComponent("bin/cef/cef.win64/mgu-bridge", isDirectory: true)
    }

    /// Called before starting the wrapped helper. Never enable a world-readable mailbox.
    public static func prepare(steamDirectory: URL) throws {
        let root = mailboxRoot(steamDirectory: steamDirectory)
        let fm = FileManager.default
        if !fm.fileExists(atPath: root.path) {
            try fm.createDirectory(at: root, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }
        let attrs = try fm.attributesOfItem(atPath: root.path)
        guard attrs[.type] as? FileAttributeType == .typeDirectory,
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
            throw IndieError.invalidArgument("Unsafe Steam bridge directory")
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let display = CGDisplayBounds(CGMainDisplayID())
        if display.width >= 640, display.height >= 480 {
            try "\(Int(display.width)) \(Int(display.height))".write(
                to: root.appendingPathComponent("display.txt"), atomically: true, encoding: .utf8)
        }
    }

    public func downloads() async throws -> [SteamBridgeDownload] {
        let value = try await evaluate("window.__mguDownloads.lease=Date.now();window.__mguDownloads.items")
        let data = try JSONSerialization.data(withJSONObject: value)
        return try JSONDecoder().decode([SteamBridgeDownload].self, from: data)
    }

    /// Lease the hook in each official desktop UI context, including the shared
    /// library context. Reading a process log after launch would be too late.
    public func takeGameLaunchRequests(appIDs: [UInt64]) async throws -> (active: Bool, appIDs: [UInt64]) {
        let directory = try activeDirectory()
        if launchDirectory != directory { launchContexts = [:]; launchDirectory = directory }
        let targets = try await command("Target.getTargets", directory: directory)
        let infos = (targets["targetInfos"] as? [[String: Any]] ?? []).filter {
            let title = $0["title"] as? String ?? ""
            let url = URL(string: $0["url"] as? String ?? "")
            return title == "SharedJSContext" || title == "Steam" || url?.host == "steamloopback.host"
        }
        let live = Set(infos.compactMap { $0["targetId"] as? String })
        launchContexts = launchContexts.filter { live.contains($0.key) }
        var active = false
        var requests = Set<UInt64>()
        var failures: [String] = []
        for info in infos {
            guard let id = info["targetId"] as? String else { continue }
            do {
                if launchContexts[id] == nil {
                    let attached = try await command("Target.attachToTarget", params: ["targetId": id, "flatten": true], directory: directory)
                    launchContexts[id] = attached["sessionId"] as? String
                }
                guard let session = launchContexts[id] else { continue }
                let result = try await command("Runtime.evaluate", params: [
                    "expression": SteamLaunchRelay.script(appIDs: appIDs), "returnByValue": true
                ], directory: directory, session: session)
                if let exception = result["exceptionDetails"] as? [String: Any] {
                    let description = (exception["exception"] as? [String: Any])?["description"] as? String
                    failures.append(String((description ?? "Steam interface unavailable").prefix(240)))
                    continue
                }
                guard let value = (result["result"] as? [String: Any])?["value"] as? [String: Any] else { continue }
                active = active || value["active"] as? Bool == true
                for number in value["appIDs"] as? [NSNumber] ?? [] {
                    let appID = number.uint64Value
                    if appIDs.contains(appID) { requests.insert(appID) }
                }
            } catch { launchContexts[id] = nil; failures.append(error.localizedDescription) }
        }
        if !active && !failures.isEmpty { throw IndieError.notFound(failures.joined(separator: "\n")) }
        return (active, requests.sorted())
    }

    public func completeGameLaunchRequest(appID: UInt64) async {
        guard let directory = launchDirectory else { return }
        for session in launchContexts.values {
            _ = try? await command("Runtime.evaluate", params: [
                "expression": "window.__mguLaunchRelay?.complete(\(appID));true", "returnByValue": true
            ], directory: directory, session: session)
        }
    }

    /// The same official Play entry point used by Steam's desktop library.
    /// Requires the native manager's live lease; never bypasses configuration.
    public func requestConfiguredPlay(appID: UInt64) async throws {
        guard appID > 0, appID <= UInt32.max else { throw IndieError.invalidArgument("Invalid Steam AppID") }
        let accepted = try await evaluate("""
        (()=>{const s=window.__mguLaunchRelay;
        if(!s||Date.now()-s.lease>15000||!s.ids.has(\(appID))||SteamClient.Apps.RunGame!==s.wrapped)return false;
        SteamClient.Apps.RunGame('\(appID)','',-1,0);return true;})()
        """) as? Bool
        guard accepted == true else { throw IndieError.notFound(L("Steam 启动衔接尚未连接")) }
    }

    /// The app must obtain explicit user confirmation before calling this operation.
    public func uninstall(appID: UInt64) async throws {
        guard appID > 0, appID <= UInt32.max, !installing else {
            throw IndieError.invalidArgument("Invalid or concurrent Steam operation")
        }
        installing = true
        defer { installing = false }
        _ = try await evaluate("SteamClient.Installs.OpenUninstallWizard([\(appID)],true);true")
    }

    public func libraries() async throws -> [SteamBridgeLibrary] {
        let value = try await evaluate("""
        (async()=>{const folders=await SteamClient.InstallFolder.GetInstallFolders();
        return folders.map(f=>({index:f.nFolderIndex,path:f.strFolderPath,
          mounted:f.bIsMounted===true,isDefault:f.bIsDefaultFolder===true,
          freeBytes:Number.isFinite(Number(f.nFreeSpace))?Number(f.nFreeSpace):null}));})()
        """)
        return try JSONDecoder().decode([SteamBridgeLibrary].self, from: JSONSerialization.data(withJSONObject:value))
    }

    public func addLibrary(windowsPath: String) async throws {
        guard windowsPath.count >= 3, windowsPath.count < 1024,
              windowsPath.range(of: #"^[a-zA-Z]:\\"#, options: .regularExpression) != nil,
              !windowsPath.contains("\0"), !windowsPath.contains("\n") else {
            throw IndieError.invalidArgument(L("游戏库路径无效"))
        }
        let encoded = String(decoding:try JSONEncoder().encode(windowsPath),as:UTF8.self)
        let existing = try await libraries().first { Self.sameLibraryPath($0.path,windowsPath) }
        if existing?.mounted == true { return }
        if existing == nil {
            _ = try await evaluate("""
            (async()=>{await SteamClient.InstallFolder.AddInstallFolder(\(encoded));
            SteamClient.InstallFolder.RefreshFolders();return true;})()
            """)
        } else {
            _ = try await evaluate("SteamClient.InstallFolder.RefreshFolders();true")
        }
        for _ in 0..<20 {
            if try await libraries().contains(where: { Self.sameLibraryPath($0.path,windowsPath) && $0.mounted }) { return }
            try await Task.sleep(for:.milliseconds(250))
        }
        throw IndieError.notFound(L("Steam 尚未确认游戏库挂载成功，请刷新后重试"))
    }

    private static func sameLibraryPath(_ a: String, _ b: String) -> Bool {
        func normalized(_ s:String)->String { s.replacingOccurrences(of:"/",with:"\\").trimmingCharacters(in:CharacterSet(charactersIn:"\\")).lowercased() }
        return normalized(a)==normalized(b)
    }

    public func isAuthenticated() async throws -> Bool {
        let ready = try await evaluate("""
        new Promise(resolve=>{
          let handle,done=false;
          handle=SteamClient.User.RegisterForLoginStateChange((_account,state,result)=>{
            done=true;resolve(state===5&&result===1);setTimeout(()=>handle?.unregister?.(),0);
          });
          setTimeout(()=>{if(!done){handle?.unregister?.();resolve(false)}},1500);
        })
        """) as? Bool
        return ready == true && SteamConnectionLog.isConnected(steamDirectory:steamDirectory)
    }

    public func beginBackgroundPresentation() async throws {
        _ = try await evaluate(SteamInstallPresentation.script + ";window.__mguInstallPresentation.begin()")
    }

    public func touchBackgroundPresentation() async throws {
        _ = try await evaluate("window.__mguInstallPresentation?.touch()??false")
    }

    public func endBackgroundPresentation(showPending: Bool = false) async {
        _ = try? await evaluate("window.__mguInstallPresentation?.end(\(showPending ? "true":"false"))??true")
    }

    public func hideClientWindow() async throws {
        let directory = try activeDirectory()
        let targets = try await command("Target.getTargets", directory: directory)
        for target in (targets["targetInfos"] as? [[String: Any]] ?? []) where target["title"] as? String == "Steam" {
            guard let id = target["targetId"] as? String else { continue }
            let attached = try await command("Target.attachToTarget", params: ["targetId":id,"flatten":true], directory:directory)
            guard let session = attached["sessionId"] as? String else { continue }
            _ = try? await command("Runtime.evaluate", params: ["expression":"SteamClient.Window.HideWindow();true", "returnByValue":true], directory:directory, session:session)
            _ = try? await command("Target.detachFromTarget", params:["sessionId":session], directory:directory)
        }
    }

    /// Explicit client-window entry only. Steam overrides Chromium's device scale;
    /// use the client's own accessibility setting, not Wine's shared DPI registry.
    public func fitClientWindow() async throws {
        let directory = try activeDirectory()
        let targets = try await command("Target.getTargets", directory: directory)
        let matches = (targets["targetInfos"] as? [[String: Any]] ?? []).filter { ($0["title"] as? String) == "Steam" }
        guard matches.count == 1, let target = matches.first?["targetId"] as? String else { return }
        let attached = try await command("Target.attachToTarget", params: ["targetId": target, "flatten": true], directory: directory)
        guard let session = attached["sessionId"] as? String else { return }
        do {
            let metrics = try await command("Runtime.evaluate", params: [
                "expression": "({width:screen.width,dpr:devicePixelRatio})", "returnByValue": true
            ], directory: directory, session: session)
            let value = (metrics["result"] as? [String: Any])?["value"] as? [String: Any]
            let display = CGDisplayBounds(CGMainDisplayID())
            let dpr = (value?["dpr"] as? Double) ?? 1
            let screenWidth = (value?["width"] as? Double) ?? display.width
            let mode = CGDisplayCopyDisplayMode(CGMainDisplayID())
            let backing = min(3, max(1, Double(mode?.pixelWidth ?? Int(display.width)) / max(1,display.width)))
            let scale = min(3, max(1, screenWidth / max(1,display.width)))
            if dpr < backing, scale > 1.1 {
                // CMsgClientSettings.accessibility_desktop_ui_scale (field 26010,
                // fixed32 float), verified against the installed Steam schema.
                let accepted = try await evaluate("""
                (async()=>{const bytes=[];let tag=26010*8+5;
                while(tag>127){bytes.push((tag&127)|128);tag>>>=7;}bytes.push(tag);
                const f=new DataView(new ArrayBuffer(4));f.setFloat32(0,\(scale),true);
                for(let i=0;i<4;i++)bytes.push(f.getUint8(i));
                return await SteamClient.Settings.SetSetting(btoa(String.fromCharCode(...bytes)));})()
                """) as? Bool
                guard accepted == true else { throw IndieError.invalidData("Steam rejected UI scaling") }
            }
            let pixelScale = dpr > 1 ? backing : scale
            let width = Int(min(1200, max(640, display.width-80)) * pixelScale)
            let height = Int(min(800, max(480, display.height-120)) * pixelScale)
            _ = try await command("Runtime.evaluate", params: ["expression": """
                (async()=>{const w=SteamClient.Window;
                if(await w.IsWindowMaximized())w.ToggleMaximize();
                w.ResizeTo(\(width),\(height),false);return true;})()
                """, "returnByValue": true, "awaitPromise": true], directory: directory, session: session)
        } catch {
            _ = try? await command("Target.detachFromTarget", params: ["sessionId": session], directory: directory)
            throw error
        }
        _ = try? await command("Target.detachFromTarget", params: ["sessionId": session], directory: directory)
    }

    public func install(appID: UInt64, libraryPath: String? = nil) async throws -> SteamBridgeInstallResult {
        guard appID > 0, appID <= UInt32.max, !installing else {
            throw IndieError.invalidArgument("Invalid or concurrent Steam install request")
        }
        installing = true
        defer { installing = false }
        guard try await isAuthenticated() else { return .loginRequired }
        let encodedPath = String(decoding:try JSONEncoder().encode(libraryPath),as:UTF8.self)
        // Do not replace another in-progress wizard. License/EULA/password states need a person.
        for attempt in 0..<2 {
        let opened = try await evaluate("""
        (async()=>{
          const c=SteamClient.Installs, i=await c.GetInstallManagerInfo();
          const folders=await SteamClient.InstallFolder.GetInstallFolders();
          const clean=p=>p.replaceAll('/','\\\\').replace(/\\\\+$/,'').toLowerCase();
          const requested=\(encodedPath);
          const folder=requested===null?folders.find(f=>f.nFolderIndex===0):folders.find(f=>clean(f.strFolderPath)===clean(requested));
          if(!folder||!folder.bIsMounted)throw Error('Library unavailable');
          window.__mguDownloads.installLibraryPath=folder.strFolderPath;
          const ids=(i.rgApps||[]).map(a=>Number(a.nAppID));
          if(![0,14,15,16].includes(i.eInstallState)){
            return ids.length===1&&ids[0]===\(appID)&&i.eInstallState===7;
          }
          const s=window.__mguDownloads;
          s.installRevision=0;s.installStarted=Date.now();
          s.installHandle?.unregister?.();
          s.installHandle=c.RegisterForShowInstallWizard(()=>{s.installRevision++;});
          c.OpenInstallWizard([\(appID)]);return true;
        })()
        """) as? Bool
        guard opened == true else { return .needsInteraction }
        for _ in 0..<60 {
            try Task.checkCancellation()
            let result = try await evaluate("""
            (async()=>{
              if(window.__mguDownloads.items.some(x=>x.appID===\(appID)&&!x.completed&&x.errorCode===0))return 'submitted';
              const c=SteamClient.Installs, i=await c.GetInstallManagerInfo();
              const ids=(i.rgApps||[]).map(a=>Number(a.nAppID));
              window.__mguDownloads.lastInstallDiagnostic={appID:\(appID),state:i.eInstallState,error:i.eAppError,ids,folder:i.iInstallFolder};
              if(ids.length!==1||ids[0]!==\(appID))return 'wait';
              // OpenInstallWizard is asynchronous. Do not report the previous
              // failed wizard before the new request produces an event/state.
              const s=window.__mguDownloads;
              if([14,15,16].includes(i.eInstallState)&&!s.installRevision)return 'wait';
              if(i.eAppError!==0&&i.eInstallState!==7)return 'error:'+i.eAppError;
              if(i.eInstallState===7){
                const folders=await SteamClient.InstallFolder.GetInstallFolders();
                const clean=p=>p.replaceAll('/','\\\\').replace(/\\\\+$/,'').toLowerCase();
                const folder=folders.find(f=>clean(f.strFolderPath)===clean(s.installLibraryPath));
                if(!folder||!folder.bIsMounted)return 'error:15';
                if(i.bIsBackupInstall===true)return 'interaction';
                if(i.iInstallFolder!==folder.nFolderIndex){
                  await c.SetInstallFolder(folder.nFolderIndex);return 'wait';
                }
                if(i.eAppError!==0)return 'error:'+i.eAppError;
                if(Number(i.nDiskSpaceRequired)>Number(i.nDiskSpaceAvailable))return 'error:12';
                await c.SetCreateShortcuts(false,false);await c.ContinueInstall();return 'submitted';
              }
              return [0,1,2,3,5].includes(i.eInstallState)?'wait':'interaction';
            })()
            """) as? String
            if result == "submitted" { return .submitted }
            if result == "interaction" { return .needsInteraction }
            if let result, result.hasPrefix("error:"), let code = Int(result.dropFirst(6)) {
                if attempt == 0, [6,7].contains(code) {
                    // Reconnect() is a LOGIN action, not download recovery. It
                    // can submit cleared credentials and invalidate the live session.
                    try await Task.sleep(for: .seconds(2))
                    guard try await isAuthenticated() else { return .loginRequired }
                    break
                }
                return .failed(code: code)
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        }
        return .failed(code: 7)
    }

    private func activeDirectory() throws -> URL {
        let fm = FileManager.default
        let attributes = try fm.attributesOfItem(atPath: root.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700 else {
            throw IndieError.invalidArgument("Unsafe Steam bridge permissions")
        }
        let directories = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let live = directories.filter { url in
            guard url.lastPathComponent.range(of: #"^\d+-\d+$"#, options: .regularExpression) != nil,
                  let attrs = try? fm.attributesOfItem(atPath: url.path),
                  attrs[.type] as? FileAttributeType == .typeDirectory,
                  let date = try? url.appendingPathComponent("ready").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  abs(date.timeIntervalSinceNow) < 4 else { return false }
            return true
        }
        guard live.count == 1, let directory = live.first else {
            context = nil
            throw IndieError.notFound(L("Steam 后台连接尚未就绪"))
        }
        return directory
    }

    private func command(_ method: String, params: [String: Any] = [:],
                         directory: URL, session: String? = nil) async throws -> [String: Any] {
        // Chromium's protocol dispatcher parses signed 32-bit request ids.
        let id = UInt32.random(in: 1...UInt32(Int32.max))
        let request = directory.appendingPathComponent("\(id).request")
        let response = directory.appendingPathComponent("\(id).response")
        var message: [String: Any] = ["id": id, "method": method, "params": params]
        if let session { message["sessionId"] = session }
        let data = try JSONSerialization.data(withJSONObject: message)
        guard data.count <= 32768 else { throw IndieError.invalidArgument("Steam request too large") }
        try data.write(to: request, options: .atomic)
        defer {
            try? FileManager.default.removeItem(at: request)
            try? FileManager.default.removeItem(at: response)
        }
        for _ in 0..<160 {
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: response.path) {
                let attrs = try FileManager.default.attributesOfItem(atPath: response.path)
                guard attrs[.type] as? FileAttributeType == .typeRegular,
                      (attrs[.size] as? NSNumber)?.intValue ?? Int.max <= 1024 * 1024 else {
                    throw IndieError.invalidArgument("Invalid Steam response")
                }
                guard let json = try JSONSerialization.jsonObject(with: Data(contentsOf: response)) as? [String: Any],
                      (json["id"] as? NSNumber)?.uint32Value == id,
                      json["error"] == nil, let result = json["result"] as? [String: Any] else {
                    context = nil
                    throw IndieError.invalidArgument(L("Steam 后台接口暂不可用"))
                }
                return result
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        context = nil
        throw IndieError.notFound(L("Steam 后台响应超时"))
    }

    private func evaluate(_ expression: String) async throws -> Any {
        let directory = try activeDirectory()
        if context?.directory != directory {
            let targets = try await command("Target.getTargets", directory: directory)
            let matches = (targets["targetInfos"] as? [[String: Any]] ?? []).filter { ($0["title"] as? String) == "SharedJSContext" }
            guard matches.count == 1, let target = matches.first?["targetId"] as? String else {
                throw IndieError.notFound(L("Steam 后台连接尚未就绪"))
            }
            let attached = try await command("Target.attachToTarget", params: ["targetId": target, "flatten": true], directory: directory)
            guard let session = attached["sessionId"] as? String else {
                throw IndieError.notFound(L("Steam 后台接口暂不可用"))
            }
            context = (directory, session)
        }
        guard let session = context?.session else { throw IndieError.notFound("No Steam session") }
        let result = try await command("Runtime.evaluate", params: [
            "expression": Self.subscription + ";window.__mguInstallPresentation?.touch?.();" + expression,
            "returnByValue": true, "awaitPromise": true, "userGesture": true
        ], directory: directory, session: session)
        guard result["exceptionDetails"] == nil,
              let remote = result["result"] as? [String: Any], let value = remote["value"] else {
            context = nil
            throw IndieError.invalidArgument(L("Steam 后台接口暂不可用"))
        }
        return value
    }

    // Only sanitized local download fields leave Steam. No account names, cookies, URLs or tokens.
    private static let subscription = #"""
    (()=>{
      if(window.__mguDownloads?.version===3){window.__mguDownloads.lease=Date.now();return;}
      const previous=window.__mguDownloads;
      if(previous){previous.handles?.forEach(h=>h?.unregister?.());previous.installHandle?.unregister?.();clearInterval(previous.timer);}
      const s=window.__mguDownloads={version:3,lease:Date.now(),items:[],overview:null,handles:[]};
      const number=v=>Number.isFinite(Number(v))&&v!=null?Math.max(0,Number(v)):null;
      const c=window.SteamClient;
      if(!c?.Downloads?.RegisterForDownloadItems) {delete window.__mguDownloads;throw Error('not ready');}
      s.handles.push(c.Downloads.RegisterForDownloadItems((changed,groups)=>{
        const local=groups.find(g=>String(g.remote_client_id)==='0');
        if(!local)return; // remote-only deltas must not erase the local queue
        const previous=new Map(s.items.map(i=>[i.appID,i]));
        s.items=(local.item_data||[]).map(i=>({appID:Number(i.appid),completed:!!i.completed,
          paused:!!i.paused,errorCode:Number(i.update_result)||0,
          downloadedBytes:number(i.downloaded_bytes),totalBytes:number(i.total_bytes),
          progress:i.completed?null:previous.get(Number(i.appid))?.progress??null,
          bytesPerSecond:i.completed||i.paused?0:previous.get(Number(i.appid))?.bytesPerSecond??null}));
        if(!s.items.some(i=>i.appID===s.overview?.appID&&!i.completed))s.overview=null;
      }));
      s.handles.push(c.Downloads.RegisterForDownloadOverview(o=>{
        if(String(o.remote_client_id)!=='0')return;
        s.items.forEach(i=>{i.progress=null;i.bytesPerSecond=null;});
        const item=s.items.find(i=>i.appID===Number(o.update_appid)&&!i.completed);
        s.overview=item?{appID:item.appID}:null;
        if(item&&Number.isFinite(o.overall_percent_complete))item.progress=Math.max(0,Math.min(1,o.overall_percent_complete/100));
        if(item){
          item.bytesPerSecond=item.paused?0:number(o.update_network_bytes_per_second);
          item.downloadedBytes=number(o.update_bytes_downloaded)??item.downloadedBytes;
          item.totalBytes=number(o.update_bytes_to_download)??item.totalBytes;
        }
      }));
      s.timer=setInterval(()=>{if(Date.now()-s.lease>60000){s.handles.forEach(h=>h?.unregister?.());
        s.installHandle?.unregister?.();clearInterval(s.timer);delete window.__mguDownloads;}},30000);
    })()
    """#
}
