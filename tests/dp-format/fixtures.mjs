/** 合成动态图片样本（纯字节构造，用于解析器的可执行验证）。 */

/** 一个最小可用 JPEG：SOI + 一张 1x1 的灰度图 + EOI，pad 到指定长度。 */
export function plainJpeg(size) {
  const head = Buffer.from([
    0xff, 0xd8, // SOI
    0xff, 0xdb, 0x00, 0x43, 0x00, // DQT
    ...new Array(64).fill(0x10),
    0xff, 0xc0, 0x00, 0x0b, 0x08, 0x00, 0x01, 0x00, 0x01, 0x01, 0x01, 0x11, 0x00, // SOF0
    0xff, 0xc4, 0x00, 0x1f, 0x00, // DHT (DC)
    ...new Array(16).fill(0x00), ...new Array(12).fill(0x00),
    0xff, 0xda, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3f, 0x00 // SOS
  ]);
  const filler = Buffer.alloc(Math.max(0, size - head.length - 2), 0x5a);
  return Buffer.concat([head, filler, Buffer.from([0xff, 0xd9])]);
}

/** 把一段 XMP 作为 APP1 段插进 JPEG（放在 SOI 之后）。 */
export function jpegWithXmp(jpeg, xmp) {
  const ns = Buffer.from('http://ns.adobe.com/xap/1.0/\0', 'latin1');
  const payload = Buffer.concat([ns, Buffer.from(xmp, 'latin1')]);
  const app1 = Buffer.concat([
    Buffer.from([0xff, 0xe1]),
    (() => { const b = Buffer.alloc(2); b.writeUInt16BE(payload.length + 2); return b; })(),
    payload
  ]);
  return Buffer.concat([jpeg.subarray(0, 2), app1, jpeg.subarray(2)]);
}

/** Google/OPPO 式 `Container:Directory` XMP。`vendor` 决定是否带 OPPO 自家命名空间。 */
export function containerXmp(items, opts = {}) {
  const vendor = opts.vendor ?? 'oppo';
  const body = items.map((it) => {
    const parts = [`Item:Mime="${it.mime}"`, `Item:Semantic="${it.semantic}"`, `Item:Length="${it.length}"`];
    if (it.padding !== undefined) parts.push(`Item:Padding="${it.padding}"`);
    return `          <rdf:li rdf:parseType="Resource">\n            <Container:Item ${parts.join(' ')}/>\n          </rdf:li>`;
  }).join('\n');
  const vendorNs = vendor === 'oppo'
    ? `        xmlns:OpCamera="http://ns.oplus.com/photos/1.0/camera/"\n`
    : '';
  const vendorFields = vendor === 'oppo'
    ? `\n      OpCamera:MotionPhotoOwner="oplus"\n      OpCamera:VideoLength="1"`
    : '';
  return `<?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/">
  <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
    <rdf:Description rdf:about=""
        xmlns:GCamera="http://ns.google.com/photos/1.0/camera/"
${vendorNs}        xmlns:Container="http://ns.google.com/photos/1.0/container/"
        xmlns:Item="http://ns.google.com/photos/1.0/container/item/"
      GCamera:MotionPhoto="1"
      GCamera:MotionPhotoVersion="1"${vendorFields}>
      <Container:Directory>
        <rdf:Seq>
${body}
        </rdf:Seq>
      </Container:Directory>
    </rdf:Description>
  </rdf:RDF>
</x:xmpmeta>`;
}

/** 旧版 Google MicroVideo 的 XMP（MicroVideoOffset = 视频长度，从文件末尾倒数）。 */
export function microVideoXmp(videoLength) {
  return `<?xpacket begin=""?><x:xmpmeta xmlns:x="adobe:ns:meta/">
  <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
    <rdf:Description rdf:about=""
        xmlns:GCamera="http://ns.google.com/photos/1.0/camera/"
      GCamera:MicroVideo="1"
      GCamera:MicroVideoOffset="${videoLength}"/>
  </rdf:RDF>
</x:xmpmeta>`;
}

/** 最小 MP4：ftyp + moov(mvhd) + free + mdat，pad 到指定长度。 */
export function mp4(size) {
  const ftyp = Buffer.concat([
    (() => { const b = Buffer.alloc(4); b.writeUInt32BE(24); return b; })(),
    Buffer.from('ftypmp42', 'latin1'),
    Buffer.from([0, 0, 0, 0]),
    Buffer.from('isommp42', 'latin1')
  ]);
  const mvhdBody = Buffer.alloc(100);
  const moov = Buffer.concat([
    (() => { const b = Buffer.alloc(4); b.writeUInt32BE(8 + 8 + mvhdBody.length); return b; })(),
    Buffer.from('moov', 'latin1'),
    (() => { const b = Buffer.alloc(4); b.writeUInt32BE(8 + mvhdBody.length); return b; })(),
    Buffer.from('mvhd', 'latin1'),
    mvhdBody
  ]);
  const prefix = Buffer.concat([ftyp, moov]);
  const mdatSize = Math.max(16, size - prefix.length);
  const mdat = Buffer.concat([
    (() => { const b = Buffer.alloc(4); b.writeUInt32BE(mdatSize); return b; })(),
    Buffer.from('mdat', 'latin1'),
    Buffer.alloc(mdatSize - 8, 0x11)
  ]);
  return Buffer.concat([prefix, mdat]);
}

