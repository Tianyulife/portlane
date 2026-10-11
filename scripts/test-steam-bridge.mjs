// Run the production Swift-embedded JavaScript against deterministic native API mocks.
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const source=readFileSync(new URL('../Sources/IndieRuntime/SteamDownloadBridge.swift',import.meta.url),'utf8');
assert.ok(!/SteamClient\.User\.Reconnect\s*\(/.test(source),'Download retries must never submit login credentials');
const subscription=source.match(/private static let subscription = #"""([\s\S]*?)"""#/)[1];
const install=source.slice(source.indexOf('public func install('),source.indexOf('private func activeDirectory'));
const expressions=[...install.matchAll(/"""([\s\S]*?)"""/g)].map(m=>m[1].replaceAll('\\\\','\\').replaceAll('\\(appID)','4364910').replaceAll('\\(encodedPath)','null'));
assert.equal(expressions.length,2);
let items,overview,wizard,shortcuts=false,continued=false;
let info={eInstallState:0,eAppError:0,rgApps:[],iInstallFolder:0};
const handle=()=>({unregister(){}});
let folders=[{nFolderIndex:0,strFolderPath:'C:\\Steam',bIsMounted:true}];
const client={InstallFolder:{async GetInstallFolders(){return folders;}},Downloads:{
 RegisterForDownloadItems(cb){items=cb;return handle();},
 RegisterForDownloadOverview(cb){overview=cb;return handle();}
},Installs:{
 async GetInstallManagerInfo(){return info;},
 async SetInstallFolder(index){info={...info,iInstallFolder:index};},
 RegisterForShowInstallWizard(cb){wizard=cb;return handle();},
 OpenInstallWizard(){},
 async SetCreateShortcuts(){await Promise.resolve();shortcuts=true;},
 async ContinueInstall(){assert.ok(shortcuts,'Must await shortcut update before continuing');continued=true;}
}};
const window={SteamClient:client};
const context=vm.createContext({window,SteamClient:client,Date,setInterval:()=>1,clearInterval(){}});
vm.runInContext(subscription,context);
items(true,[{remote_client_id:'0',item_data:[{appid:4364910,completed:false}]}]);
overview({remote_client_id:'0',update_appid:4364910,overall_percent_complete:42});
assert.equal(window.__mguDownloads.items[0].progress,0.42);
overview({remote_client_id:'0',update_appid:4364910,overall_percent_complete:42,update_network_bytes_per_second:1048576,update_bytes_downloaded:42,update_bytes_to_download:100});
assert.equal(window.__mguDownloads.items[0].bytesPerSecond,1048576);
assert.equal(window.__mguDownloads.items[0].downloadedBytes,42);
items(true,[{remote_client_id:'remote',item_data:[]}]);
assert.equal(window.__mguDownloads.items[0].progress,0.42,'Remote deltas must preserve local state');
assert.equal(await vm.runInContext(expressions[1],context),'submitted','Download queue is an acknowledgement even when wizard is gone');
items(true,[{remote_client_id:'0',item_data:[]}]);
info={eInstallState:15,eAppError:6,rgApps:[{nAppID:4364910}],iInstallFolder:0};
assert.equal(await vm.runInContext(expressions[0],context),true);
assert.equal(await vm.runInContext(expressions[1],context),'wait','Ignore stale terminal state');
wizard(info);
assert.equal(await vm.runInContext(expressions[1],context),'error:6','Network failure is not an EULA');
info={...info,eInstallState:8,eAppError:0};
assert.equal(await vm.runInContext(expressions[1],context),'interaction');
assert.equal(continued,false,'Never accept an EULA automatically');
info={...info,eInstallState:7};
assert.equal(await vm.runInContext(expressions[1],context),'submitted');
assert.ok(continued);
continued=false;
folders.push({nFolderIndex:4,strFolderPath:'D:\\Game Library',bIsMounted:true});
window.__mguDownloads.installLibraryPath='d:\\Game Library\\';
assert.equal(await vm.runInContext(expressions[1],context),'wait');
assert.equal(info.iInstallFolder,4);
assert.equal(await vm.runInContext(expressions[1],context),'submitted');
folders[1].bIsMounted=false;
assert.equal(await vm.runInContext(expressions[1],context),'error:15','Disconnected target must not fall back to C:');
items(true,[{remote_client_id:'0',item_data:[{appid:4364910,completed:true}]}]);
overview({remote_client_id:'0',update_appid:0,overall_percent_complete:0});
assert.equal(window.__mguDownloads.items[0].progress,null);
assert.equal(window.__mguDownloads.items[0].bytesPerSecond,null);
// Current Steam schema, > 32-bit counters, and an overview preceding item delivery.
items(true,[{remote_client_id:'0',item_data:[]}]);
const total=134794763088,downloaded=64701486282;
const stages=[{}, {}, {bytes_in_progress:downloaded,bytes_total:total}];
overview({remote_client_id:'0',update_appid:2358720,overall_percent_complete:48,
 update_state:'Downloading',progress:stages,update_network_bytes_per_second:46600000});
items(true,[{remote_client_id:'0',item_data:[{appid:2358720,completed:false,
 downloaded_bytes:85000000,total_bytes:1,update_type_info:[{progress:stages}]}]}]);
assert.equal(window.__mguDownloads.items[0].progress,0.48);
assert.equal(window.__mguDownloads.items[0].downloadedBytes,downloaded);
assert.equal(window.__mguDownloads.items[0].totalBytes,total);
assert.equal(window.__mguDownloads.items[0].bytesPerSecond,46600000);
assert.equal(window.__mguDownloads.items[0].phase,'Downloading');
items(true,[{remote_client_id:'other-device',item_data:[]}]);
assert.equal(window.__mguDownloads.items[0].totalBytes,total);
overview({remote_client_id:'0',update_appid:0,overall_percent_complete:0});
items(true,[{remote_client_id:'0',item_data:[{appid:2358720,completed:false,downloaded_bytes:85000000,total_bytes:1}]}]);
assert.equal(window.__mguDownloads.items[0].totalBytes,null,'Reject impossible totals instead of displaying 0 KB');
assert.equal(window.__mguDownloads.items[0].downloadedBytes,null,'Byte pairs must use a single coherent source');
console.log('PASS: remote deltas, queue acknowledgement, stale wizard, network errors, EULA, async continuation, completion cleanup');
