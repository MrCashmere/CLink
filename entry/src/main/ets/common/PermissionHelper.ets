import { LogCapture as Lg } from '../common/LogCapture';
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';

/** 权限自检结果。 */
export interface PermissionCheckOutcome {
  /** 参与自检的权限总数。 */
  total: number;
  /** 自检结束后仍未授予的权限。 */
  missing: Permissions[];
  /** 是否存在系统已不再弹窗（此前被永久拒绝）的权限。 */
  needManualGrant: boolean;
}

/**
 * 运行时权限申请工具。
 *
 * 规则：
 *  - 逐项申请权限，禁止批量申请（每次 requestPermissionsFromUser 只传一个权限，
 *    保证系统按单个权限弹窗，而非一次性请求多个）。
 *  - 已授予的权限直接跳过，不再重复弹窗。
 *  - Ensure 不阻塞后续流程——无论用户同意与否都正常返回，
 *    由具体功能在真正需要某权限时自行判断可用性。
 */
export class PermissionHelper {
  /** 检查某权限是否已授予。 */
  static granted(context: common.Context, permission: Permissions): boolean {
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const status = atManager.checkAccessTokenSync(context.applicationInfo.accessTokenId, permission);
      return status === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
    } catch (error) {
      Lg.w(`PermissionHelper.check failed(${permission}): ${JSON.stringify(error)}`);
      return false;
    }
  }

  /** 逐项申请未授予的权限；返回是否全部已授予。 */
  static async ensure(context: common.UIAbilityContext, permissions: Permissions[]): Promise<boolean> {
    const atManager = abilityAccessCtrl.createAtManager();
    let allGranted = true;
    for (const permission of permissions) {
      if (PermissionHelper.granted(context, permission)) {
        continue;
      }
      try {
        // 单条请求，满足「禁止批量申请权限」。
        const result = await atManager.requestPermissionsFromUser(context, [permission]);
        const granted = result.authResults.length > 0 && result.authResults[0] === 0;
        Lg.i(`PermissionHelper granted(${permission})=${granted}`);
        if (!granted) {
          allGranted = false;
        }
      } catch (error) {
        Lg.w(`PermissionHelper request failed(${permission}): ${JSON.stringify(error)}`);
        allGranted = false;
      }
    }
    return allGranted;
  }

  /** 仅检查、不弹窗：返回当前仍未授予的权限列表。 */
  static missing(context: common.Context, permissions: Permissions[]): Permissions[] {
    const result: Permissions[] = [];
    for (const permission of permissions) {
      if (!PermissionHelper.granted(context, permission)) {
        result.push(permission);
      }
    }
    return result;
  }

  /**
   * 权限自检：逐项检查，未授予的重新弹窗申请。
   *
   * 用户此前若已永久拒绝，requestPermissionsFromUser 会直接返回拒绝且不再弹窗
   * （dialogShownResults[i] === false）。这种情况下改用 requestPermissionOnSetting
   * 拉起「设置内授权」弹窗，避免按钮点下去毫无反应。
   */
  static async recheck(
    context: common.UIAbilityContext,
    permissions: Permissions[]
  ): Promise<PermissionCheckOutcome> {
    const atManager = abilityAccessCtrl.createAtManager();
    const missing: Permissions[] = [];
    let needManualGrant = false;
    for (const permission of permissions) {
      if (PermissionHelper.granted(context, permission)) {
        continue;
      }
      let dialogShown = true;
      try {
        // 单条请求，满足「禁止批量申请权限」。
        const result = await atManager.requestPermissionsFromUser(context, [permission]);
        if (result.authResults.length > 0 && result.authResults[0] === 0) {
          Lg.i(`PermissionHelper recheck granted(${permission})`);
          continue;
        }
        const shownResults: Array<boolean> | undefined = result.dialogShownResults;
        dialogShown = shownResults === undefined || shownResults.length === 0 || shownResults[0] === true;
      } catch (error) {
        Lg.w(`PermissionHelper recheck request failed(${permission}): ${JSON.stringify(error)}`);
      }
      if (!dialogShown) {
        // 系统已不再弹申请窗：改走设置内授权弹窗，再给用户一次机会。
        needManualGrant = true;
        try {
          const statuses = await atManager.requestPermissionOnSetting(context, [permission]);
          if (statuses.length > 0 && statuses[0] === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
            Lg.i(`PermissionHelper recheck granted on setting(${permission})`);
            continue;
          }
        } catch (error) {
          Lg.w(`PermissionHelper requestPermissionOnSetting failed(${permission}): ${JSON.stringify(error)}`);
        }
      }
      // 以实际授权状态为准复核一次，避免返回值异常时误报未授予。
      if (PermissionHelper.granted(context, permission)) {
        continue;
      }
      missing.push(permission);
    }
    Lg.i(`PermissionHelper recheck done: missing=${missing.length}/${permissions.length}`);
    return { total: permissions.length, missing: missing, needManualGrant: needManualGrant };
  }
}