/**
 * 带 `stco` 分片偏移的 QuickTime MOV：ftyp(qt) + moov{mvhd, trak/mdia/minf/stbl/stco} + mdat。
 *
 * `moov` 排在 `mdat` 之前 —— 这正是「往 moov 里插字节后必须平移分片偏移」的场景，
 * 用于验证 LivePhotoWriter 注入 Apple 元数据时没有把视频写坏。
 * 返回 { bytes, stcoEntryOffset, stcoValue, mdatPayloadOffset }，方便用例断言偏移被平移了多少。
 */
export function movWithChunks(mdatPayloadSize = 4096) {
  const u32 = (v) => { const b = Buffer.alloc(4); b.writeUInt32BE(v >>> 0); return b; };
  const box = (type, body) => Buffer.concat([u32(8 + body.length), Buffer.from(type, 'latin1'), body]);

  const stcoBody = Buffer.concat([u32(0), u32(1), u32(0)]); // version/flags + count + 占位偏移
  const stbl = box('stbl', box('stco', stcoBody));
  const minf = box('minf', stbl);
  const mdia = box('mdia', minf);
  const trak = box('trak', mdia);
  const mvhd = box('mvhd', Buffer.alloc(100));
  const moov = box('moov', Buffer.concat([mvhd, trak]));

  const ftyp = (() => {
    const body = Buffer.concat([Buffer.from('qt  ', 'latin1'), u32(512), Buffer.from('qt  ', 'latin1')]);
    return box('ftyp', body);
  })();

  const mdat = box('mdat', Buffer.alloc(mdatPayloadSize, 0x22));
  const bytes = Buffer.concat([ftyp, moov, mdat]);

  // 用查找定位（而不是手算嵌套长度），避免用例本身算错结构长度。
  const stcoValueOffset = bytes.indexOf(Buffer.from('stco', 'latin1')) + 4 + 4 + 4;
  const mdatPayloadOffset = bytes.indexOf(Buffer.from('mdat', 'latin1')) + 4;
  bytes.writeUInt32BE(mdatPayloadOffset, stcoValueOffset);
  return { bytes, stcoValueOffset, stcoValue: mdatPayloadOffset, mdatPayloadOffset };
}

/** 三星式：JPEG + MP4 + SEFH…SEFT trailer。 */export function samsungJpeg(primary, video) {
  const body = Buffer.from('SEFH\x00\x00\x00\x00some-samsung-trailer-bytes', 'latin1');
  const footer = Buffer.from('SEFT', 'latin1');
  const trailerLength = body.length + footer.length + 4;
  const lenBuf = Buffer.alloc(4);
  lenBuf.writeUInt32BE(trailerLength);
  return Buffer.concat([primary, video, body, footer, lenBuf]);
}

/** 最小 livp（ZIP：存储方式，含一张 JPEG 与一段 MP4）。 */
export function livpZip(jpeg, videoBytes) {
  const entries = [
    { name: 'image.jpg', data: jpeg },
    { name: 'video.mp4', data: videoBytes }
  ];
  const locals = [];
  const centrals = [];
  let offset = 0;
  for (const entry of entries) {
    const nameBuf = Buffer.from(entry.name, 'latin1');
    const crc = 0;
    const local = Buffer.concat([
      Buffer.from([0x50, 0x4b, 0x03, 0x04]),
      Buffer.from([20, 0, 0, 0, 0, 0]), // version/flags/method/time/date
      (() => { const b = Buffer.alloc(4); b.writeUInt32LE(crc); return b; })(),
      (() => { const b = Buffer.alloc(4); b.writeUInt32LE(entry.data.length); return b; })(),
      (() => { const b = Buffer.alloc(4); b.writeUInt32LE(entry.data.length); return b; })(),
      (() => { const b = Buffer.alloc(2); b.writeUInt16LE(nameBuf.length); return b; })(),
      Buffer.from([0, 0]),
      nameBuf,
      entry.data
    ]);
    locals.push(local);
    const central = Buffer.concat([
      Buffer.from([0x50, 0x4b, 0x01, 0x02]),
      Buffer.from([20, 0, 20, 0, 0, 0, 0, 0]), // version made by / needed / flags / method / time / date
      (() => { const b = Buffer.alloc(4); b.writeUInt32LE(crc); return b; })(),
      (() => { const b = Buffer.alloc(4); b.writeUInt32LE(entry.data.length); return b; })(),
      (() => { const b = Buffer.alloc(4); b.writeUInt32LE(entry.data.length); return b; })(),
      (() => { const b = Buffer.alloc(2); b.writeUInt16LE(nameBuf.length); return b; })(),
      Buffer.from([0, 0, 0, 0, 0, 0, 0, 0]), // extra/comment/disk/attr
      (() => { const b = Buffer.alloc(4); b.writeUInt32LE(offset); return b; })(),
      nameBuf
    ]);
    centrals.push(central);
    offset += local.length;
  }
  const centralBuf = Buffer.concat(centrals);
  const eocd = Buffer.concat([
    Buffer.from([0x50, 0x4b, 0x05, 0x06]),
    Buffer.from([0, 0, 0, 0]),
    (() => { const b = Buffer.alloc(2); b.writeUInt16LE(entries.length); return b; })(),
    (() => { const b = Buffer.alloc(2); b.writeUInt16LE(entries.length); return b; })(),
    (() => { const b = Buffer.alloc(4); b.writeUInt32LE(centralBuf.length); return b; })(),
    (() => { const b = Buffer.alloc(4); b.writeUInt32LE(offset); return b; })(),
    Buffer.from([0, 0])
  ]);
  return Buffer.concat([...locals, centralBuf, eocd]);
}
