/**
 * MS-CDP Connection / Control message structs (all big-endian), mirroring
 * ShortDev.Microsoft.ConnectedDevices.Messages.Connection / .Control.
 */

import { CdpWriter, CdpReader, CDP_TCP_PORT } from './CdpCodec';
import { ByteUtils } from '../../common/ByteUtils';

/** Implemented by every message body carried inside a CDP frame. */
export interface CdpConnectionBody {
  write(writer: CdpWriter): void;
}

export enum CdpConnectionMode {
  None = 0,
  Proximal = 1,
  Legacy = 2
}

export enum CdpConnectionType {
  ConnectRequest = 0,
  ConnectResponse = 1,
  DeviceAuthRequest = 2,
  DeviceAuthResponse = 3,
  UserDeviceAuthRequest = 4,
  UserDeviceAuthResponse = 5,
  AuthDoneRequest = 6,
  AuthDoneRespone = 7,
  ConnectFailure = 8,
  UpgradeRequest = 9,
  UpgradeResponse = 10,
  UpgradeFinalization = 11,
  UpgradeFinalizationResponse = 12,
  TransportRequest = 13,
  TransportConfirmation = 14,
  UpgradeFailure = 15,
  DeviceInfoMessage = 16,
  DeviceInfoResponseMessage = 17
}

export enum CdpCurveType {
  CT_NIST_P256_KDF_SHA512 = 0
}

export enum CdpConnectionResult {
  Success = 0,
  Pending = 1,
  Failure_Authentication = 2,
  Failure_NotAllowed = 3
}

export enum CdpResult {
  Success = 0,
  Pending = 1,
  Failure_Authentication = 2,
  Failure_NotAllowed = 3,
  Failure_Unknown = 4
}

export enum CdpControlMessageType {
  StartChannelRequest = 0,
  StartChannelResponse = 1,
  StopChannelRequest = 2,
  EnumerateAppsRequest = 3,
  EnumerateAppsReponse = 4,
  EnumerateAppTargetNamesRequest = 5,
  EnumerateAppTargetNamesResponse = 6,
  ChannelAuthorizationRequest = 7,
  ChannelAuthorizationResponse = 8
}

export enum CdpChannelResult {
  Success = 0,
  Failure_NotFound = 1
}

/** ConnectionHeader = ConnectionMode (i16 BE) + MessageType (u8). */
export class CdpConnectionHeader {
  mode: number = CdpConnectionMode.Proximal;
  messageType: number = 0;

  constructor(messageType: number = 0, mode: number = CdpConnectionMode.Proximal) {
    this.messageType = messageType;
    this.mode = mode;
  }

  write(writer: CdpWriter): void {
    writer.writeI16BE(this.mode);
    writer.writeU8(this.messageType);
  }

  static parse(reader: CdpReader): CdpConnectionHeader {
    const mode = reader.readI16BE();
    const messageType = reader.readU8();
    return new CdpConnectionHeader(messageType, mode);
  }
}

/** ConnectionRequest body. */
export class CdpConnectionRequest implements CdpConnectionBody {
  curveType: number = CdpCurveType.CT_NIST_P256_KDF_SHA512;
  hmacSize: number = 32;
  nonceBytes: Uint8Array = new Uint8Array(8);
  messageFragmentSize: number = 16384;
  publicKeyX: Uint8Array = new Uint8Array(0);
  publicKeyY: Uint8Array = new Uint8Array(0);

  write(writer: CdpWriter): void {
    writer.writeU8(this.curveType);
    writer.writeU16BE(this.hmacSize);
    writer.writeBytes(this.nonceBytes);
    writer.writeU32BE(this.messageFragmentSize);
    writer.writeBytesWithLength(this.publicKeyX);
    writer.writeBytesWithLength(this.publicKeyY);
  }

