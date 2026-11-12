const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.TS_LIB || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const root = path.resolve(__dirname, '..');
const bytes = {
  encodeText: text => new TextEncoder().encode(text),
  decodeText: b => new TextDecoder().decode(b),
  concat: parts => { const out = new Uint8Array(parts.reduce((n,p)=>n+p.length,0)); let off=0; for(const p of parts){out.set(p,off);off+=p.length;} return out; },
  toArrayBuffer: b => b.buffer.slice(b.byteOffset,b.byteOffset+b.byteLength),
  indexOf: (b,p,start=0) => Buffer.from(b).indexOf(Buffer.from(p),start)
};
const deferred = () => { let resolve,reject; const promise=new Promise((a,b)=>{resolve=a;reject=b;});return {promise,resolve,reject}; };
async function flush(){ for(let i=0;i<25;i++)await Promise.resolve(); }
function clock(){let next=1;const jobs=new Map();return {
  jobs, setTimeout:(fn,ms)=>{const id=next++;jobs.set(id,{fn,ms});return id;},
  clearTimeout:id=>jobs.delete(id),setInterval:(fn,ms)=>{const id=next++;jobs.set(id,{fn,ms,interval:true});return id;},clearInterval:id=>jobs.delete(id),
  async fire(ms){for(const [id,j] of [...jobs])if(j.ms===ms){if(!j.interval)jobs.delete(id);j.fn();}await flush();}
};}
function load(file, mocks={}, timers=clock()){
  const src=fs.readFileSync(path.join(root,file),'utf8');
  const out=ts.transpileModule(src,{compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS}}).outputText;
  const exports={};
  const defaults={LogCapture:{i(){},w(){},e(){}},ByteUtils:bytes,SecurityUtils:{createToken:()=>String(Math.random())},SettingsStore:{current:()=>({alias:'test',alwaysVisible:false})}};
  vm.runInNewContext(out,{exports,require:(name)=>{
    if(name in mocks)return mocks[name];
    if(name.endsWith('HttpBodyParser'))return load('entry/src/main/ets/common/HttpBodyParser.ets',{},timers);
    for(const [key,value]of Object.entries(defaults))if(name.endsWith(key))return {[key]:value};
    return {};
  },Uint8Array,ArrayBuffer,TextDecoder,TextEncoder,console,...timers},{filename:file});
  return exports;
}
function multicast(options={}){
 const timers=clock(), sockets=[], nativeCalls=[];
 const native=new Proxy({hotspotInterfaces:()=>[],ifaceOnSameSubnet:()=>''},{get:(obj,key)=>obj[key]||((...args)=>{nativeCalls.push([key,...args]);return true;})});
 const {MulticastDiscovery}=load('entry/src/main/ets/service/MulticastDiscovery.ets',{
  '@kit.NetworkKit':{socket:{constructMulticastSocketInstance(){
   const events={}; const n=sockets.length;
   const sock={events,closed:0,binds:0,options:[],sent:[],
    on:(key,cb)=>events[key]=cb,
    setExtraOptions:async opt=>{assert.equal(sock.bindComplete,true,'SDK requires completed bind before setExtraOptions');sock.options.push(opt);},
    bind:()=>{sock.binds++;return (options.bind?.(n)||Promise.resolve()).then(()=>{sock.bindComplete=true;});},
    close:()=>{sock.closed++;return options.close?.(n,sock.closed)||Promise.resolve();},
    addMembership:()=>options.join?.(n)||Promise.resolve(),
    send:async arg=>sock.sent.push(arg)}; sockets.push(sock);return sock;
  }}},'./NetDiscoveryNative':{NetDiscoveryNative:native},'@ohos.deviceInfo':{marketName:'test'}
 },timers);
 const discovery=new MulticastDiscovery(()=>{},()=>false,()=> '192.168.1.2');
 return {discovery,sockets,timers,nativeCalls};
}
test('stop during bind closes the owned socket and suppresses late setup',async()=>{
 const gate=deferred();const {discovery:d,sockets,timers}=multicast({bind:()=>gate.promise});
 d.start();await flush();assert.equal(sockets.length,1);d.stop();gate.resolve();await flush();
 assert.equal(sockets[0].closed,1);assert.equal(d.bound,false);assert.equal(timers.jobs.size,0);
});
test('rapid stop/start waits for old bind and close before constructing the replacement',async()=>{
 const bind=deferred(),close=deferred();const {discovery:d,sockets}=multicast({bind:n=>n===0?bind.promise:Promise.resolve(),close:n=>n===0?close.promise:Promise.resolve()});
 d.start();await flush();d.stop();d.start();await flush();assert.equal(sockets.length,1);
 bind.resolve();await flush();assert.equal(sockets.length,1);close.resolve();await flush();
 assert.equal(sockets.length,2);assert.equal(d.multicastSocket,sockets[1]);assert.equal(d.bound,true);d.stop();await flush();
});
test('close failure retains ownership; a later start retries release before binding',async()=>{
 const {discovery:d,sockets}=multicast({close:(n,count)=>n===0&&count===1?Promise.reject({code:2300999}):Promise.resolve()});
 d.start();await flush();d.stop();await flush();assert.equal(d.multicastSocket,sockets[0]);
 d.start();await flush();assert.equal(sockets[0].closed,2);assert.equal(sockets.length,2);d.stop();await flush();
});
test('bind failure retries once and reports setup failure without claiming a stale owner',async()=>{
 const {discovery:d,sockets,timers}=multicast({bind:()=>Promise.reject({code:2301098})});
 d.start();await flush();await timers.fire(600);assert.equal(sockets.length,2);assert.equal(sockets[0].closed,1);assert.equal(sockets[1].closed,1);
 assert.match(d.statusHint(),/重试失败/);assert.doesNotMatch(d.statusHint(),/重启手机|残留/);d.stop();await flush();assert.equal(sockets[1].closed,1);
});
test('stop cancels pending retry and stale membership callbacks cannot resurrect native resources',async()=>{
 const joined=deferred();const {discovery:d,timers,nativeCalls}=multicast({join:()=>joined.promise});
 d.start();await flush();d.stop();const n=nativeCalls.length;joined.resolve();await flush();await timers.fire(600);
 assert.equal(nativeCalls.length,n);assert.equal(d.groupJoined,false);assert.equal(timers.jobs.size,0);
});
test('self check requires exact nonce and clears warning only for the active socket',async()=>{
 const {discovery:d,sockets,timers}=multicast();d.start();await flush();const s=sockets[0];
 s.events.message({message:bytes.encodeText('{"cashmereSelfTest":"unrelated"}').buffer,remoteInfo:{address:'127.0.0.1',port:53317}});
 assert.equal(d.selfTestSeen,false);
 s.events.message({message:bytes.encodeText(d.selfTestToken).buffer});await timers.fire(1200);
 assert.equal(d.statusHint(),'');d.stop();await flush();
});
test('native holders bind multicast group; main enables reuse only after bind succeeds',async()=>{
 const cpp=fs.readFileSync(path.join(root,'entry/src/main/cpp/net_discovery.cpp'),'utf8');
 const holder=cpp.slice(cpp.indexOf('napi_value JoinMulticastOn'),cpp.indexOf('// Multicast relay:'));
 assert.match(holder,/local\.sin_addr = groupAddr/);assert.doesNotMatch(holder,/htonl\(INADDR_ANY\)/);
 const {discovery:d,sockets}=multicast();d.start();await flush();assert.equal(sockets[0].options[0].reuseAddress,true);d.stop();await flush();
});
function scanner(behavior){
 const timers=clock();let transport,connects=0;
 const {LocalSendSubnetScanner}=load('entry/src/main/ets/service/LocalSendSubnetScanner.ets',{
  '../common/CertificateStore':{CertificateStore:class{async ensure(){return {certPath:'cert',keyPath:'key'};}}},
  '@ohos.file.fs':{default:{readText:async p=>p}},
  '../common/TlsTransport':{Transports:{open:async(...args)=>{connects++;transport={closed:0,listener:null,onData(fn){this.listener=fn;},async send(){return behavior(this,args);},async close(){this.closed++;}};return transport;}}}
 },timers);
 return {s:new LocalSendSubnetScanner(()=>{},()=>false,{}),timers,get transport(){return transport;},get connects(){return connects;}};
}
const response=(status,body)=>bytes.encodeText(`HTTP/1.1 ${status} OK\r\nContent-Length: ${Buffer.byteLength(body)}\r\n\r\n${body}`);
test('HTTPS subnet probe uses native transport with client credentials and parses a valid info response',async()=>{
 let args;const h=scanner((t,a)=>{args=a;t.listener(response(200,'{"alias":"设备","port":53317}'));});
 const found=[];h.s.emit=d=>found.push(d);await h.s.probeTls('192.168.1.3',0);
 assert.equal(args[2],true);assert.equal(args[3],'cert');assert.equal(args[4],'key');assert.equal(found.length,1);assert.equal(found[0].https,true);assert.equal(h.transport.closed,1);assert.equal(h.timers.jobs.size,0);
});
test('HTTPS hung send terminates at the whole-request deadline and closes transport',async()=>{
 const h=scanner(()=>new Promise(()=>{}));const pending=h.s.requestInfo('192.168.1.3','/info',true);await flush();await h.timers.fire(4000);
 assert.equal((await pending).raw,'');assert.equal(h.transport.closed,1);assert.equal(h.timers.jobs.size,0);
});
test('stop cancels HTTPS request without emitting a late peer',async()=>{
 const h=scanner(()=>new Promise(()=>{}));let emitted=0;h.s.emit=()=>emitted++;
 const pending=h.s.probeTls('192.168.1.3',0);await flush();h.s.stop();await pending;
 h.transport.listener(response(200,'{"alias":"late"}'));assert.equal(emitted,0);assert.equal(h.transport.closed,1);assert.equal(h.timers.jobs.size,0);
});
test('HTTPS error JSON is not accepted as device info and fallback paths are checked',async()=>{
 const h=scanner(t=>t.listener(response(404,'{"alias":"not a peer"}')));let emitted=0;h.s.emit=()=>emitted++;
 await h.s.probeTls('192.168.1.3',0);assert.equal(emitted,0);assert.equal(h.connects,3);
});
test('unframed JSON response waits for complete body fragments',()=>{
 const h=scanner(()=>{});const ctor=h.s.constructor;
 assert.equal(ctor.completeResponse(bytes.encodeText('HTTP/1.1 200 OK\r\n\r\n{"alias":')),undefined);
 assert.ok(ctor.completeResponse(bytes.encodeText('HTTP/1.1 200 OK\r\n\r\n{"alias":"peer"}')));
});
test('plaintext transport factory closes after bind or connect failure',async()=>{
 for(const bindFails of [false,true]){
  let closed=0;const tcp={bind:async()=>{if(bindFails)throw new Error('bind failed');},on(){},connect:async()=>{throw new Error('refused');},close:async()=>{closed++;}};
  const {Transports}=load('entry/src/main/ets/common/TlsTransport.ets',{'@kit.NetworkKit':{socket:{constructTCPSocketInstance:()=>tcp}}});
  await assert.rejects(Transports.open('peer',1,false));assert.equal(closed,1);
 }
});
test('LocalSend request deadline ends hung upload and clears timers',async()=>{
 const timers=clock();let closed=0;const transport={send:async()=>new Promise(()=>{}),onData(){},close:async()=>{closed++;}};
 const {LocalSendClient}=load('entry/src/main/ets/protocol/localsend/LocalSendClient.ets',{
  '../../common/CertificateStore':{CertificateStore:class{}},
  '../../common/TlsTransport':{Transports:{open:async()=>transport}}
 },timers);
 const client=new LocalSendClient({});const pending=client.request({address:'peer',port:1,https:false},{method:'POST',path:'/upload',contentType:'test',contentLength:10,timeoutMs:50});
 await flush();await timers.fire(50);assert.equal((await pending).status,0);assert.equal(closed,1);assert.equal(timers.jobs.size,0);
});
test('LocalSend send rejection clears deadline and stall timers',async()=>{
 const timers=clock();let closed=0;const {LocalSendClient}=load('entry/src/main/ets/protocol/localsend/LocalSendClient.ets',{
  '../../common/CertificateStore':{CertificateStore:class{}},
  '../../common/TlsTransport':{Transports:{open:async()=>({send:async()=>{throw new Error('write failed');},onData(){},close:async()=>{closed++;}})}}
 },timers);
 const client=new LocalSendClient({});await assert.rejects(client.request({address:'peer',port:1,https:false},{method:'POST',path:'/upload',contentType:'test',contentLength:0,timeoutMs:50}));
 assert.equal(closed,1);assert.equal(timers.jobs.size,0);
});
function localDiscovery(mdns){
 const timers=clock();
 const {LocalSendDiscovery}=load('entry/src/main/ets/service/LocalSendDiscovery.ets',{
  '@ohos.net.mdns':{default:mdns},'@ohos.deviceInfo':{default:{marketName:'test'}},
  '../common/AdvertisementIdentity':{AdvertisementIdentity:{localSendInstanceSuffix:()=> 'persistent'}},
  './MulticastDiscovery':{MulticastDiscovery:class {setAdvertising(){}setHttps(){}setFingerprint(){}setPort(){}}},
  './LocalSendSubnetScanner':{LocalSendSubnetScanner:class {stop(){}}}
 },timers);
 return {d:new LocalSendDiscovery({}),timers};
}
test('mDNS add completing after visibility off is removed, including duplicate adoption',async()=>{
 for(const duplicate of [false,true]){
  const gate=deferred();let removed=0;
  const {d}=localDiscovery({addLocalService:()=>gate.promise,removeLocalService:async()=>{removed++;}});
  d.setVisible(true);await flush();d.setVisible(false);
  if(duplicate)gate.reject({code:2204007});else gate.resolve({serviceName:'persistent'});
  await d.advertisementOperation;assert.equal(removed,1);assert.equal(d.advertisedService,undefined);
 }
});
test('mDNS protocol refresh serializes removal before new registration',async()=>{
 const calls=[];const removal=deferred();
 const {d}=localDiscovery({addLocalService:async(_c,info)=>{calls.push('add');return info;},removeLocalService:()=>{calls.push('remove');return removal.promise;}});
 d.setVisible(true);await d.advertisementOperation;d.setHttps(true);await flush();
 assert.deepEqual(calls,['add','remove']);removal.resolve();await d.advertisementOperation;
 assert.deepEqual(calls,['add','remove','add']);
 assert.equal(bytes.decodeText(Uint8Array.from(d.advertisedService.serviceAttribute.find(a=>a.key==='protocol').value)),'https');
});
test('malformed datagrams cannot throw out of the UDP callback',()=>{
 const {discovery:d}=multicast();
 for(const raw of ['null','{"alias":"bad","protocol":42}','{"__relay":true,"from":7,"data":{}}']){
  assert.doesNotThrow(()=>d.handleDatagram(raw,'192.168.1.3',53317));
 }
});
