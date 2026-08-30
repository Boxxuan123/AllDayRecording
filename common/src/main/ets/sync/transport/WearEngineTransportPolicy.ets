export const P2P_REMOTE_APP_NOT_INSTALLED: number = 200;
export const P2P_REMOTE_APP_NOT_RUNNING: number = 201;
export const P2P_REMOTE_APP_RUNNING: number = 202;
export const P2P_COMMUNICATION_FAILURE: number = 206;
export const P2P_COMMUNICATION_SUCCESS: number = 207;

interface WearEngineCodedError {
  code?: number;
  message?: string;
}

export function p2pResultMessage(code: number | undefined): string {
  switch (code) {
    case P2P_REMOTE_APP_NOT_INSTALLED:
      return '对端尚未安装本应用';
    case P2P_REMOTE_APP_NOT_RUNNING:
      return '请先打开对端应用';
    case P2P_COMMUNICATION_FAILURE:
      return 'Wear Engine 通信失败，请检查华为运动健康中的设备连接';
    default:
      return `Wear Engine 返回错误码 ${code}`;
  }
}

export function isP2pCommunicationError(error: Object): boolean {
  const codedError = error as WearEngineCodedError;
  if (codedError.code === 1008500002 || codedError.code === 1008500003) {
    return true;
  }
  const message = error instanceof Error ? error.message : '';
  return message.includes('Wear Engine 通信失败') || message.includes('当前未连接') ||
    message.includes('未找到已连接的对端设备');
}

export function isP2pCommunicationFailureResult(error: Object): boolean {
  const codedError = error as WearEngineCodedError;
  if (codedError.code === P2P_COMMUNICATION_FAILURE) {
    return true;
  }
  const message = error instanceof Error ? error.message : '';
  return message === p2pResultMessage(P2P_COMMUNICATION_FAILURE);
}

export function shouldRetryP2pFileTransfer(error: Object, attempt: number, maximumAttempts: number): boolean {
  return attempt < maximumAttempts && isP2pCommunicationError(error) &&
    !isP2pCommunicationFailureResult(error);
}

export function shouldRetryReceiverConnection(error: Object): boolean {
  const codedError = error as WearEngineCodedError;
  if (codedError.code === 1008500004 || codedError.code === 1008500005 ||
    codedError.code === 1008500006 || codedError.code === 1008500008) {
    return false;
  }
  const message = error instanceof Error ? error.message : '';
  return message !== '当前设备不支持 Wear Engine' && message !== 'Wear Engine 接收器启动已取消';
}

export function wearEngineErrorMessage(error: Object): string {
  const codedError = error as WearEngineCodedError;
  switch (codedError.code) {
    case 1008500002:
      return '没有已绑定的穿戴设备';
    case 1008500003:
      return '手机与手表当前未连接';
    case 1008500004:
      return '应用尚未在华为开发者联盟申请 Wear Engine 服务';
    case 1008500005:
      return '华为账号尚未授权本应用使用 Wear Engine';
    case 1008500006:
      return '请先同意 Wear Engine 隐私声明';
    case 1008500008:
      return '设备尚未登录华为账号';
    case 1008509999:
      return 'Wear Engine 权限校验失败，请确认设备基础信息与 P2P 通信能力已审批生效';
    default:
      if (codedError.code !== undefined) {
        return `${codedError.message || 'Wear Engine 调用失败'}（错误码 ${codedError.code}）`;
      }
      return error instanceof Error ? error.message : '未知错误';
  }
}
