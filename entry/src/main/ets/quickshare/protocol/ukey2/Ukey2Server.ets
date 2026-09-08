import { QuickShareHandshakeMessage, QuickShareUkey2State } from './Handshake';
import { QuickShareLogger } from '../../utils/Logger';

export class QuickShareUkey2Server {
  state: QuickShareUkey2State = 'Idle';
  constructor(private readonly logger: QuickShareLogger) {}
  acceptClientInit(payload: Uint8Array): QuickShareHandshakeMessage { this.state = 'ServerInit'; this.logger.log('UKEY2', 'RECV ClientInit'); return { type: 'ServerInit', payload }; }
  acceptClientFinish(): void { this.state = 'Established'; this.logger.log('UKEY2', 'RECV ClientFinish'); }
}
