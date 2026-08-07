import assert from 'node:assert/strict';
import { afterEach, beforeEach, describe, it } from 'node:test';

import worker from '../src/index.js';

const ORIGIN = 'https://perldoc-jp-xxxxxxxxxx.asia-northeast1.run.app';

// fetch を差し替えて、Worker が実際に叩こうとした URL とヘッダを捕まえる。
// グローバルを触るので、テストごとに必ず元へ戻す。
// オリジンの応答は originResponse で差し替えられる (レスポンス側の挙動を
// 固定するテストが使う)
let calls = [];
let realFetch;
let originResponse;
beforeEach(() => {
  calls = [];
  originResponse = () => new Response('ok', { status: 200 });
  realFetch = globalThis.fetch;
  globalThis.fetch = (input, init) => {
    const href = input instanceof Request ? input.url : String(input);
    calls.push({ url: new URL(href), init });
    return Promise.resolve(originResponse());
  };
});
afterEach(() => {
  globalThis.fetch = realFetch;
});

const proxy = (rawUrl, opts = {}, env = {}) =>
  worker.fetch(new Request(rawUrl, opts), { ORIGIN, ...env });

describe('転送先 origin の固定', () => {
  it('通常のパスとクエリを ORIGIN に転送する', async () => {
    await proxy('https://perldoc.jp/func/chomp?foo=bar');
    assert.equal(calls.length, 1);
    assert.equal(calls[0].url.href, `${ORIGIN}/func/chomp?foo=bar`);
  });

  // パスが // で始まると protocol-relative URL として解釈され、
  // 転送先ホストが乗っ取られる (オープンプロキシ)
  for (const path of ['//attacker.example/x', '///attacker.example/x', '//attacker.example']) {
    it(`${path} でも転送先は ORIGIN のまま`, async () => {
      await proxy(`https://perldoc.jp${path}`);
      assert.equal(calls.length, 1);
      assert.equal(calls[0].url.origin, ORIGIN);
    });
  }

  it('バックスラッシュ始まりでも転送先は ORIGIN のまま', async () => {
    await proxy('https://perldoc.jp/\\attacker.example/x');
    assert.equal(calls.length, 1);
    assert.equal(calls[0].url.origin, ORIGIN);
  });
});

// ReverseProxy が読む X-Forwarded-* は For / Host / HTTPS / Port / Proto / Server の
// 6 つで、いずれもクライアントが自由に送れる。特に Port は HTTP_HOST に連結されるため
// `443@evil.example` を送ると Location の実ホストが evil.example になる
describe('クライアント由来の X-Forwarded-* の一掃', () => {
  const HOSTILE = {
    'X-Forwarded-For': '127.0.0.1',
    'X-Forwarded-HTTPS': 'OFF',
    'X-Forwarded-Port': '443@evil.example',
    'X-Forwarded-Server': 'evil.example:443',
    'Forwarded': 'host=evil.example;proto=http',
  };

  it('転送しない', async () => {
    await proxy('https://perldoc.jp/func/chomp', { headers: HOSTILE });
    const h = calls[0].init.headers;
    for (const name of Object.keys(HOSTILE)) {
      assert.equal(h.get(name), null, `${name} が転送されない`);
    }
  });

  it('一掃しても通常のリクエストヘッダは残す', async () => {
    await proxy('https://perldoc.jp/', {
      headers: { 'Accept-Language': 'ja', 'User-Agent': 'test-agent', 'Referer': 'https://example.com/' },
    });
    const h = calls[0].init.headers;
    assert.equal(h.get('Accept-Language'), 'ja');
    assert.equal(h.get('User-Agent'), 'test-agent');
    assert.equal(h.get('Referer'), 'https://example.com/');
  });
});

describe('X-Forwarded-Host', () => {
  it('リクエストのホスト名を入れる', async () => {
    await proxy('https://perldoc.jp/');
    assert.equal(calls[0].init.headers.get('X-Forwarded-Host'), 'perldoc.jp');
  });

  it('クライアントが送った値を上書きする', async () => {
    await proxy('https://perldoc.jp/', { headers: { 'X-Forwarded-Host': 'evil.example' } });
    assert.equal(calls[0].init.headers.get('X-Forwarded-Host'), 'perldoc.jp');
  });
});

