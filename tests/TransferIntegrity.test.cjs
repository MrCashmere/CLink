// Exercise the production transfer paths with deterministic sockets and filesystems.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.TS_LIB || 'C:/Program Files/Huawei/DevEco Studio/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const entry=path.join(__dirname, '../entry/src/main/ets') + '/';
const gs=path.join(__dirname, '../gs/src/main/ets') + '/';
const quiet={i(){},w(){},e(){},d(){},flushNow(){}};
const context={filesDir:'/sandbox/files',cacheDir:'/sandbox/cache'};
const deferred=()=>{let resolve; const promise=new Promise(r=>resolve=r); return {promise,resolve};};
const wait=()=>new Promise(r=>setImmediate(r));
function makeDisk({shortWrite=0}={}) {
  const disk=new Map();
  const dirs=new Set(['/']);
  return {disk, api:{
    OpenMode:{READ_ONLY:0,READ_WRITE:2,CREATE:64,TRUNC:512},
    accessSync:p=>disk.has(p)||dirs.has(p),
    mkdirSync:p=>dirs.add(p),
    openSync(p,mode){if(mode===0&&!disk.has(p))throw new Error('not found');if(!disk.has(p)||mode&512) disk.set(p,Buffer.alloc(0));return {fd:p};},
    closeSync(){}, unlinkSync:p=>disk.delete(p), statSync:p=>({size:disk.get(p).length}),
    writeSync(p,b){const v=Buffer.from(b);const n=Math.max(0,v.length-shortWrite); disk.set(p,Buffer.concat([disk.get(p),v.subarray(0,n)]));return n;},
    async write(p,b){return this.writeSync(p,b);}
  }};
}
function loader(extra={}) {
  const cache=new Map();
  const logConsole={info(){},debug(){},warn(){},error(){},log(){}};
  function load(file){
    const p=path.resolve(file);
    if(cache.has(p))return cache.get(p).exports;
    const source=fs.readFileSync(p,'utf8');
    const code=ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS}}).outputText;
    const mod={exports:{}};cache.set(p,mod);
    const imp=id=>{
      if(id in extra)return extra[id];
      if(id==='@kit.ArkTS')return {util:{TextEncoder,TextDecoder:{create:()=>new TextDecoder()}}};
      if(id.startsWith('../../')&&/\/(DynamicPhotoBridge|DynamicPhotoService|GalleryAutoSaveService)$/.test(id))return {};
      if(id.endsWith('/LogCapture'))return {LogCapture:quiet};
      if(id.endsWith('/CertificateStore'))return {CertificateStore:class{}};
      if(id.endsWith('/SettingsStore'))return {SettingsStore:{current:()=>({})}};
      if(id.endsWith('/PeerLivePhotoFormat'))return {PeerLivePhotoFormat:{resolveForUserAgent:()=>({brand:''})}};
      if(id.endsWith('/SecurityUtils'))return {SecurityUtils:{createToken:()=>Math.random().toString(16),createPin:()=> '1234'}};
      if(id.endsWith('/GsCrypto'))return {GsCrypto:{createToken:()=> 'gate',randomBytes:async n=>new Uint8Array(n)}};
      if(id.startsWith('.')&&fs.existsSync(path.resolve(path.dirname(p),id+'.ets')))return load(path.resolve(path.dirname(p),id+'.ets'));
      return {};
    };
    vm.runInNewContext(code,{module:mod,exports:mod.exports,require:imp,console:logConsole,Uint8Array,ArrayBuffer,TextDecoder,TextEncoder,
      setTimeout:()=>1,clearTimeout(){},setInterval:()=>1,clearInterval(){},...extra.globals},{filename:p});
    return mod.exports;
  }
  return load;
}
function conn() {
  return {
    sent:[], onData(cb){this.data=cb;},onClose(cb){this.closed=cb;},close(){},
    peerAddress:async()=> '192.0.2.4',
    async sendBytes(b){this.sent.push(Buffer.from(b));},
    body(){return Buffer.concat(this.sent).toString().split('\r\n\r\n')[1];},
    status(){return Number(Buffer.concat(this.sent).toString().slice(9,12));}
  };
}
function localServer(diskApi) {
  const {LocalSendServer}=loader({
    '@ohos.file.fs':{default:diskApi},
    '../../common/TlsTransport':{},
    '../../common/ByteUtils':{ByteUtils:{
      encodeText:s=>new TextEncoder().encode(s),decodeText:b=>new TextDecoder().decode(b),
      concat:ps=>new Uint8Array(Buffer.concat(ps.map(p=>Buffer.from(p)))),
      indexOf:(b,p,start=0)=>Buffer.from(b).indexOf(Buffer.from(p),start),
      toArrayBuffer:b=>b.buffer.slice(b.byteOffset,b.byteOffset+b.byteLength)
    }}
  })(entry+'protocol/localsend/LocalSendServer.ets');
  const server=new LocalSendServer(context);
  const progress=[],received=[],staged=[];
  server.setHandler({
    onSessionRequested:async()=>true,onSessionResolved(){},
    async onFileStaged(id,file){staged.push(file);},
    onFileReceived(id,file){received.push(file);},onProgress(id,value){progress.push(value);}
  });
  server.relocateIncoming=async p=>p;
  return {server,progress,received,staged};
}
async function prepare(server,files){
  const c=conn();
  await server.handleSendRequest({
    query:new Map(),headers:new Map(),body:new TextEncoder().encode(JSON.stringify({files}))
  },c);
  assert.equal(c.status(),200);
  return JSON.parse(c.body());
}
async function upload(server,s,id,bytes){
  const c=conn();server.handleConnection(c);
  const head='POST /api/localsend/v2/upload?sessionId='+s.sessionId+'&fileId='+id+'&token='+s.files[id]+' HTTP/1.1\r\n'
      +'Content-Type: application/octet-stream\r\nContent-Length: '+bytes.length+'\r\n\r\n';
  c.data(new Uint8Array(Buffer.concat([Buffer.from(head),Buffer.from(bytes)])));
  await wait();
  return c;
}
test('LocalSend counts each file ID once and keeps the announced MIME type',async()=>{
  const {server,progress,received,staged}=localServer(makeDisk().api);
  const s=await prepare(server,{a:{fileName:'opaque-image',size:3,fileType:'image/jpeg'},b:{fileName:'b.txt',size:3,fileType:'text/plain'}});
  assert.equal((await upload(server,s,'a','one')).status(),200);
  assert.equal((await upload(server,s,'a','two')).status(),409);
  assert.ok(progress.at(-1) < 100);
  assert.equal((await upload(server,s,'b','end')).status(),200);
  assert.deepEqual(received.map(f=>f.name),['opaque-image','b.txt']);
  assert.equal(progress.at(-1),100);
  assert.equal(staged[0].mime,'image/jpeg');
});
test('LocalSend never truncates a previously staged file with the same name',async()=>{
  const {disk,api}=makeDisk();
  const {server}=localServer(api);
  const now=Date.now;
  Date.now=()=>1730000000000;
  try {
    const a=server.openIncomingStream('a.txt'), b=server.openIncomingStream('a.txt');
    disk.set(b.path,Buffer.from('prior'));
    const c=server.openIncomingStream('a.txt');
    assert.notEqual(a.path,b.path);assert.notEqual(b.path,c.path);
    assert.equal(disk.get(b.path).toString(),'prior');
  } finally {Date.now=now;}
});
test('web download does not certify a truncated body as complete',async()=>{
  const {disk,api}=makeDisk();
  disk.set('/sample',Buffer.from('ab'));
  api.statSync=()=>({size:6});
  api.readSync=(fd,b,o)=>{if(o.offset>0)return 0;new Uint8Array(b).set(disk.get(fd));return 2;};
  const {server}=localServer(api);
  server.shareForBrowser=async s=>s;
  const shareId=server.addShare('/sample','sample.txt',6);
  const c=conn();
  await server.handleDownload({headers:new Map()},c,shareId);
  assert.equal(c.status(),200);assert.equal(c.body(),'2\r\nab\r\n');
  assert.doesNotMatch(Buffer.concat(c.sent).toString(),/\r\n0\r\n\r\n$/);
});
function qs(diskApi){
  const load=loader({'@ohos.file.fs':{default:diskApi},
    '../util/GsBytes':{GsBytes:{
      encodeText:s=>new TextEncoder().encode(s),decodeText:b=>new TextDecoder().decode(b),cleanText:s=>s,
      readU32BE:(b,o)=>new DataView(b.buffer,b.byteOffset,b.byteLength).getUint32(o),
      writeU32BE:n=>{const b=new Uint8Array(4);new DataView(b.buffer).setUint32(0,n);return b;},
      toArrayBuffer:b=>b.buffer.slice(b.byteOffset,b.byteOffset+b.byteLength),
      concat:ps=>new Uint8Array(Buffer.concat(ps.map(p=>Buffer.from(p))))
    }}});
  const {QuickShareReceiver}=load(gs+'quickshare/QuickShareChannel.ets');
  const {NearDropWire}=load(gs+'quickshare/NearDropWire.ets');
  return {QuickShareReceiver,NearDropWire};
}
test('Quick Share rejects a different payload ID and removes a partially written file',async()=>{
  const {disk,api}=makeDisk({shortWrite:1});
  const {QuickShareReceiver,NearDropWire:w}=qs(api);
  const file={name:'other',size:2,mimeType:'application/octet-stream'};
  const frames=[w.payload(22,file,0,new Uint8Array([1,2]),false),w.payload(22,file,2,new Uint8Array(0),true)];
  const r=new QuickShareReceiver(context,'app');
  await assert.rejects(r.receiveFile({next:async()=>frames.shift()},{decrypt:async b=>b},
    {id:'11',name:'requested.txt',size:2},()=>{},async()=>{},{},false), /标识/);
  assert.equal(disk.size,0);

  const requested=w.payload(17,file,0,new Uint8Array([1,2]),false);
  await assert.rejects(r.receiveFile({next:async()=>requested},{decrypt:async b=>b},
    {id:'11',name:'requested.txt',size:2},()=>{},async()=>{},{},false), /写入不完整/);
  assert.equal(disk.size,0);
});
test('Quick Share reads the complete batch before awaiting gallery and retains MIME',async()=>{
  const {QuickShareReceiver,NearDropWire:w}=qs(makeDisk().api);
  const r=new QuickShareReceiver(context);
  const incoming=[
    {name:'extensionless',size:3,payloadId:1,mimeType:'image/jpeg'},
    {name:'b.bin',size:4,payloadId:2,mimeType:'application/octet-stream'}
  ];
  const peerFrames=[w.pairedKeyEncryption(),w.pairedKeyResult(),w.introduction(incoming)];
  r.nextSharingFrame=async()=>w.parseSharing(peerFrames.shift());
  r.sendSharingFrame=async()=>{};
  const fileReads=[];
  r.receiveFile=async(_i,_h,m)=>{fileReads.push(m);return m;};
  const auth=deferred();
  const hooks={
    onIncomingSession:async()=>true,
    onFileReceived:async f=>{if(f.name==='extensionless')await auth.promise;},
    onProgress(){}
  };
  const request=w.connectionRequest('peer','Peer',new Uint8Array(0),new Uint8Array(0));
  const session={
    handshake:{prepare:async()=>{},buildServerInit:async()=>new Uint8Array(0),processClientFinish:async()=>{},markVerified(){},encrypt:async b=>b},
    inbox:{next:async key=>key===1?request:new Uint8Array(0)}, send:async()=>{},hooks,
    activeConn:{close(){}}
  };
  const pending=r.runSession(session,hooks);
  await wait();assert.equal(fileReads.length,2);assert.equal(fileReads[0].mime,'image/jpeg');
  auth.resolve();await pending;assert.equal(fileReads.length,2);
});
test('Quick Share consumes the zero-byte file terminator before reading the next file',async()=>{
  const {QuickShareReceiver,NearDropWire:w}=qs(makeDisk().api);
  const empty={name:'empty',size:0,mimeType:'application/octet-stream'};
  const nonempty={name:'nonempty',size:1,mimeType:'application/octet-stream'};
  const frames=[
    w.payload(1,empty,0,new Uint8Array(0),false),w.payload(1,empty,0,new Uint8Array(0),true),
    w.payload(2,nonempty,0,new Uint8Array([55]),false),w.payload(2,nonempty,1,new Uint8Array(0),true)
  ];
  const r=new QuickShareReceiver(context,'app');
  const inbox={next:async()=>frames.shift()};
  const h={decrypt:async b=>b};
  const a=await r.receiveFile(inbox,h,{id:'01',name:empty.name,size:0},()=>{},async()=>{},{},false);
  assert.equal(a.size,0);assert.equal(frames.length,2);
  const b = await r.receiveFile(inbox,h,{id:'02',name:nonempty.name,size:1},()=>{},async()=>{},{},false);
  assert.equal(b.size,1);assert.equal(frames.length,0);
});
test('an idle TCP client cannot claim the Quick Share session slot',async()=>{
  const events={};
  const jobs=new Map();
  let tid=0;
  const load=loader({
    '@kit.NetworkKit':{socket:{constructTCPSocketServerInstance:()=>({on:(k,v)=>events[k]=v,async listen(){},off(){},async close(){}})}},
    './UKEY2Handshake':{UKEY2Handshake:class{async prepare(){}}},
    globals:{setTimeout(fn,ms){const t=++tid;jobs.set(t,{fn,ms});return t;},clearTimeout:t=>jobs.delete(t)}
  });
  const {QuickShareReceiver}=load(gs+'quickshare/QuickShareChannel.ets');
  const receiver=new QuickShareReceiver(context);
  let closed=false;
  const fake={on(){},getRemoteAddress:async()=>({address:'192.0.2.9',port:40000}),async close(){closed=true;}};
  await receiver.start(53318,{});
  events.connect(fake);
  const first=[...jobs.values()].find(v=>v.ms===3000);assert.ok(first);first.fn();
  await wait();
  assert.equal(QuickShareReceiver.activeSession,false);
  assert.equal(closed,true);
  assert.equal(jobs.size,0);
});
test('late Windows media processing cannot append a file to the next session',async()=>{
  const gate=deferred(), added=[], history=[];
  const load=loader({
    './DynamicPhotoService':{DynamicPhotoService:{settleReceivedFile:()=>gate.promise,isClaimedByDynamicPhoto:()=>true}},
    '../windowsnearby/WindowsNearbyBleController':{WindowsNearbyDeviceListener:class{}},
    '../windowsnearby/WindowsNearbySender':{WindowsNearbySenderListener:class{}},
    '../windowsnearby/WindowsNearbyTransfer':{WindowsNearbyTransferListener:class{}},
    '../windowsnearby/WindowsNearbyHistory':{WindowsNearbyHistory:{async add(_ctx,row){history.push(row);}}},
    '../quickshare/service/GalleryAutoSaveService':{}, './AppServices':{}, './NetAddress':{}, './PermissionHelper':{}, './PinDialogGuard':{},
    '../mta/MtaService':{}, '../service/TransferManager':{}, '../utils/DesignTokens':{}, '../utils/SystemMaterial':{},
    '../quickshare/controller/QuickShareBrowser':{}, '../protocol/gs/GsFacade':{}
  });
  const {NearbyScanHub}=load(entry+'common/NearbyScanHub.ets');
  const hub=Object.create(NearbyScanHub.prototype);
  Object.assign(hub,{context,windowsReceiveFiles:[],windowsReceiveTaskId:'A',windowsReceivePeer:'peer-A',
    publishWindowsLive(){},notifyWindowsReceive(){},appServices:{transfer:{addReceivedFile:(id,file)=>added.push({id,file})}}});
  const old=hub.onWindowsFileReceived({name:'only-from-A.jpg',size:3},'/sandbox/files/A.jpg', () => hub.windowsReceiveTaskId === 'A');
  hub.windowsReceiveFiles=[]; hub.windowsReceiveTaskId='B'; hub.windowsReceivePeer='peer-B';
  gate.resolve();await old;
  assert.deepEqual(added,[]);assert.deepEqual(history,[]);assert.deepEqual(hub.windowsReceiveFiles,[]);
});

