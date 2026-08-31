import { describe, it, expect } from '@ohos/hypium';
import { ReceivedRecordingFile, WAV_HEADER_BYTES } from 'common';
import {
  decodeBase64Url,
  encodeBase64Url,
  buildDeviceSignaturePayload,
  normalizeCertificateFingerprint,
  normalizeComputerBaseUrl,
  parseComputerPairingBootstrap
} from '../main/ets/computer/ComputerTransferProtocol';
import {
  COMPUTER_SESSION_MANIFEST_FORMAT,
  prepareComputerSessions
} from '../main/ets/computer/ComputerSessionManifest';

function recording(sourcePath: string, fileName: string, size: number): ReceivedRecordingFile {
  return {
    fileName: fileName,
    path: `/phone/${fileName}`,
    size: size,
    durationMs: 0,
    requestId: 'request',
    sourcePath: sourcePath,
    receivedAt: 1
  };
}

function asciiBytes(value: string): Uint8Array {
  const result = new Uint8Array(value.length);
  for (let index = 0; index < value.length; index += 1) {
    result[index] = value.charCodeAt(index);
  }
  return result;
}

function asciiText(value: Uint8Array): string {
  let result = '';
  for (let index = 0; index < value.length; index += 1) {
    result += String.fromCharCode(value[index]);
  }
  return result;
}

export default function computerTransferProtocolTest() {
  describe('ComputerTransferProtocol', () => {
    it('normalizesSecureAddressFingerprintAndBase64Url', 0, () => {
      expect(normalizeComputerBaseUrl(' https://192.168.1.20:8766/ '))
        .assertEqual('https://192.168.1.20:8766');
      expect(normalizeCertificateFingerprint('aa'.repeat(32)))
        .assertEqual(new Array<string>(32).fill('AA').join(':'));
      const encoded = encodeBase64Url(new Uint8Array([251, 255, 0]));
      expect(encoded).assertEqual('-_8A');
      expect(decodeBase64Url(encoded)[1]).assertEqual(255);
    });

    it('rejectsPlaintextAndAddressesWithPaths', 0, () => {
      expect((): void => {
        normalizeComputerBaseUrl('http://192.168.1.20:8766');
      }).assertThrowError('电脑地址必须是无路径的 HTTPS 地址，例如 https://192.168.1.20:8766');
      expect((): void => {
        normalizeComputerBaseUrl('https://computer.example/path');
      }).assertThrowError('电脑地址必须是无路径的 HTTPS 地址，例如 https://192.168.1.20:8766');
    });

    it('parsesSingleScanPairingBootstrap', 0, () => {
      const receiverId = 'ab'.repeat(32);
      const payload = JSON.stringify({
        protocol: 'ALL_DAY_RECORDING_PAIRING',
        version: 1,
        receiver_id: receiverId,
        addresses: ['https://192.168.1.20:8766'],
        ca_fingerprint: 'AB'.repeat(32),
        ca_pem: '-----BEGIN CERTIFICATE-----\nCA\n-----END CERTIFICATE-----\n',
        pairing_code: 'pairing-code-123456789'
      });
      const uri = `alldayrecording://pair/${encodeBase64Url(
        asciiBytes(payload))}`;
      const bootstrap = parseComputerPairingBootstrap(uri);
      expect(bootstrap.receiver_id).assertEqual(receiverId);
      expect(bootstrap.addresses[0]).assertEqual('https://192.168.1.20:8766');
      expect(bootstrap.pairing_code).assertEqual('pairing-code-123456789');
    });

    it('buildsCanonicalDeviceSignaturePayload', 0, () => {
      const payload = buildDeviceSignaturePayload('challenge_id', 'nonce_value', {
        method: 'PUT',
        path: `/api/v1/uploads/${'a'.repeat(32)}`,
        body_sha256: 'b'.repeat(64),
        upload_offset: 42
      });
      const text = asciiText(payload);
      expect(text).assertEqual(`ALL_DAY_RECORDING_DEVICE_AUTH_V1\nchallenge_id\nnonce_value\nPUT\n` +
        `/api/v1/uploads/${'a'.repeat(32)}\n${'b'.repeat(64)}\n42`);
    });

    it('buildsCanonicalManifestFromReceivedWatchPaths', 0, () => {
      const root = 'pcm_gap_test_1788000000000';
      const sessions = prepareComputerSessions([
        recording(`${root}/segment_000002_first_000000016000.wav`,
          'segment_000002_first_000000016000.wav', WAV_HEADER_BYTES + 32000),
        recording(`${root}/segment_000001_first_000000000000.wav`,
          'segment_000001_first_000000000000.wav', WAV_HEADER_BYTES + 32000),
        recording('手表手动发送', 'received.wav', WAV_HEADER_BYTES + 32000)
      ]);

      expect(sessions.length).assertEqual(1);
      expect(sessions[0].manifest.format).assertEqual(COMPUTER_SESSION_MANIFEST_FORMAT);
      expect(sessions[0].manifest.chunks.length).assertEqual(2);
      expect(sessions[0].manifest.chunks[0].firstSample).assertEqual(0);
      expect(sessions[0].manifest.totalSamples).assertEqual(32000);
      expect(sessions[0].manifest.continuityValid).assertTrue();
      expect(sessions[0].manifestRelativePath()).assertEqual(`${root}/session_summary.json`);
    });
  });
}