  static parse(reader: CdpReader): CdpConnectionRequest {
    const req = new CdpConnectionRequest();
    req.curveType = reader.readU8();
    req.hmacSize = reader.readU16BE();
    req.nonceBytes = reader.readU64();
    req.messageFragmentSize = reader.readU32BE();
    req.publicKeyX = reader.readBytesWithLength();
    req.publicKeyY = reader.readBytesWithLength();
    return req;
  }
}

/** ConnectionResponse body. */
export class CdpConnectionResponse implements CdpConnectionBody {
  result: number = CdpConnectionResult.Pending;
  hmacSize: number = 32;
  nonceBytes: Uint8Array = new Uint8Array(8);
  messageFragmentSize: number = 16384;
  publicKeyX: Uint8Array = new Uint8Array(0);
  publicKeyY: Uint8Array = new Uint8Array(0);

  write(writer: CdpWriter): void {
    writer.writeU8(this.result);
    writer.writeU16BE(this.hmacSize);
    writer.writeBytes(this.nonceBytes);
    writer.writeU32BE(this.messageFragmentSize);
    writer.writeBytesWithLength(this.publicKeyX);
    writer.writeBytesWithLength(this.publicKeyY);
  }

  static parse(reader: CdpReader): CdpConnectionResponse {
    const res = new CdpConnectionResponse();
    res.result = reader.readU8();
    res.hmacSize = reader.readU16BE();
    res.nonceBytes = reader.readU64();
    res.messageFragmentSize = reader.readU32BE();
    res.publicKeyX = reader.readBytesWithLength();
    res.publicKeyY = reader.readBytesWithLength();
    return res;
  }
}

/** AuthenticationPayload: certificate DER + signed thumbprint (both u16-prefixed). */
export class CdpAuthenticationPayload implements CdpConnectionBody {
  certificate: Uint8Array = new Uint8Array(0);
  signedThumbprint: Uint8Array = new Uint8Array(0);

  write(writer: CdpWriter): void {
    writer.writeBytesWithLength(this.certificate);
    writer.writeBytesWithLength(this.signedThumbprint);
  }

  static parse(reader: CdpReader): CdpAuthenticationPayload {
    const payload = new CdpAuthenticationPayload();
    payload.certificate = reader.readBytesWithLength();
    payload.signedThumbprint = reader.readBytesWithLength();
    return payload;
  }
}

/** ResultPayload: one CdpResult byte. */
export class CdpResultPayload implements CdpConnectionBody {
  result: number = CdpResult.Success;

  constructor(result: number = CdpResult.Success) {
    this.result = result;
  }

  write(writer: CdpWriter): void {
    writer.writeU8(this.result);
  }

  static parse(reader: CdpReader): CdpResultPayload {
    return new CdpResultPayload(reader.readU8());
  }
}

/** HResultPayload: one signed int32 (HRESULT). Used by UpgradeFailure. */
export class CdpHResultPayload implements CdpConnectionBody {
  hresult: number;

  constructor(hresult: number) {
    this.hresult = hresult;
  }

  write(writer: CdpWriter): void {
    writer.writeU32BE(this.hresult >>> 0);
  }

  static parse(reader: CdpReader): CdpHResultPayload {
    return new CdpHResultPayload(reader.readU32BE());
  }
}

/** Empty body used by messages that carry no payload (e.g. UpgradeFinalizationResponse). */
export class CdpEmptyBody implements CdpConnectionBody {
  write(writer: CdpWriter): void {
    // nothing to write
  }
}

/** UpgradeResponse body: one TCP endpoint + empty metadata array. */
export class CdpUpgradeResponsePayload implements CdpConnectionBody {
  readonly hostAddress: string;
  readonly service: string;

  constructor(hostAddress: string, service: string) {
    this.hostAddress = hostAddress;
    this.service = service;
  }

