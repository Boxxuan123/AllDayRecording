// Authentication/preparation failed before dispatching the review action.
export class ComputerReviewNotSentError extends Error {
  readonly reviewRequestNotSent: boolean = true;
  original: Object | undefined;
  constructor(message: string, original?: Object) { super(`审核请求尚未发送：${message}`); this.original=original; }
}
