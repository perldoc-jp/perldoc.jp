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

// 一掃は Cloudflare が付けた実クライアント IP も消すため、Cloudflare 自身が
// 確定させる CF-Connecting-IP から設定し直す。origin の ReverseProxy は
// X-Forwarded-For しか読まない
describe('X-Forwarded-For', () => {
  it('CF-Connecting-IP から設定し直す (クライアント由来の値は使わない)', async () => {
    await proxy('https://perldoc.jp/', {
      headers: { 'CF-Connecting-IP': '203.0.113.7', 'X-Forwarded-For': '10.0.0.1, 127.0.0.1' },
    });
    assert.equal(calls[0].init.headers.get('X-Forwarded-For'), '203.0.113.7');
  });

  it('CF-Connecting-IP が無ければ付けない', async () => {
    await proxy('https://perldoc.jp/', { headers: { 'X-Forwarded-For': '10.0.0.1' } });
    assert.equal(calls[0].init.headers.get('X-Forwarded-For'), null);
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

// staging (docs/cloud-run.md §10) だけがクロール除けを足す。付け足しのために
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

describe('リクエストの転送', () => {
  it('メソッドをそのまま引き継ぐ', async () => {
    await proxy('https://perldoc.jp/', { method: 'HEAD' });
    assert.equal(calls[0].init.method, 'HEAD');
  });

  // アプリに POST ルートが増えたときに、Worker 経由でだけボディが落ちて
  // 壊れることがないようにする
  it('ボディをそのまま引き継ぐ', async () => {
    await proxy('https://perldoc.jp/', { method: 'POST', body: 'hello' });
    assert.equal(calls[0].init.method, 'POST');
    assert.equal(await new Response(calls[0].init.body).text(), 'hello');
  });
});

describe('NOINDEX の判定', () => {
  // --var は常に文字列を渡すので、無効化のつもりで '0' や 'false' を書いた
  // 値を truthy と読むと、本番が丸ごと検索から消える
  for (const value of ['0', 'false', '', 'yes']) {
    it(`NOINDEX=${JSON.stringify(value)} では足さない`, async () => {
      const res = await proxy('https://perldoc.jp/', {}, { NOINDEX: value });
      assert.equal(res.headers.get('X-Robots-Tag'), null);
    });
  }
});

describe('origin 障害時の応答', () => {
  it('fetch が失敗したら 502 を返す', async () => {
    globalThis.fetch = () => Promise.reject(new TypeError('network error'));
    const res = await proxy('https://perldoc.jp/');
    assert.equal(res.status, 502);
  });

  // catch 自身が例外を投げると、利用者には Cloudflare の汎用エラーが出る
  // Object.create(null) は toString を持たないので String() 自体が投げる。
  // ログの整形で二次例外を起こすと 502 を返しきれない
  for (const [name, thrown] of [
    ['null', null],
    ['文字列', 'boom'],
    ['数値', 42],
    ['prototype なしのオブジェクト', Object.create(null)],
  ]) {
    it(`Error でない値 (${name}) が投げられても 502 を返す`, async () => {
      globalThis.fetch = () => Promise.reject(thrown);
      const res = await proxy('https://perldoc.jp/');
      assert.equal(res.status, 502);
    });
  }

  it('ORIGIN が不正なら origin を叩かずに 502 を返す', async () => {
    const res = await proxy('https://perldoc.jp/', {}, { ORIGIN: 'not-a-url' });
    assert.equal(res.status, 502);
    assert.equal(calls.length, 0);
  });

  it('ログの error に run.app のホスト名を残さない', async () => {
    // fetch の例外メッセージに接続先が含まれても、Workers Logs には
    // 実ホスト名 (= 機密 locator) を書かない
    const hostname = new URL(ORIGIN).hostname;
    const logged = [];
    const realError = console.error;
    console.error = (entry) => logged.push(entry);
    let res;
    try {
      globalThis.fetch = () => Promise.reject(new TypeError(`connect failed: ${hostname}`));
      res = await proxy('https://perldoc.jp/');
    } finally {
      console.error = realError;
    }
    assert.equal(res.status, 502);
    assert.equal(logged.length, 1);
    assert.ok(!JSON.stringify(logged[0]).includes(hostname));
    assert.match(logged[0].error, /<origin>/);
  });
});