test('LocalSend consumes a split chunk terminator only after its final CRLF', async () => {
  const {server, received} = localServer(makeDisk().api);
  const session = await prepare(server,{x:{fileName:'x.bin',size:5}});
  const c=conn(); server.handleConnection(c);
  const head='POST /api/localsend/v2/upload?sessionId='+session.sessionId+'&fileId=x&token='+session.files.x+
    ' HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n';
  for (const part of [head+'5\r', '\nhe', 'llo\r', '\n0\r\n\r']) {
    c.data(new TextEncoder().encode(part));
    assert.equal(c.sent.length,0);
  }
  c.data(new TextEncoder().encode('\n'));
  await wait();
  assert.equal(c.status(),200);
  assert.equal(received[0].size,5);
});
test('LocalSend rejects a chunked upload cut off after file bytes but before framing ends', async () => {
  const {disk,api}=makeDisk();
  const {server,received}=localServer(api);
  const session = await prepare(server,{x:{fileName:'x.bin',size:5}});
  const c=conn(); server.handleConnection(c);
  c.data(new TextEncoder().encode('POST /api/localsend/v2/upload?sessionId='+session.sessionId+'&fileId=x&token='+
    session.files.x+' HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n'));
  assert.equal(c.sent.length,0);
  c.closed(); await wait();
  assert.equal(received.length,0);
  assert.equal(disk.size,0);
});
test('LocalSend multipart keeps boundary-like file bytes and waits for a split closing delimiter', async () => {
  const {disk,api}=makeDisk();
  const {server,received}=localServer(api);
  const payload='ordinary--bound file\r\ncontent';
  const session = await prepare(server,{x:{fileName:'x.bin',size:payload.length}});
  const c=conn(); server.handleConnection(c);
  const body='--bound\r\nContent-Disposition: form-data; name="file"; filename="ignored.bin"\r\n\r\n'+payload+
    '\r\n--bound--\r\n';
  const head='POST /api/localsend/v2/upload?sessionId='+session.sessionId+'&fileId=x&token='+session.files.x+
    ' HTTP/1.1\r\nContent-Type: multipart/form-data; boundary=bound\r\nContent-Length: '+body.length+'\r\n\r\n';
  c.data(new TextEncoder().encode(head+body.slice(0,-4)));
  assert.equal(c.sent.length,0);
  c.data(new TextEncoder().encode(body.slice(-4))); await wait();
  assert.equal(c.status(),200);
  assert.equal(received[0].name,'x.bin');
  assert.equal(disk.get(received[0].savedPath).toString(),payload);
});
test('Quick Share distinguishes two IDs beyond JavaScript safe integer precision', () => {
  const {ProtoReader}=loader()(gs+'quickshare/ProtoReader.ets');
  const prefix=[8,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff];
  const a=new Uint8Array([...prefix,0x01]);
  const b=new Uint8Array([...prefix.slice(0,1),0xfe,...prefix.slice(2),0x01]);
  assert.notEqual(ProtoReader.firstVarintKey(a,1),ProtoReader.firstVarintKey(b,1));
  assert.throws(() => ProtoReader.firstVarintKey(new Uint8Array([...prefix,0x02]),1), /exceeds 64 bits/);
});

