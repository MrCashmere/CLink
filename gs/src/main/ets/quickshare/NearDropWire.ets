import { GsBytes } from '../util/GsBytes';
import { ProtoWire } from './ProtoWire';
import { ProtoReader } from './ProtoReader';
import { NearbyCapabilities } from './NearbyCapabilities';

export enum OfflineType { CONNECTION_REQUEST = 1, CONNECTION_RESPONSE = 2, PAYLOAD_TRANSFER = 3, BANDWIDTH_UPGRADE_NEGOTIATION = 4, KEEP_ALIVE = 5, DISCONNECTION = 6, PAIRED_KEY_ENCRYPTION = 7 }
export enum SharingType { INTRODUCTION = 1, RESPONSE = 2, PAIRED_KEY_ENCRYPTION = 3, PAIRED_KEY_RESULT = 4, CANCEL = 6 }
export enum PayloadPacket { DATA = 1, CONTROL = 2, PAYLOAD_ACK = 3 }
export const LAST_CHUNK: number = 1;
export interface PayloadFile {
  name: string;
  size: number;
  payloadId: number;
  mimeType: string;
  // FileMetadata.id (field 6): a uuid for the attachment, unique across all
  // attachments. The official Windows receiver requires it to bind the incoming
  // FILE payload to the file attachment; without it the peer generates an
  // unrelated attachment id and drops the payload as untracked. Optional: the
  // sender may omit it and introduction() generates a unique value.
  attachmentId?: number;
  // FileMetadata.attachment_hash (field 8): a stable identifier for the
  // attachment, used to recognise the same attachment across transfers.
  attachmentHash?: number;
}
export interface OfflineDecoded { type: number; body: Uint8Array; }
export interface PayloadDecoded { id: number; idKey: string; packetType: number; type: number; totalSize: number; name: string; offset: number; flags: number; body: Uint8Array; }
export interface PayloadTransferDecoded { id: number; idKey: string; packetType: number; type: number; totalSize: number; offset: number; flags: number; body: Uint8Array; }
export interface SharingDecoded { type: number; body: Uint8Array; }

export class NearDropWire {
  static offline(type: number, body: Uint8Array): Uint8Array { const field: number = type === 1 ? 2 : type === 2 ? 3 : type === 3 ? 4 : type === 4 ? 5 : type === 5 ? 6 : type === 6 ? 7 : 8; const v1: Uint8Array = ProtoWire.message([ProtoWire.fieldEnum(1, type), ProtoWire.nested(field, body)]); return ProtoWire.message([ProtoWire.fieldEnum(1, 1), ProtoWire.nested(2, v1)]); }
  static parseOffline(frame: Uint8Array): OfflineDecoded { return NearDropWire.parseOfflineRaw(ProtoReader.decodeFrame(frame)); }
  static parseOfflineFrame(frame: Uint8Array): OfflineDecoded { return NearDropWire.parseOfflineRaw(frame); }
  static parseOfflineRaw(raw: Uint8Array): OfflineDecoded {
    const v1: Uint8Array | undefined = ProtoReader.firstBytes(raw, 2);
    if (v1 === undefined || ProtoReader.firstVarint(raw, 1) !== 1) throw new Error('invalid OfflineFrame');
    const type: number = ProtoReader.firstVarint(v1, 1) ?? 0;
    const field: number = type === 1 ? 2 : type === 2 ? 3 : type === 3 ? 4 : type === 4 ? 5 : type === 5 ? 6 : type === 6 ? 7 : 8;
    const body: Uint8Array | undefined = ProtoReader.firstBytes(v1, field);
    if (type <= 0 || body === undefined) throw new Error('missing OfflineFrame body');
    return { type, body };
  }
  static tryParseOfflineFrame(raw: Uint8Array): OfflineDecoded | undefined {
    try {
      if ((ProtoReader.firstVarint(raw, 1) ?? -1) !== 1) return undefined;
      const v1: Uint8Array | undefined = ProtoReader.firstBytes(raw, 2);
      if (v1 === undefined) return undefined;
      const offlineType: number | undefined = ProtoReader.firstVarint(v1, 1);
      if (offlineType === undefined) return undefined;
      const field: number = offlineType === 1 ? 2 : offlineType === 2 ? 3 : offlineType === 3 ? 4 : offlineType === 4 ? 5 : offlineType === 5 ? 6 : offlineType === 6 ? 7 : offlineType === 7 ? 8 : 0;
      if (field === 0) return undefined;
      const body: Uint8Array | undefined = ProtoReader.firstBytes(v1, field);
      if (body === undefined) return undefined;
      // A ConnectionRequest must carry an endpoint_id (field 1, string). Rejecting
      // frames without it keeps this parser from mistaking a Ukey2Message ALERT
      // (whose message_type=1 collides structurally with an OfflineFrame version=1)
      // for a connection request.
      if (offlineType === 1 && ProtoReader.firstBytes(body, 1) === undefined) return undefined;
      return { type: offlineType, body };
    } catch (error) {
      return undefined;
    }
  }
  // Mirrors NearDrop EndpointInfo.serialize(): byte0 = (deviceType.rawValue << 1)
  // with bit4 (0x10) clear to signal a device name follows, then 16 random
  // bytes, then 1-byte UTF-8 name length, then the name bytes.
  // Device type: unknown=0, phone=1, tablet=2, laptop=3.
  static endpointInfo(name: string, random: Uint8Array, deviceType: number = 1): Uint8Array {
    const nameBytes: Uint8Array = GsBytes.encodeText(name);
    const bytes: Uint8Array = new Uint8Array(18 + nameBytes.length);
    // byte0 = version(3)<<5 | visibility(1)<<4 | deviceType(3)<<1 | reserved(1).
    // version must be 1 so the peer's EndpointInfo parser reads a valid device.
    bytes[0] = (1 << 5) | ((deviceType & 0x7) << 1);
    bytes.set(random.length >= 16 ? random.slice(0, 16) : random, 1);
    bytes[17] = nameBytes.length & 0xff;
    bytes.set(nameBytes, 18);
    return bytes;
  }
  // Extract the readable display name from an EndpointInfo blob (NearDrop layout:
  // byte0 device-type bits, bytes 1..16 random, byte17 name length, bytes 18.. name).
  // Android's ConnectionRequest.endpoint_name (field2) is often prefixed with device
  // descriptor bytes that decode to mojibake; endpoint_info carries the clean name.
  static endpointName(info: Uint8Array): string {
    if (info.length <= 18) return '';
    const len: number = info[17] & 0xff;
    if (18 + len > info.length) return '';
    return GsBytes.decodeText(info.slice(18, 18 + len));
  }

