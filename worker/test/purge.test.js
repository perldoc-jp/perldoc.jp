import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { after, describe, it } from 'node:test';

// scripts/purge-cache.sh が Cloudflare の API をどう呼び、応答をどう判定するかを
// 検査する。
//
// PATH の先頭に偽の curl を置き、argv と stdin を記録させ、--output の path へ
// 用意した本文を書かせる。実際の API は呼ばない。ゾーンの purge が内側の
// fetch() キャッシュまで消すことはこの層では証明できず、docs/cloud-run.md §10 の
// 手順で実環境に対して確かめる。
const workerDir = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const script = join(workerDir, 'scripts', 'purge-cache.sh');
const tmpRoots = [];

after(() => {
  for (const dir of tmpRoots) rmSync(dir, { recursive: true, force: true });
});

function makeTmp() {
  const dir = mkdtempSync(join(tmpdir(), 'pjp-purge-'));
  tmpRoots.push(dir);
  return dir;
}

const ZONE_ID = '0123456789abcdef0123456789abcdef';
const TOKEN = 'test-token_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456';
const OK_BODY = JSON.stringify({ success: true, errors: [], messages: [], result: { id: ZONE_ID } });

function fakeCurlDir(recordPath, { body, code, exit }) {
  const dir = makeTmp();
  const recorder = join(dir, 'record.mjs');
  writeFileSync(recorder, [
    "import { appendFileSync, readFileSync, writeFileSync } from 'node:fs';",
    'const argv = process.argv.slice(2);',
    "const stdin = readFileSync(0, 'utf8');",
    `appendFileSync(${JSON.stringify(recordPath)}, JSON.stringify({ argv, stdin }) + '\\n');`,
    "const i = argv.indexOf('--output');",
    `if (i !== -1) writeFileSync(argv[i + 1], ${JSON.stringify(body)});`,
    `process.stdout.write(${JSON.stringify(code)});`,
    `process.exit(${Number(exit)});`,
  ].join('\n'));
  writeFileSync(join(dir, 'curl'), [
    '#!/bin/bash',
    `exec node ${JSON.stringify(recorder)} "$@"`,
  ].join('\n'), { mode: 0o755 });
  return dir;
}

function run({ args = [], env = {}, body = OK_BODY, code = '200', exit = 0 } = {}) {
  const record = join(makeTmp(), 'calls.jsonl');
  const fake = fakeCurlDir(record, { body, code, exit });
  // 呼び出し元の環境にある同名の変数を持ち込まない
  const { CLOUDFLARE_ZONE_ID: _z, CLOUDFLARE_CACHE_PURGE_TOKEN: _t, ...base } = process.env;
  let status = 0;
  let stdout = '';
  let stderr = '';
  try {
    // shebang で実行する (deploy.test.js と同じ理由。macOS の /bin/bash 3.2 と
    // 新しい bash の挙動差をテストが素通ししないようにする)
    stdout = execFileSync(script, args, {
      cwd: tmpdir(),
      env: {
        ...base,
        PATH: `${fake}:${process.env.PATH}`,
        CLOUDFLARE_ZONE_ID: ZONE_ID,
        CLOUDFLARE_CACHE_PURGE_TOKEN: TOKEN,
        ...env,
      },
      stdio: ['ignore', 'pipe', 'pipe'],
      encoding: 'utf8',
    });
  } catch (error) {
    status = error.status ?? 1;
    stdout = String(error.stdout ?? '');
    stderr = String(error.stderr ?? '');
  }
  const calls = existsSync(record)
    ? readFileSync(record, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l))
    : [];
  return { status, stdout, stderr, calls };
}

const valueOf = (argv, flag) => argv[argv.indexOf(flag) + 1];