test('Windows CDP counts overlapping fetch ranges only once and rejects early completion', async () => {
  const {WindowsNearbySender} = loader()(entry+'windowsnearby/WindowsNearbySender.ets');
  const sender = Object.create(WindowsNearbySender.prototype);
  sender.sentRanges = new Map();
  const first = sender.recordSentRange(0, 4, 8);
  const overlap = sender.recordSentRange(0, 2, 6);
  const retry = sender.recordSentRange(0, 4, 8);
  assert.deepEqual([first, overlap, retry], [4, 2, 0]);
  sender.bytesSent = first + overlap + retry;
  sender.bytesToSend = 8;
  await assert.rejects(sender.handleFetchRequest({}, {getUInt32: () => 2}), /文件传完前/);
  assert.equal(sender.recordSentRange(0, 0, 2), 2);
});

test('MTA closes an in-flight dial and ignores late events from its former socket', async () => {
  const sockets = [];
  const makeSocket = () => {
    const events = new Map();
    const socket = {events, on: (name, cb) => events.set(name, cb), off: name => events.delete(name),
      connect: async () => true, close: async () => true, send: async () => false};
    sockets.push(socket);
    return socket;
  };
  const {MtaTransferClient} = loader({
    '@kit.NetworkKit': {webSocket: {createWebSocket: makeSocket}},
    '../NativeBridge': {},
    '../../utils/MtaProgressUtil': {ProgressReportThrottle: class {}},
    '../../utils/Logger': {getLogger: () => ({debug() {}, warn() {}, error() {}})},
    '../../utils/FormatUtil': {errorText: error => String(error)}
  })(entry+'mta/upstream/service/mta/MtaTransferClient.ets');
  const client = new MtaTransferClient();
  const events = [];
  client.setEventHandlers({
    onWsOpen: () => events.push('open'),
    onWsClosed: () => events.push('close'),
    onError: () => events.push('error')
  });
  const old = client.connect('wss://old', 10);
  const former = new Map(sockets[0].events);
  const cancelled = assert.rejects(old, /已取消/);
  await client.close();
  await cancelled;
  const next = client.connect('wss://new', 10);
  former.get('open')();
  former.get('close')();
  former.get('error')(new Error('stale'));
  assert.deepEqual(events, []);
  sockets[1].events.get('open')();
  await next;
  assert.deepEqual(events, ['open']);
  await assert.rejects(client.acceptRequest(), /写入未完成/);
  await client.close();
});