  // ConnectionRequestFrame：字段顺序按 proto 升序；`mediums`(5) 是 repeated（非 packed），每个介质一个 varint。
  // 之前这里只声明了 `WIFI_LAN(5)`，官方端因此没有理由给我们 Wi-Fi Direct 通道；现在补上 `WIFI_DIRECT(8)`
  // 与 `medium_metadata`(7)（P2P 角色 + 凭据类型），理由见 docs/WIFI_DIRECT.md §2.4/§2.5。
  static connectionRequest(endpointId: string, endpointName: string, info: Uint8Array, handshake: Uint8Array): Uint8Array {
    const parts: Uint8Array[] = [
      ProtoWire.fieldString(1, endpointId),
      ProtoWire.fieldString(2, endpointName)
    ];
    for (const medium of NearbyCapabilities.UPGRADE_MEDIUMS) {
      parts.push(ProtoWire.fieldEnum(5, medium));
    }
    parts.push(ProtoWire.fieldBytes(6, info));
    parts.push(ProtoWire.nested(7, NearbyCapabilities.mediumMetadata()));
    return NearDropWire.offline(1, ProtoWire.message(parts));
  }
  static connectionResponse(handshake: Uint8Array, accepted: boolean = true): Uint8Array { const status: Uint8Array = ProtoWire.message([ProtoWire.fieldEnum(1, 0)]); return NearDropWire.offline(2, ProtoWire.message([ProtoWire.fieldInt32(1, 0), ProtoWire.fieldBytes(2, handshake), ProtoWire.fieldEnum(3, accepted ? 1 : 2), ProtoWire.nested(4, status), ProtoWire.fieldInt32(9, 15000)])); }
  // Nearby Connections requires BOTH peers to send a CONNECTION_RESPONSE. The
  // client (sender) sends this minimal ACCEPT after it receives the server's,
  // before any encrypted frame (NearDrop PROTOCOL.md: Client->>Server: Connection
  // response). The server advertises OsInfo via connectionResponse(); the client
  // only needs response=ACCEPT.
  static connectionAccept(): Uint8Array { return NearDropWire.offline(2, ProtoWire.message([ProtoWire.fieldEnum(3, 1)])); }
  static keepAlive(ack: boolean, seq: number): Uint8Array { return NearDropWire.offline(5, ProtoWire.message([ProtoWire.fieldBool(1, ack), ProtoWire.fieldInt32(2, seq)])); }
  static disconnection(ack: boolean): Uint8Array { return NearDropWire.offline(6, ProtoWire.message([ProtoWire.fieldBool(1, !ack), ProtoWire.fieldBool(2, ack)])); }
  // Legacy FILE-frame helper kept for compatibility: it now delegates to the
  // official PayloadTransferFrame builder so callers get the same wire bytes.
  static payload(id: number, file: PayloadFile, offset: number, body: Uint8Array, last: boolean): Uint8Array { return NearDropWire.payloadFileData(NearDropWire.payloadFileHeader(id, file), offset, body, last); }
  // A registered FILE payload. Build the payload_header once (the Connections
  // "register payload" step) and reuse it across every streaming frame. Mirrors the
  // official nearby::connections PayloadTransferFrame.PayloadHeader:
  //   id=1, type=2(FILE), total_size=3, is_sensitive=4, file_name=5.
  static payloadFileHeader(id: number, file: PayloadFile, isSensitive: boolean = false): Uint8Array { return ProtoWire.message([ProtoWire.fieldInt64(1, id), ProtoWire.fieldEnum(2, 2), ProtoWire.fieldInt64(3, file.size), ProtoWire.fieldBool(4, isSensitive), ProtoWire.fieldString(5, file.name)]); }
  // One streaming DATA frame for a FILE payload:
  //   OfflineFrame(PAYLOAD_TRANSFER) -> PayloadTransferFrame {
  //     packet_type = DATA(1), payload_header = <registered header>,
  //     payload_chunk = { flags, offset, body } }.
  // `last=true` writes the LAST_CHUNK flag (0x1) and should carry an empty body with
  // offset = total_size (the terminating frame). Every real chunk uses `last=false`.
  static payloadFileData(header: Uint8Array, offset: number, body: Uint8Array, last: boolean = false): Uint8Array { const chunk: Uint8Array = ProtoWire.message([ProtoWire.fieldInt32(1, last ? LAST_CHUNK : 0), ProtoWire.fieldInt64(2, offset), ProtoWire.fieldBytes(3, body)]); return NearDropWire.offline(3, ProtoWire.message([ProtoWire.fieldEnum(1, 1), ProtoWire.nested(2, header), ProtoWire.nested(3, chunk)])); }
  static payloadBytes(id: number, body: Uint8Array): Uint8Array { const header: Uint8Array = ProtoWire.message([ProtoWire.fieldInt64(1, id), ProtoWire.fieldEnum(2, 1), ProtoWire.fieldInt64(3, body.length)]); const chunk: Uint8Array = ProtoWire.message([ProtoWire.fieldInt32(1, LAST_CHUNK), ProtoWire.fieldInt64(2, 0), ProtoWire.fieldBytes(3, body)]); return NearDropWire.offline(3, ProtoWire.message([ProtoWire.fieldEnum(1, 1), ProtoWire.nested(2, header), ProtoWire.nested(3, chunk)])); }
  // The Nearby Connections PayloadTransfer envelope. negotiation/share frames
  // are carried as BYTES payloads exactly as rquickshare/NearDrop send them,
  // split into a full-data packet + a 0-byte LAST_CHUNK packet (see
  // docs/PROTOCOL.md "payload layer"). FILE payloads only send real chunks
  // and set LAST_CHUNK on the final real chunk.
  private static payloadHeader(id: number, totalSize: number): Uint8Array { return ProtoWire.message([ProtoWire.fieldInt64(1, id), ProtoWire.fieldEnum(2, 1), ProtoWire.fieldInt64(3, totalSize), ProtoWire.fieldBool(4, false)]); }
  private static payloadTransferBody(header: Uint8Array, chunk: Uint8Array): Uint8Array { return ProtoWire.message([ProtoWire.fieldEnum(1, 1), ProtoWire.nested(2, header), ProtoWire.nested(3, chunk)]); }
  static payloadTransferEnvelope(sharing: Uint8Array, payloadId: number): Uint8Array { const header: Uint8Array = NearDropWire.payloadHeader(payloadId, sharing.length); const chunk: Uint8Array = ProtoWire.message([ProtoWire.fieldInt32(1, 0), ProtoWire.fieldInt64(2, 0), ProtoWire.fieldBytes(3, sharing)]); return NearDropWire.offline(3, NearDropWire.payloadTransferBody(header, chunk)); }
  static payloadTransferLastChunk(payloadId: number, totalSize: number): Uint8Array { const header: Uint8Array = NearDropWire.payloadHeader(payloadId, totalSize); const chunk: Uint8Array = ProtoWire.message([ProtoWire.fieldInt32(1, 1), ProtoWire.fieldInt64(2, totalSize), ProtoWire.fieldBytes(3, new Uint8Array(0))]); return NearDropWire.offline(3, NearDropWire.payloadTransferBody(header, chunk)); }
  static parsePayloadTransfer(offline: OfflineDecoded): PayloadTransferDecoded { const body: Uint8Array = offline.body; const header: Uint8Array | undefined = ProtoReader.firstBytes(body, 2); const chunk: Uint8Array | undefined = ProtoReader.firstBytes(body, 3); if (header === undefined || chunk === undefined) throw new Error('invalid PayloadTransferFrame'); return { id: ProtoReader.firstVarint(header, 1) ?? 0, idKey: ProtoReader.firstVarintKey(header, 1) ?? '', packetType: ProtoReader.firstVarint(body, 1) ?? 0, type: ProtoReader.firstVarint(header, 2) ?? 0, totalSize: ProtoReader.firstVarint(header, 3) ?? 0, offset: ProtoReader.firstVarint(chunk, 2) ?? 0, flags: ProtoReader.firstVarint(chunk, 1) ?? 0, body: ProtoReader.firstBytes(chunk, 3) ?? new Uint8Array(0) }; }
  // Accepts either the whole OfflineFrame(PAYLOAD_TRANSFER) or the inner
  // payload_transfer message and returns the payload_transfer body.
  private static payloadTransferBodyFrom(raw: Uint8Array): Uint8Array { if (ProtoReader.firstVarint(raw, 1) === 1) { const v1: Uint8Array | undefined = ProtoReader.firstBytes(raw, 2); if (v1 !== undefined) { const body: Uint8Array | undefined = ProtoReader.firstBytes(v1, 4); if (body !== undefined) return body; } } return raw; }
  static parsePayload(raw: Uint8Array): PayloadDecoded { const body: Uint8Array = NearDropWire.payloadTransferBodyFrom(raw); const header: Uint8Array | undefined = ProtoReader.firstBytes(body, 2); const chunk: Uint8Array | undefined = ProtoReader.firstBytes(body, 3); if (header === undefined || chunk === undefined) throw new Error('invalid PayloadTransferFrame'); return { id: ProtoReader.firstVarint(header, 1) ?? 0, idKey: ProtoReader.firstVarintKey(header, 1) ?? '', packetType: ProtoReader.firstVarint(body, 1) ?? 0, type: ProtoReader.firstVarint(header, 2) ?? 0, totalSize: ProtoReader.firstVarint(header, 3) ?? 0, name: GsBytes.decodeText(ProtoReader.firstBytes(header, 5) ?? new Uint8Array(0)), offset: ProtoReader.firstVarint(chunk, 2) ?? 0, flags: ProtoReader.firstVarint(chunk, 1) ?? 0, body: ProtoReader.firstBytes(chunk, 3) ?? new Uint8Array(0) }; }
  static sharing(type: number, body: Uint8Array): Uint8Array { const v1: Uint8Array = ProtoWire.message([ProtoWire.fieldEnum(1, type), ProtoWire.nested(type === 1 ? 2 : type === 2 ? 3 : type === 3 ? 4 : type === 4 ? 5 : 6, body)]); return ProtoWire.message([ProtoWire.fieldEnum(1, 1), ProtoWire.nested(2, v1)]); }
  static parseSharing(raw: Uint8Array): SharingDecoded { const root: Uint8Array = raw; const v1: Uint8Array = ProtoReader.firstBytes(root, 2) ?? new Uint8Array(0); const type: number = ProtoReader.firstVarint(v1, 1) ?? 0; const field: number = type === 1 ? 2 : type === 2 ? 3 : type === 3 ? 4 : type === 4 ? 5 : 6; return { type, body: ProtoReader.firstBytes(v1, field) ?? new Uint8Array(0) }; }
  // A unique positive attachment id: the official Windows receiver keys each
  // incoming FileMetadata by FileMetadata.id (field 6) and uses it to persist the
  // attachment. Windows Quick Share only finalizes attachments with a POSITIVE id;
  // a negative id makes the receiver report RECEIVE_ATTACHMENTS_END with
  // received_bytes=0 / FAILED_ATTACHMENT_TRANSMISSION_STATUS (verified against the
  // Windows nearby_share.log: Android success uses +id, Harmony failure used -id).
  // The FILE payload header id stays negative (payload_id, field 3/header id 1):
  // Android's FILE payload ids are negative too, so the sign of the payload id is
  // not what the receiver cares about.
  static attachmentId(): number { return Math.floor(Math.random() * 9007199254740991) + 1; }
  static attachmentHash(): number { return Math.floor(Math.random() * 9007199254740991) + 1; }
  // Derive a precise mime from the file extension so the introduction carries a
  // type/mime that the official Windows receiver understands (the picker often
  // yields 'application/octet-stream' which maps to DOCUMENT and fails there).
  static mimeForName(name: string): string {
    const n: string = name.toLowerCase();
    if (n.endsWith('.jpg') || n.endsWith('.jpeg')) return 'image/jpeg';
    if (n.endsWith('.png')) return 'image/png';
    if (n.endsWith('.gif')) return 'image/gif';
    if (n.endsWith('.webp')) return 'image/webp';
    if (n.endsWith('.bmp')) return 'image/bmp';
    if (n.endsWith('.mp4')) return 'video/mp4';
    if (n.endsWith('.mkv')) return 'video/x-matroska';
    if (n.endsWith('.mp3')) return 'audio/mpeg';
    if (n.endsWith('.wav')) return 'audio/wav';
    if (n.endsWith('.txt')) return 'text/plain';
    if (n.endsWith('.md')) return 'text/markdown';
    if (n.endsWith('.pdf')) return 'application/pdf';
    if (n.endsWith('.apk')) return 'application/vnd.android.package-archive';
    if (n.endsWith('.zip')) return 'application/zip';
    if (n.endsWith('.json')) return 'application/json';
    return '';
  }
  static introduction(files: PayloadFile[]): Uint8Array { const parts: Uint8Array[] = []; for (const file of files) { const mime: string = NearDropWire.mimeForName(file.name) || file.mimeType; parts.push(ProtoWire.nested(1, ProtoWire.message([ProtoWire.fieldString(1, file.name), ProtoWire.fieldEnum(2, NearDropWire.fileType(file.name, mime)), ProtoWire.fieldInt64(3, file.payloadId), ProtoWire.fieldInt64(4, file.size), ProtoWire.fieldString(5, mime), ProtoWire.fieldInt64(6, file.attachmentId ?? NearDropWire.attachmentId()), ProtoWire.fieldInt64(8, file.attachmentHash ?? NearDropWire.attachmentHash())]))); } parts.push(ProtoWire.fieldBool(6, true), ProtoWire.fieldEnum(8, 1)); return NearDropWire.sharing(1, ProtoWire.message(parts)); }
  static response(accepted: boolean): Uint8Array { return NearDropWire.sharing(2, ProtoWire.message([ProtoWire.fieldEnum(1, accepted ? 1 : 2)])); }
  // NearDrop/rquickshare send a random 72-byte signedData and 6-byte
  // secretIdHash; callers must supply random bytes (GsCrypto.randomBytes).
  // All-zero fallback kept only for callers that omit them.
  static pairedKeyEncryption(signedData?: Uint8Array, secretIdHash?: Uint8Array): Uint8Array { const signed: Uint8Array = signedData === undefined || signedData.length === 0 ? new Uint8Array(72) : signedData; const hash: Uint8Array = secretIdHash === undefined || secretIdHash.length === 0 ? new Uint8Array(6) : secretIdHash; return NearDropWire.sharing(3, ProtoWire.message([ProtoWire.fieldBytes(1, signed), ProtoWire.fieldBytes(2, hash)])); }
  static pairedKeyResult(status: number = 3): Uint8Array { return NearDropWire.sharing(4, ProtoWire.message([ProtoWire.fieldEnum(1, status)])); }
  static cancel(): Uint8Array { return NearDropWire.sharing(6, new Uint8Array(0)); }
  // The official sharing FileMetadata.Type enum has only
  // UNKNOWN=0, IMAGE=1, VIDEO=2, APP=3, AUDIO=4. Return a value in range;
  // the previous `return 5` produced an out-of-range enum that the official
  // Windows/Android receiver treats as an unsupported attachment type and
  // answers the Introduction with status=UNSUPPORTED_ATTACHMENT_TYPE (4).
  // Non-media, non-app files (txt, pdf, docx, zip, octet-stream) -> UNKNOWN(0),
  // matching rquickshare's `mime_guess` mapping (.apk -> APP, else -> Unknown).
  private static fileType(name: string, mime: string): number { if (mime.startsWith('image/')) return 1; if (mime.startsWith('video/')) return 2; if (mime.startsWith('audio/')) return 4; const n: string = name.toLowerCase(); if (n.endsWith('.apk') || n.endsWith('.exe')) return 3; return 0; }
}