// Plack::Middleware::ReverseProxy は X-Forwarded-Proto eq 'https' の完全一致でしか
// psgi.url_scheme を https にせず、http のままだと /func/* の正規化リダイレクトが
// http://perldoc.jp/... を返す。クライアント由来の値を残さないことを保証する
describe('X-Forwarded-Proto', () => {
  it('クライアントが送った値を上書きして https に確定させる', async () => {
    await proxy('https://perldoc.jp/', { headers: { 'X-Forwarded-Proto': 'http' } });
    assert.equal(calls[0].init.headers.get('X-Forwarded-Proto'), 'https');
  });
});

// X-Forwarded-Host を付けている目的そのものが、オリジンが返す Location を
// perldoc.jp のまま返すこと。Worker が 3xx を自分で追ってしまうと Location は
// クライアントに届かず、自ゾーン宛の追従は Worker の再呼び出しにもなる
describe('オリジンの 3xx の扱い', () => {
  it("fetch に redirect: 'manual' を渡す", async () => {
    await proxy('https://perldoc.jp/chomp');
    assert.equal(calls[0].init.redirect, 'manual');
  });

  it('status と Location をそのまま返す', async () => {
    originResponse = () =>
      new Response(null, {
        status: 301,
        headers: { Location: 'https://perldoc.jp/func/chomp' },
      });
    const res = await proxy('https://perldoc.jp/chomp');
    assert.equal(res.status, 301);
    assert.equal(res.headers.get('Location'), 'https://perldoc.jp/func/chomp');
  });
});

describe('オリジンの応答の素通し', () => {
  it('本文とヘッダを保つ', async () => {
    originResponse = () =>
      new Response('<html>ok</html>', {
        status: 200,
        headers: { 'Content-Type': 'text/html', 'Cache-Control': 'public, max-age=7200' },
      });
    const res = await proxy('https://perldoc.jp/');
    assert.equal(await res.text(), '<html>ok</html>');
    assert.equal(res.headers.get('Cache-Control'), 'public, max-age=7200');
  });

  it('エラーの status を握りつぶさない', async () => {
    originResponse = () => new Response('not found', { status: 404 });
    const res = await proxy('https://perldoc.jp/no-such-page');
    assert.equal(res.status, 404);
  });
});

// staging (docs/cloud-run.md §9) だけがクロール除けを足す。付け足しのために
// レスポンスを組み直すので、status や他のヘッダを落とさないことを固定する
describe('NOINDEX', () => {
  it('既定では X-Robots-Tag を足さない', async () => {
    const res = await proxy('https://perldoc.jp/');
    assert.equal(res.headers.get('X-Robots-Tag'), null);
  });

  it('X-Robots-Tag を足しつつ status と他のヘッダを保つ', async () => {
    originResponse = () =>
      new Response('body', {
        status: 404,
        headers: { 'Cache-Control': 'public, max-age=7200' },
      });
    const res = await proxy('https://staging.perldoc.jp/', {}, { NOINDEX: '1' });
    assert.equal(res.headers.get('X-Robots-Tag'), 'noindex, nofollow');
    assert.equal(res.status, 404);
    assert.equal(res.headers.get('Cache-Control'), 'public, max-age=7200');
    assert.equal(await res.text(), 'body');
  });

  it('3xx でも Location を保つ', async () => {
    originResponse = () =>
      new Response(null, {
        status: 301,
        headers: { Location: 'https://staging.perldoc.jp/func/chomp' },
      });
    const res = await proxy('https://staging.perldoc.jp/chomp', {}, { NOINDEX: '1' });
    assert.equal(res.status, 301);
    assert.equal(res.headers.get('Location'), 'https://staging.perldoc.jp/func/chomp');
    assert.equal(res.headers.get('X-Robots-Tag'), 'noindex, nofollow');
  });
});
