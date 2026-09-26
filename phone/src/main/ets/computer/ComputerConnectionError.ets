// Stable error boundary. Native error codes come from the installed NetworkKit SDK.
export class ComputerConnectionError extends Error {
  category: string;
  phase: string;
  nativeCode: number = 0;
  statusCode: number = 0;
  serverCode: string = '';
  requestId: string = '';
  path: string = '';
  mayHaveSent: boolean = false;
  original: Object | undefined = undefined;
  constructor(category: string, phase: string, message: string) {
    super(message);
    this.category = category;
    this.phase = phase;
  }
}

interface NativeFailure { code?: number; }

export function connectionFailure(error: Object, path: string, requestId: string): ComputerConnectionError {
  if (error instanceof ComputerConnectionError) { return error; }
  const code = (error as NativeFailure).code ?? 0;
  const unreachable = code === 2300006 || code === 2300007;
  const tls = [2300035, 2300058, 2300059, 2300060, 2300077, 2300083, 2300090, 2300091].indexOf(code) >= 0;
  const category = unreachable ? 'unreachable' : tls ? 'tls' : code === 2300028 ? 'response_timeout' : 'transport';
  const message = unreachable ? '电脑地址不可达' : tls ? '电脑 TLS 证书或安全连接校验失败，请检查已配对电脑' :
    code === 2300028 ? '等待电脑响应超时，请核对本次操作结果' : '电脑连接失败';
  const failure = new ComputerConnectionError(category, unreachable || tls ? 'connect' : 'response',
    `${message}（诊断 ${requestId}，错误码 ${code}）`);
  failure.nativeCode = code;
  failure.path = path;
  failure.requestId = requestId;
  failure.mayHaveSent = !unreachable && !tls;
  failure.original = error;
  return failure;
}

export function mayRediscover(error: Object): boolean {
  // A generic SDK timeout cannot distinguish connect from response timeout.
  // Fail conservatively; an HTTP response, TLS failure or auth failure is final.
  return error instanceof ComputerConnectionError && error.category === 'unreachable';
}

let diagnosticSequence: number = 0;
export function connectionDiagnosticId(): string {
  diagnosticSequence += 1;
  return `sync-${Date.now().toString(36)}-${diagnosticSequence}`;
}
