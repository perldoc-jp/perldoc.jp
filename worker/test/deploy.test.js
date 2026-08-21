import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, symlinkSync, writeFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { after, describe, it } from 'node:test';

// scripts/deploy.sh が wrangler へ渡す argv を検査する。
//
// PATH の先頭に偽の npm を置き、$PWD・最終 argv・WRANGLER_SEND_METRICS を
// 記録させる。wrapper が足す安全条件 (worker root への cd、絶対 --config、
// --offline --no、ORIGIN の注入、environment selector の正規化) は
// すべてここで固定する。
//
// binding の merge (staging の NOINDEX と CLI の ORIGIN の共存) はこの層では
// 証明できない — 偽 npm は wrangler を起動せず wrangler.jsonc を読まない。
// そちらは実 wrangler の --dry-run で確かめる (docs/cloud-run.md の受け入れ検査)。
const workerDir = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const script = join(workerDir, 'scripts', 'deploy.sh');
const tmpRoots = [];

after(() => {
  for (const dir of tmpRoots) rmSync(dir, { recursive: true, force: true });
});

function makeTmp() {
  const dir = mkdtempSync(join(tmpdir(), 'pjp-deploy-'));
  tmpRoots.push(dir);
  return dir;
}

// PATH の先頭に置く偽 npm。呼び出しごとに 1 行の JSON を追記する
function fakeNpmDir(recordPath) {
  const dir = makeTmp();
  const npm = join(dir, 'npm');
  const recorder = join(dir, 'record.mjs');
  writeFileSync(recorder, [
    "import { appendFileSync } from 'node:fs';",
    `appendFileSync(${JSON.stringify(recordPath)}, JSON.stringify({`,
    '  cwd: process.cwd(),',
    '  argv: process.argv.slice(2),',
    '  metrics: process.env.WRANGLER_SEND_METRICS ?? null,',
    "}) + '\\n');",
  ].join('\n'));
  writeFileSync(npm, [
    '#!/bin/bash',
    `exec node ${JSON.stringify(recorder)} "$@"`,
  ].join('\n'), { mode: 0o755 });
  return dir;
}

function run(args, { origin = 'https://example.run.app', env = {}, cwd = tmpdir() } = {}) {
  const record = join(makeTmp(), 'calls.jsonl');
  const fake = fakeNpmDir(record);
  let status = 0;
  let stderr = '';
  try {
    execFileSync('bash', [script, ...args], {
      cwd,
      env: {
        ...process.env,
        PATH: `${fake}:${process.env.PATH}`,
        ORIGIN: origin,
        ...env,
      },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
  } catch (error) {
    status = error.status ?? 1;
    stderr = String(error.stderr ?? '');
  }
  const calls = existsSync(record)
    ? readFileSync(record, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l))
    : [];
  return { status, stderr, calls };
}

const count = (argv, value) => argv.filter((a) => a === value).length;

describe('deploy.sh の argv', () => {
  for (const [mode, selector] of [['production', '--env='], ['staging', '--env=staging']]) {
    it(`${mode} は wrangler を 1 回だけ正しい argv で呼ぶ`, () => {
      const { status, calls, stderr } = run([mode]);
      assert.equal(status, 0, stderr);
      assert.equal(calls.length, 1);
      const { cwd, argv, metrics } = calls[0];

      // 呼び出し元の cwd から独立して worker root にいる
      assert.equal(cwd, workerDir);
      assert.equal(metrics, 'false', 'WRANGLER_SEND_METRICS が子プロセスへ届く');

      // npm exec --offline --no -- wrangler deploy の並びが崩れていない
      assert.deepEqual(argv.slice(0, 6),
        ['exec', '--offline', '--no', '--', 'wrangler', 'deploy']);

      // --config はちょうど 1 つで、値は絶対 path の wrangler.jsonc
      assert.equal(count(argv, '--config'), 1);
      assert.equal(argv[argv.indexOf('--config') + 1], join(workerDir, 'wrangler.jsonc'));

      // environment selector はちょうど 1 つ
      assert.equal(argv.filter((a) => a.startsWith('--env')).length, 1);
      assert.ok(argv.includes(selector));

      // 検証済みの ORIGIN がちょうど 1 つ
      assert.equal(count(argv, '--var'), 1);
      assert.equal(argv[argv.indexOf('--var') + 1], 'ORIGIN:https://example.run.app');

      // dry-run 形式でなければ付かない
      assert.equal(count(argv, '--dry-run'), 0);
      assert.equal(count(argv, '--outdir'), 0);
    });
  }

  it('CLOUDFLARE_ENV があっても production は --env= に正規化する', () => {
    const { status, calls } = run(['production'], { env: { CLOUDFLARE_ENV: 'staging' } });
    assert.equal(status, 0);
    assert.ok(calls[0].argv.includes('--env='));
    assert.equal(calls[0].argv.filter((a) => a.startsWith('--env')).length, 1);
  });

  it('--dry-run では --dry-run と --outdir がそれぞれ 1 つ', () => {
    const outdir = join(makeTmp(), 'out');
    const { status, calls, stderr } = run(['staging', '--dry-run', outdir]);
    assert.equal(status, 0, stderr);
    const { argv } = calls[0];
    assert.equal(count(argv, '--dry-run'), 1);
    assert.equal(count(argv, '--outdir'), 1);
    assert.equal(argv[argv.indexOf('--outdir') + 1], outdir);
  });
});

describe('deploy.sh が拒否する入力', () => {
  const rejected = {
    'モード無し': [],
    '未知のモード': ['prod'],
    'wrangler のオプション直指定': ['production', '--var', 'ORIGIN:https://x.run.app'],
    '--dry-run に outdir が無い': ['production', '--dry-run'],
    '--dry-run に引数が多い': ['production', '--dry-run', '/tmp/a', '/tmp/b'],
    '余分な引数': ['production', 'staging'],
  };
  for (const [label, args] of Object.entries(rejected)) {
    it(`${label} は非ゼロで、npm を呼ばない`, () => {
      const { status, calls } = run(args);
      assert.notEqual(status, 0);
      assert.equal(calls.length, 0);
    });
  }

  it('不正な ORIGIN では npm を呼ばない', () => {
    const { status, calls } = run(['production'], { origin: 'https://evil.example' });
    assert.notEqual(status, 0);
    assert.equal(calls.length, 0);
  });

  describe('<outdir> の安全条件', () => {
    it('相対 path は拒否する (worker root へ書き込ませない)', () => {
      const { status, calls, stderr } = run(['production', '--dry-run', 'out']);
      assert.notEqual(status, 0);
      assert.match(stderr, /absolute path/);
      assert.equal(calls.length, 0);
    });

    it('既存ディレクトリは拒否する', () => {
      const dir = makeTmp();
      const { status, calls } = run(['production', '--dry-run', dir]);
      assert.notEqual(status, 0);
      assert.equal(calls.length, 0);
    });

    it('既存ファイルは拒否する', () => {
      const file = join(makeTmp(), 'f');
      writeFileSync(file, '');
      const { status, calls } = run(['production', '--dry-run', file]);
      assert.notEqual(status, 0);
      assert.equal(calls.length, 0);
    });

    it('dangling symlink も拒否する (-e だけでは見逃す)', () => {
      const link = join(makeTmp(), 'link');
      symlinkSync(join(tmpdir(), 'pjp-nonexistent-target'), link);
      const { status, calls } = run(['production', '--dry-run', link]);
      assert.notEqual(status, 0);
      assert.equal(calls.length, 0);
    });
  });
});