describe('purge-cache.sh の API 呼び出し', () => {
  it('ゾーンの purge_cache へ purge_everything を 1 回だけ POST する', () => {
    const { status, calls, stderr } = run();
    assert.equal(status, 0, stderr);
    assert.equal(calls.length, 1);
    const { argv } = calls[0];

    assert.equal(
      argv.at(-1),
      `https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/purge_cache`,
    );
    assert.equal(valueOf(argv, '--request'), 'POST');
    assert.deepEqual(JSON.parse(valueOf(argv, '--data')), { purge_everything: true });
    assert.ok(argv.includes('Content-Type: application/json'));
  });

  // argv は同じホストの他プロセスから ps で読める。token は stdin の設定として渡す
  it('token を argv に載せず、stdin の設定で Authorization ヘッダーにする', () => {
    const { calls } = run();
    const { argv, stdin } = calls[0];
    assert.ok(!argv.some((a) => a.includes(TOKEN)), 'token が argv にある');
    assert.equal(valueOf(argv, '--config'), '-');
    assert.equal(stdin, `header = "Authorization: Bearer ${TOKEN}"\n`);
  });

  it('TLS の検証を外すオプションを付けない', () => {
    const { calls } = run();
    const { argv } = calls[0];
    assert.ok(!argv.includes('--insecure') && !argv.includes('-k'));
  });

  it('成功時も token を出力しない', () => {
    const { stdout, stderr } = run();
    assert.ok(!stdout.includes(TOKEN) && !stderr.includes(TOKEN));
  });
});

// 失敗を成功として通すと、内側の 24 時間 TTL のあいだ古い応答が残り続ける。
// 判定は HTTP の status と本文の success の両方で行う
describe('purge-cache.sh が失敗として扱う応答', () => {
  const failures = {
    'HTTP 200 でも success が false': {
      body: JSON.stringify({ success: false, errors: [{ code: 1000, message: 'boom' }] }),
    },
    'HTTP 403 (権限の無い token)': {
      code: '403',
      body: JSON.stringify({ success: false, errors: [{ code: 10000, message: 'Authentication error' }] }),
    },
    'HTTP 429 (レート制限)': {
      code: '429',
      body: JSON.stringify({ success: false, errors: [{ code: 971, message: 'rate limited' }] }),
    },
    'JSON でない本文': { body: '<html>bad gateway</html>', code: '200' },
    '空の本文': { body: '', code: '200' },
    'success が文字列の "true"': { body: JSON.stringify({ success: 'true' }) },
    'curl 自体の失敗': { exit: 28, code: '000', body: '' },
  };
  for (const [label, response] of Object.entries(failures)) {
    it(`${label} は非ゼロで終わり、token を出力しない`, () => {
      const { status, stdout, stderr } = run(response);
      assert.notEqual(status, 0);
      assert.ok(!stdout.includes(TOKEN) && !stderr.includes(TOKEN));
    });
  }

  it('API が返した errors を stderr に出す', () => {
    const { stderr } = run({
      code: '403',
      body: JSON.stringify({ success: false, errors: [{ code: 10000, message: 'Authentication error' }] }),
    });
    assert.match(stderr, /HTTP 403/);
    assert.match(stderr, /Authentication error/);
  });
});

describe('purge-cache.sh が拒否する入力', () => {
  const rejected = {
    'ZONE_ID が無い': { env: { CLOUDFLARE_ZONE_ID: '' } },
    'token が無い': { env: { CLOUDFLARE_CACHE_PURGE_TOKEN: '' } },
    'ZONE_ID が 32 桁の 16 進でない': { env: { CLOUDFLARE_ZONE_ID: 'perldoc.jp' } },
    'ZONE_ID に path を混ぜる': { env: { CLOUDFLARE_ZONE_ID: `${ZONE_ID}/../../user` } },
    // stdin の設定は 1 行 1 オプションなので、改行や引用符が入ると別の
    // オプションを注入できる
    'token に改行がある': { env: { CLOUDFLARE_CACHE_PURGE_TOKEN: 'abc\nurl = "https://evil.example"' } },
    'token に引用符がある': { env: { CLOUDFLARE_CACHE_PURGE_TOKEN: 'abc"def' } },
    '余分な引数': { args: ['--everything'] },
  };
  for (const [label, input] of Object.entries(rejected)) {
    it(`${label} は非ゼロで、curl を呼ばない`, () => {
      const { status, calls } = run(input);
      assert.notEqual(status, 0);
      assert.equal(calls.length, 0);
    });
  }
});
