class Utf8TextEncoderMock {
  encodeInto(value: string): Uint8Array {
    const bytes: Array<number> = [];
    for (let index = 0; index < value.length; index += 1) {
      let codePoint = value.charCodeAt(index);
      if (codePoint >= 0xd800 && codePoint <= 0xdbff && index + 1 < value.length) {
        const low = value.charCodeAt(index + 1);
        if (low >= 0xdc00 && low <= 0xdfff) {
          codePoint = 0x10000 + ((codePoint - 0xd800) << 10) + (low - 0xdc00);
          index += 1;
        }
      }
      if (codePoint <= 0x7f) {
        bytes.push(codePoint);
      } else if (codePoint <= 0x7ff) {
        bytes.push(0xc0 | (codePoint >>> 6));
        bytes.push(0x80 | (codePoint & 0x3f));
      } else if (codePoint <= 0xffff) {
        bytes.push(0xe0 | (codePoint >>> 12));
        bytes.push(0x80 | ((codePoint >>> 6) & 0x3f));
        bytes.push(0x80 | (codePoint & 0x3f));
      } else {
        bytes.push(0xf0 | (codePoint >>> 18));
        bytes.push(0x80 | ((codePoint >>> 12) & 0x3f));
        bytes.push(0x80 | ((codePoint >>> 6) & 0x3f));
        bytes.push(0x80 | (codePoint & 0x3f));
      }
    }
    return new Uint8Array(bytes);
  }
}

class Utf8TextDecoderMock {
  decodeToString(content: Uint8Array): string {
    let result = '';
    let index = 0;
    while (index < content.length) {
      const first = content[index];
      let codePoint = first;
      let length = 1;
      if ((first & 0xe0) === 0xc0 && index + 1 < content.length) {
        codePoint = ((first & 0x1f) << 6) | (content[index + 1] & 0x3f);
        length = 2;
      } else if ((first & 0xf0) === 0xe0 && index + 2 < content.length) {
        codePoint = ((first & 0x0f) << 12) | ((content[index + 1] & 0x3f) << 6) |
          (content[index + 2] & 0x3f);
        length = 3;
      } else if ((first & 0xf8) === 0xf0 && index + 3 < content.length) {
        codePoint = ((first & 0x07) << 18) | ((content[index + 1] & 0x3f) << 12) |
          ((content[index + 2] & 0x3f) << 6) | (content[index + 3] & 0x3f);
        length = 4;
      }
      if (codePoint <= 0xffff) {
        result += String.fromCharCode(codePoint);
      } else {
        const adjusted = codePoint - 0x10000;
        result += String.fromCharCode(0xd800 + (adjusted >>> 10));
        result += String.fromCharCode(0xdc00 + (adjusted & 0x3ff));
      }
      index += length;
    }
    return result;
  }
}

class Utf8TextEncoderFactoryMock {
  create(charset: string): Utf8TextEncoderMock {
    return new Utf8TextEncoderMock();
  }
}

class Utf8TextDecoderFactoryMock {
  create(charset: string): Utf8TextDecoderMock {
    return new Utf8TextDecoderMock();
  }
}

class UtilMock {
  TextEncoder: Utf8TextEncoderFactoryMock = new Utf8TextEncoderFactoryMock();
  TextDecoder: Utf8TextDecoderFactoryMock = new Utf8TextDecoderFactoryMock();
}

export const util: UtilMock = new UtilMock();
export default util;
