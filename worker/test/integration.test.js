// 実際の workerd と wrangler.jsonc の組で Worker を動かす統合テスト。
//
// proxy.test.js は fetch を差し替えてハンドラを直接呼ぶので速い代わりに、
// 設定ファイルの読み取りとランタイムの起動は通らない。compatibility_date が
// 同梱の workerd で扱えない値になっていても Node のテストは通ってしまった
// 実績があるので、実ランタイムでの起動も常時回す。
//
// 検証はランタイムと設定の配線に絞る。外向きの fetch は harness が Node 側へ
// 中継したうえで MSW が横取りするが、その経路ではリクエストヘッダが
// 中継されず、ネットワークエラーも 500 応答に化ける。ヘッダの組み立てと
// origin 障害時の 502 は proxy.test.js が Workers の意味論のまま検証している。
import assert from 'node:assert/strict';
import { after, afterEach, before, describe, it } from 'node:test';

import { setupServer } from 'msw/node';
import { http, HttpResponse } from 'msw';
import { createTestHarness } from 'wrangler';

// 厳格な ORIGIN の検証 (src/origin.js) を通す必要があるので、stub も
// run.app のホスト名にする
const ORIGIN = 'https://perldoc-jp-stub.asia-northeast1.run.app';

const network = setupServer(
  http.get(`${ORIGIN}/*`, () => HttpResponse.text('origin body')),
);

const configPath = new URL('../wrangler.jsonc', import.meta.url);
const production = createTestHarness({
  workers: [{ configPath, vars: { ORIGIN } }],
});
// staging は NOINDEX を上書きせず、wrangler.jsonc の env.staging から
// 読ませる (設定側の配線が抜けていないかを見る)
const staging = createTestHarness({
  workers: [{ configPath, env: 'staging', vars: { ORIGIN } }],
});

before(async () => {
  network.listen({ onUnhandledRequest: 'error' });
  await production.listen();
  await staging.listen();
});
// テストごとに、差し替えたハンドラと Worker 側の状態を戻す
afterEach(async () => {
  network.resetHandlers();
  await production.reset();
  await staging.reset();
});
after(async () => {
  network.close();
  await production.close();
  await staging.close();
});

describe('実 workerd 上の Worker', () => {
  it('本番の設定で起動して origin の応答を返す', async () => {
    const res = await production.fetch('https://perldoc.jp/func/chomp');
    assert.equal(res.status, 200);
    assert.equal(await res.text(), 'origin body');
    // 外側 (Workers Cache) を制御するヘッダーが bundle 後の実ランタイムでも
    // 付くこと。エッジでの消費と HIT/MISS はローカルで観測できないため、
    // ヘッダーの存在だけをここで見る
    assert.equal(res.headers.get('Cloudflare-CDN-Cache-Control'), 'max-age=3600');
  });

  it('本番の設定では X-Robots-Tag を足さない', async () => {
    const res = await production.fetch('https://perldoc.jp/');
    assert.equal(res.headers.get('X-Robots-Tag'), null);
  });

  // --var での手渡しではなく wrangler.jsonc の env.staging.vars を読ませる。
  // 設定側の配線が抜けると staging が検索結果に出る
  it('staging の設定は NOINDEX を設定ファイルから読む', async () => {
    const res = await staging.fetch('https://staging.perldoc.jp/');
    assert.equal(res.status, 200);
    assert.equal(res.headers.get('X-Robots-Tag'), 'noindex, nofollow');
  });

  // diff の分類・正規化 (src/index.js の classifyDiffRequest) が bundle 後の
  // 実ランタイムでも効いていること。cf オプションと MISS→HIT はローカルで
  // 観測できないため、URL の再構築と 400 の遮断だけをここで見る
  it('diff は正規化した target だけを上流 URL に載せる', async () => {
    const captured = [];
    network.use(
      http.get(`${ORIGIN}/*`, ({ request }) => {
        captured.push(request.url);
        return HttpResponse.text('diff body');
      }),
    );
    const res = await production.fetch(
      'https://perldoc.jp/docs/perl/5.42.0/perlfunc.pod/diff?nonce=1&target=perl%2f5.10.1%2fperlfunc.pod',
    );
    assert.equal(res.status, 200);
    assert.deepEqual(captured, [
      `${ORIGIN}/docs/perl/5.42.0/perlfunc.pod/diff?target=perl%2F5.10.1%2Fperlfunc.pod`,
    ]);
  });

  it('重複 target は 400 で、origin に届かない', async () => {
    const captured = [];
    network.use(
      http.get(`${ORIGIN}/*`, ({ request }) => {
        captured.push(request.url);
        return HttpResponse.text('diff body');
      }),
    );
    const res = await production.fetch(
      'https://perldoc.jp/docs/perl/5.42.0/perlfunc.pod/diff?target=a&target=b',
    );
    assert.equal(res.status, 400);
    assert.deepEqual(captured, []);
  });

  it('%2F 入りの diff 形パスは 400 で、origin に届かない', async () => {
    const captured = [];
    network.use(
      http.get(`${ORIGIN}/*`, ({ request }) => {
        captured.push(request.url);
        return HttpResponse.text('diff body');
      }),
    );
    const res = await production.fetch(
      'https://perldoc.jp/docs/perl%2F5.42.0/perlfunc.pod/diff?target=perl%2F5.10.1%2Fperlfunc.pod',
    );
    assert.equal(res.status, 400);
    assert.deepEqual(captured, []);
  });

  // ORIGIN の検証が実ランタイムでも効いていること (設定ミスのまま
  // デプロイされた場合に、origin を叩かず 502 で止まる)
  it('不正な ORIGIN では 502 を返す', async () => {
    const harness = createTestHarness({
      workers: [{ configPath, vars: { ORIGIN: 'not-a-url' } }],
    });
    try {
      await harness.listen();
      const res = await harness.fetch('https://perldoc.jp/');
      assert.equal(res.status, 502);
    } finally {
      await harness.close();
    }
  });
});