  write(writer: CdpWriter): void {
    writer.writeU16BE(1); // endpoint count
    writer.writeStringWithLength(this.hostAddress);
    writer.writeStringWithLength(this.service);
    writer.writeU16BE(2); // CdpTransportType.Tcp
    // MetaData = [EndpointMetadata.Tcp] (matches the Android reference host).
    writer.writeU16BE(1); // metadata array count
    writer.writeU16BE(2); // EndpointMetadata.Tcp type
    writer.writeU32BE(0); // metadata data length
  }

  static parse(reader: CdpReader): CdpUpgradeResponsePayload {
    reader.readU16BE(); // endpoint count
    const host = reader.readStringWithLength();
    const service = reader.readStringWithLength();
    reader.readU16BE(); // transport type
    reader.readU16BE(); // metadata count
    reader.readU16BE(); // metadata type
    reader.readU32BE(); // metadata data length
    return new CdpUpgradeResponsePayload(host, service);
  }
}

/** UpgradeIdPayload body: 16-byte GUID used by TransportRequest/Confirmation. */
export class CdpUpgradeIdPayload implements CdpConnectionBody {
  readonly upgradeId: Uint8Array;

  constructor(upgradeId: Uint8Array) {
    this.upgradeId = upgradeId;
  }

  write(writer: CdpWriter): void {
    writer.writeBytes(this.upgradeId);
  }

  static parse(reader: CdpReader): CdpUpgradeIdPayload {
    return new CdpUpgradeIdPayload(reader.readBytes(16));
  }
}

/** StartChannelRequest body. */
export class CdpStartChannelRequest implements CdpConnectionBody {
  id: string = '';
  name: string = '';
  reserved1: number = 0;
  reserved2: string = '';

  write(writer: CdpWriter): void {
    writer.writeStringWithLength(this.id);
    writer.writeStringWithLength(this.name);
    writer.writeI16BE(this.reserved1);
    writer.writeStringWithLength(this.reserved2);
  }

  static parse(reader: CdpReader): CdpStartChannelRequest {
    const req = new CdpStartChannelRequest();
    req.id = reader.readStringWithLength();
    req.name = reader.readStringWithLength();
    req.reserved1 = reader.readI16BE();
    req.reserved2 = reader.readStringWithLength();
    return req;
  }
}

/** StartChannelResponse body. */
export class CdpStartChannelResponse implements CdpConnectionBody {
  result: number = CdpChannelResult.Success;
  channelId: number = 0;

  write(writer: CdpWriter): void {
    writer.writeU8(this.result);
    writer.writeU64BE(Math.floor(this.channelId / 0x100000000), this.channelId >>> 0);
  }

  static parse(reader: CdpReader): CdpStartChannelResponse {
    const res = new CdpStartChannelResponse();
    res.result = reader.readU8();
    res.channelId = reader.readU64BE();
    return res;
  }
}

/** DeviceInfoMessage body: a JSON string with u16 length + zero terminator. */
export class CdpDeviceInfoMessage implements CdpConnectionBody {
  deviceInfoJson: string = '';

  write(writer: CdpWriter): void {
    writer.writeStringWithLength(this.deviceInfoJson);
  }

  static parse(reader: CdpReader): CdpDeviceInfoMessage {
    const msg = new CdpDeviceInfoMessage();
    msg.deviceInfoJson = reader.readStringWithLength();
    return msg;
  }
}

/** Build a minimal CdpDeviceInfo JSON for the phone acting as a CDP host. */
export function buildDeviceInfoJson(name: string, deviceIdHex: string, hostAddress: string): string {
  const dedup = ByteUtils.fromHex(deviceIdHex);
  const base64 = ByteUtils.toBase64(dedup);
  const json =
    '{"DeduplicationHint":"' + base64 + '","connectionModes":1,"deviceId":"' + base64 + '",' +
    '"endpoints":[{"endpointType":1,"host":"' + hostAddress + '","service":"' + CDP_TCP_PORT.toString() + '"}],' +
    '"name":"' + name + '","type":8}';
  return json;
}
