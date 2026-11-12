import { common } from '@kit.AbilityKit';
import { PermissionHelper } from '../../../common/PermissionHelper';
let mtaPermissionContext: common.UIAbilityContext | undefined = undefined;
export function setMtaPermissionContext(context: common.UIAbilityContext): void { mtaPermissionContext = context; }
export function isBluetoothPermissionGranted(): boolean {
  return mtaPermissionContext !== undefined && PermissionHelper.granted(mtaPermissionContext, 'ohos.permission.ACCESS_BLUETOOTH');
}
export async function requestBluetoothPermission(context: common.Context): Promise<boolean> {
  const result = await PermissionHelper.ensure(context as common.UIAbilityContext, ['ohos.permission.ACCESS_BLUETOOTH']);
  return result;
}
