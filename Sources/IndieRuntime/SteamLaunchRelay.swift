import Foundation

/// Intercepts local Steam UI Play requests before Steam creates a game process.
/// The original Steam launch contract is resumed by the native -applaunch path.
public enum SteamLaunchRelay {
    public static func script(appIDs: [UInt64]) -> String {
        let ids = appIDs.filter { $0 > 0 && $0 <= UInt32.max }.sorted().map(String.init).joined(separator: ",")
        return installation + ";window.__mguLaunchRelay.configure([\(ids)]);window.__mguLaunchRelay.take()"
    }

    public static let installation = #"""
    (()=>{
      const apps=window.SteamClient?.Apps;
      if(!apps||typeof apps.RunGame!=='function')throw Error('Steam Play interface unavailable');
      if(window.__mguLaunchRelay?.version===1&&apps.RunGame===window.__mguLaunchRelay.wrapped)return;
      window.__mguLaunchRelay?.dispose();
      const original=apps.RunGame;
      const s={version:1,lease:Date.now(),ids:new Set(),pending:new Set(),queue:[]};
      s.wrapped=function(gameID,...args){
        const text=String(gameID),id=/^[0-9]+$/.test(text)?Number(text):0;
        if(Date.now()-s.lease>15000||!s.ids.has(id))return original.call(this,gameID,...args);
        if(!s.pending.has(id)){s.pending.add(id);s.queue.push(id);}
      };
      s.configure=ids=>{s.ids=new Set(ids);s.lease=Date.now();};
      s.take=()=>({active:apps.RunGame===s.wrapped,appIDs:s.queue.splice(0)});
      s.complete=id=>s.pending.delete(id);
      s.dispose=()=>{if(apps.RunGame===s.wrapped)apps.RunGame=original;clearInterval(s.timer);};
      apps.RunGame=s.wrapped;
      if(apps.RunGame!==s.wrapped)throw Error('Steam Play interface is read-only');
      s.timer=setInterval(()=>{if(Date.now()-s.lease>15000){s.dispose();delete window.__mguLaunchRelay;}},5000);
      window.__mguLaunchRelay=s;
    })()
    """#
}
