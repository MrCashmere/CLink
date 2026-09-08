import { QuickShareHandshakeMessage, QuickShareUkey2State } from './Handshake';
import { QuickShareLogger } from '../../utils/Logger';

export class QuickShareUkey2Client {
  state: QuickShareUkey2State = 'Idle';
  constructor(private readonly logger: QuickShareLogger) {}
  createClientInit(payload: Uint8Array): QuickShareHandshakeMessage { this.state = 'ClientInit'; this.logger.log('UKEY2', 'SEND ClientInit'); return { type: 'ClientInit', payload }; }
  acceptServerInit(payload: Uint8Array): QuickShareHandshakeMessage { this.state = 'ClientFinish'; this.logger.log('UKEY2', 'RECV ServerInit'); return { type: 'ClientFinish', payload }; }
  establish(): void { this.state = 'Established'; this.logger.log('UKEY2', 'SESSION Established'); }
}
