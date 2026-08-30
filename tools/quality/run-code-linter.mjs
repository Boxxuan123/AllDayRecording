import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { tmpdir } from 'node:os';

const projectRoot = resolve(process.argv[2] || process.cwd());
const sdkRoot = resolveSdkRoot();
const studioHome = resolveStudioHome(sdkRoot);
const codeLinterRoot = join(studioHome, 'plugins', 'codelinter');
const codeLinterEntry = join(codeLinterRoot, 'index.js');
const configPath = join(projectRoot, 'code-linter.json5');
const sdkMetadataPath = join(sdkRoot, 'default', 'hms', 'ets', 'uni-package.json');

requireFile(codeLinterEntry, 'DevEco Code Linter');
requireFile(configPath, 'project Code Linter configuration');
requireFile(sdkMetadataPath, 'HarmonyOS SDK metadata');

const sdkMetadata = JSON.parse(readFileSync(sdkMetadataPath, 'utf8'));
const apiVersion = String(sdkMetadata.apiVersion || '').trim();
const platformVersion = String(sdkMetadata.platformVersion || '').trim();
if (!apiVersion || !platformVersion) {
  fail(`SDK metadata is missing apiVersion/platformVersion: ${sdkMetadataPath}`);
}

// DevEco's command-line parser expects a dotted API version even though the
// SDK metadata stores the same value as a single integer (for example, 26).
const dottedApiVersion = apiVersion.includes('.') ? apiVersion : `${apiVersion}.0.0`;
const logPath = join(tmpdir(), 'alldayrecording-code-linter.log');
const args = [
  codeLinterEntry,
  '--dir', JSON.stringify([projectRoot]),
  '--config', configPath,
  '--project', projectRoot,
  '--workdir', codeLinterRoot,
  '--sdkPath', sdkRoot,
  '--sdkNumberVersion', dottedApiVersion,
  '--sdkStringVersion', platformVersion,
  '--logPath', logPath,
  '--inIde', 'false',
  '--language', 'en'
];
const result = spawnSync(process.execPath, args, {
  cwd: projectRoot,
  encoding: 'utf8',
  maxBuffer: 32 * 1024 * 1024
});

if (result.error) {
  fail(`Code Linter failed to start: ${result.error.message}`);
}

const records = parseRecords(`${result.stdout || ''}\n${result.stderr || ''}`);
const defects = records.flatMap((record) => Array.isArray(record.defects) ? record.defects : []);
const incompleteMessages = records
  .filter((record) => record.messageType === 0 || record.messageType === -1)
  .map((record) => record.content)
  .filter((content) => typeof content === 'string' && content.length > 0);

for (const defect of defects) {
  const filePath = defect._filePath || '<unknown file>';
  const line = defect.reportLine || 0;
  const column = defect.reportColumn || 0;
  const ruleId = defect.ruleId || '<unknown rule>';
  const description = defect.description || 'Code Linter defect';
  process.stderr.write(`${filePath}:${line}:${column} ${ruleId} ${description}\n`);
}
for (const message of [...new Set(incompleteMessages)]) {
  process.stderr.write(`Code Linter: ${message}\n`);
}

if (result.status !== 0 || incompleteMessages.length > 0) {
  fail(`Code Linter did not complete cleanly (exit ${result.status ?? 'unknown'}). See ${logPath}`);
}
if (defects.length > 0) {
  fail(`Code Linter found ${defects.length} defect(s).`);
}

process.stdout.write(`Code Linter: PASS (0 defects, SDK ${platformVersion} / API ${apiVersion})\n`);

function resolveSdkRoot() {
  if (process.env.DEVECO_SDK_HOME) {
    return resolve(process.env.DEVECO_SDK_HOME);
  }
  if (process.env.DEVECO_STUDIO_HOME) {
    return join(resolve(process.env.DEVECO_STUDIO_HOME), 'sdk');
  }
  return '/Applications/DevEco-Studio.app/Contents/sdk';
}

function resolveStudioHome(resolvedSdkRoot) {
  if (process.env.DEVECO_STUDIO_HOME) {
    return resolve(process.env.DEVECO_STUDIO_HOME);
  }
  return dirname(resolvedSdkRoot);
}

function requireFile(filePath, label) {
  if (!existsSync(filePath)) {
    fail(`Cannot find ${label}: ${filePath}`);
  }
}

function parseRecords(output) {
  const records = [];
  for (const line of output.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed.startsWith('{')) {
      continue;
    }
    try {
      records.push(JSON.parse(trimmed));
    } catch {
      // Non-JSON tool chatter is ignored; process status still guards failures.
    }
  }
  return records;
}

function fail(message) {
  process.stderr.write(`${message}\n`);
  process.exit(1);
}
