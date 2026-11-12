import { describe, it, expect } from '@ohos/hypium';
import { GalleryMediaClassifier } from '../../../main/ets/quickshare/storage/GalleryMediaClassifier';

export default function testsuite(): void {
  describe('ReceiveMediaRouting', (): void => {
    it('usesDeclaredMimeWhenFileHasNoExtension', 0, (): void => {
      const classification = GalleryMediaClassifier.classify('from-peer', 'image/jpeg');
      expect(classification.kind).assertEqual('image');
      expect(classification.extension).assertEqual('jpg');
    });

    it('keepsTextOutOfTheGalleryEvenWithAPhotoExtension', 0, (): void => {
      const classification = GalleryMediaClassifier.classify('notes.jpg', 'text/plain');
      expect(classification.kind).assertEqual('other');
    });
  });
}
