// Authentication/preparation failed before dispatching the review action.
export class ComputerReviewNotSentError extends Error {
  readonly reviewRequestNotSent: boolean = true;
  constructor(message: string) { super(`审核请求尚未发送：${message}`); }
}
