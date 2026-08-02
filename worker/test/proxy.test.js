import assert from 'node:assert/strict';
import { after, beforeEach, describe, it } from 'node:test';

import worker from '../src/index.js';

const ORIGIN = 'https://perldoc-jp-xxxxxxxxxx.asia-northeast1.run.app';

const realFetch = globalThis.fetch;
after(() => {
  globalThis.fetch = realFetch;
});

// fetch を差し替えて、Worker が実際に叩こうとした URL とヘッダを捕まえる
let calls = [];
beforeEach(() => {
  calls = [];
  globalThis.fetch = (input, init) => {
    const href = input instanceof Request ? input.url : String(input);
    calls.push({ url: new URL(href), init });
    return Promise.resolve(new Response('ok', { status: 200 }));
  };
});

const proxy = (rawUrl, opts = {}) =>
  worker.fetch(new Request(rawUrl, opts), { ORIGIN });

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
