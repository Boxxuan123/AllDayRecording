const ULID_ALPHABET: string = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
let lastOperationTime: number = 0;
let operationSequence: number = 0;

export function newOperationId(): string {
  const current = Date.now();
  operationSequence = current === lastOperationTime ? (operationSequence + 1) % 1024 : 0;
  lastOperationTime = current;
  let time = current;
  let prefix = '';
  for (let index = 0; index < 10; index += 1) {
    prefix = ULID_ALPHABET.charAt(time % 32) + prefix;
    time = Math.floor(time / 32);
  }
  let suffix = '';
  for (let index = 0; index < 14; index += 1) {
    suffix += ULID_ALPHABET.charAt(Math.floor(Math.random() * 32));
  }
  suffix += ULID_ALPHABET.charAt(Math.floor(operationSequence / 32));
  suffix += ULID_ALPHABET.charAt(operationSequence % 32);
  return prefix + suffix;
}
