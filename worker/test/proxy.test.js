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

// 全パスの GET/HEAD の status 200 は Cloudflare エッジで 2 時間キャッシュする
// (docs/cloud-run.md)。cf はサブリクエスト単位の設定で、200 以外は負数 = 保存しない
const EDGE_CACHE = {
  cacheEverything: true,
  cacheTtlByStatus: { '200': 7200, '201-599': -1 },
};

const DIFF = '/docs/perl/5.42.0/perlfunc.pod/diff';
const TARGET = 'perl%2F5.10.1%2Fperlfunc.pod';
const CANONICAL_DIFF = `${ORIGIN}${DIFF}?target=perl%2F5.10.1%2Fperlfunc.pod`;

describe('全パス共通のエッジキャッシュ設定', () => {
  for (const path of [
    '/',
    '/about',
    '/docs/perl/5.42.0/perlfunc.pod',
    '/static/css/style.css',
    `${DIFF}?target=${TARGET}`,
  ]) {
    it(`GET ${path} に共通の cf 設定が付く`, async () => {
      await proxy(`https://perldoc.jp${path}`);
      assert.deepEqual(calls[0].init.cf, EDGE_CACHE);
    });
  }

  it('HEAD にも同じ cf 設定が付き、メソッドは HEAD のまま', async () => {
    await proxy('https://perldoc.jp/about', { method: 'HEAD' });
    assert.deepEqual(calls[0].init.cf, EDGE_CACHE);
    assert.equal(calls[0].init.method, 'HEAD');
  });

  // cf のキャッシュ設定は GET/HEAD にしか効かないが、コード上も付けない。
  // 将来 POST ルートが増えたときに「POST もキャッシュ対象」と誤読させない
  it('POST には cf を付けず、ボディを透過する', async () => {
    await proxy('https://perldoc.jp/', { method: 'POST', body: 'hello' });
    assert.equal(calls[0].init.cf, undefined);
    assert.equal(await new Response(calls[0].init.body).text(), 'hello');
  });

  // 2 時間はエッジ TTL であり、ブラウザーへ新しい TTL を公開しない
  it('レスポンスへ Cache-Control を追加しない', async () => {
    const res = await proxy('https://perldoc.jp/');
    assert.equal(res.headers.get('Cache-Control'), null);
  });

  it('静的ファイルの既存 Cache-Control はそのまま返す', async () => {
    originResponse = () =>
      new Response('css', {
        status: 200,
        headers: { 'Cache-Control': 'public, max-age=14400' },
      });
    const res = await proxy('https://perldoc.jp/static/css/style.css');
    assert.equal(res.headers.get('Cache-Control'), 'public, max-age=14400');
  });
});

// Cloudflare の既定キャッシュキーは URL のほかに Origin と method override /
// forwarding 系ヘッダーを含み、値を変えるだけで同じ URL を別キーへ分割して
// MISS を強制できる。Cache-Control / Pragma は上流サブリクエストへの再検証指示、
// Cookie / Authorization は BYPASS の誘発と認証状態の共有キャッシュへの
// 持ち込みになる。公開・非個人化のレスポンスしか無いため、キャッシュ対象の
// GET/HEAD では上流に渡さない
describe('キャッシュ対象メソッドのヘッダー境界', () => {
  const CACHE_BUSTING = {
    'Origin': 'https://attacker.example',
    'X-HTTP-Method-Override': 'PURGE',
    'X-HTTP-Method': 'PURGE',
    'X-Method-Override': 'PURGE',
    'X-Host': 'evil.example',
    'X-Original-URL': '/evil',
    'X-Rewrite-URL': '/evil',
    'Cache-Control': 'no-cache',
    'Pragma': 'no-cache',
    'Authorization': 'Bearer cache-bust',
    'Cookie': 'cache-bust=1',
  };

  for (const method of ['GET', 'HEAD']) {
    it(`${method} では上流に残らない`, async () => {
      await proxy(`https://perldoc.jp${DIFF}?target=${TARGET}`, { method, headers: CACHE_BUSTING });
      const h = calls[0].init.headers;
      for (const name of Object.keys(CACHE_BUSTING)) {
        assert.equal(h.get(name), null, `${name} が上流に残らない`);
      }
    });
  }

  it('削除しても User-Agent / Accept-Language / Referer は残す', async () => {
    await proxy(`https://perldoc.jp${DIFF}?target=${TARGET}`, {
      headers: { 'Accept-Language': 'ja', 'User-Agent': 'test-agent', 'Referer': 'https://example.com/' },
    });
    const h = calls[0].init.headers;
    assert.equal(h.get('Accept-Language'), 'ja');
    assert.equal(h.get('User-Agent'), 'test-agent');
    assert.equal(h.get('Referer'), 'https://example.com/');
  });

  // 非キャッシュメソッドのヘッダー転送は変えない。将来の POST ルートが
  // Cookie や Authorization を黙って失わないようにする
  it('POST では Cookie / Authorization / Origin を落とさない', async () => {
    await proxy('https://perldoc.jp/', {
      method: 'POST',
      body: 'x',
      headers: { 'Cookie': 'a=1', 'Authorization': 'Bearer t', 'Origin': 'https://perldoc.jp' },
    });
    const h = calls[0].init.headers;
    assert.equal(h.get('Cookie'), 'a=1');
    assert.equal(h.get('Authorization'), 'Bearer t');
    assert.equal(h.get('Origin'), 'https://perldoc.jp');
  });

  // 既定キーは X-Forwarded-Host も含む。Worker が信頼値で確定させるため、
  // 同じ run.app を叩く production と staging のキャッシュは host ごとに分かれる
  it('X-Forwarded-Host は staging では staging のホスト名になる', async () => {
    await proxy(`https://staging.perldoc.jp${DIFF}?target=${TARGET}`);
    assert.equal(calls[0].init.headers.get('X-Forwarded-Host'), 'staging.perldoc.jp');
  });
});

// diff は高コストなので、同じ比較をクエリの変種で別キーに分割させない。
// 上流 URL は Worker が分類した値だけから再構築し、元の search を渡さない
// (Plack 側の WWW::Form::UrlEncoded は `;` も区切りに使うため、素通しすると
// Worker の検証をすり抜けた target が diff 計算へ到達し得る)
describe('diff のキー正規化', () => {
  it('正常な GET の上流 URL は正規化した target だけを持つ', async () => {
    await proxy(`https://perldoc.jp${DIFF}?target=${TARGET}`);
    assert.equal(calls.length, 1);
    assert.equal(calls[0].url.href, CANONICAL_DIFF);
  });

  it('HEAD も GET と同じ上流 URL と cf になり、メソッドは HEAD のまま', async () => {
    await proxy(`https://perldoc.jp${DIFF}?target=${TARGET}`, { method: 'HEAD' });
    assert.equal(calls[0].url.href, CANONICAL_DIFF);
    assert.deepEqual(calls[0].init.cf, EDGE_CACHE);
    assert.equal(calls[0].init.method, 'HEAD');
  });

  it('percent hex の大文字小文字 (%2f / %2F) は同じ上流 URL になる', async () => {
    await proxy(`https://perldoc.jp${DIFF}?target=perl%2f5.10.1%2fperlfunc.pod`);
    await proxy(`https://perldoc.jp${DIFF}?target=${TARGET}`);
    assert.equal(calls[0].url.href, calls[1].url.href);
  });

  it('空白の表現差 (%20 / +) は同じ上流 URL になる', async () => {
    await proxy(`https://perldoc.jp${DIFF}?target=a%20b`);
    await proxy(`https://perldoc.jp${DIFF}?target=a+b`);
    assert.equal(calls[0].url.href, calls[1].url.href);
  });

  it('未知パラメーターは受理しつつ上流 URL から除く', async () => {
    await proxy(`https://perldoc.jp${DIFF}?target=${TARGET}&nonce=1`);
    assert.equal(calls[0].url.href, CANONICAL_DIFF);
  });

  it('未知パラメーターの値や順序が違っても同じ上流 URL になる', async () => {
    await proxy(`https://perldoc.jp${DIFF}?nonce=1&target=${TARGET}`);
    await proxy(`https://perldoc.jp${DIFF}?target=${TARGET}&nonce=2`);
    assert.equal(calls[0].url.href, CANONICAL_DIFF);
    assert.equal(calls[1].url.href, CANONICAL_DIFF);
  });

  // 名前の大文字小文字は区別する (Plack も区別するため Target は未知パラメーター)
  it('Target (大文字) は target として扱わない', async () => {
    await proxy(`https://perldoc.jp${DIFF}?Target=perl%2F5.40.0%2Fperlfunc.pod&target=${TARGET}`);
    assert.equal(calls[0].url.href, CANONICAL_DIFF);
  });

  // URLSearchParams は名前もデコードする。Plack も同様なので、符号化した
  // 名前で検証をすり抜けて素の search を上流に運ばせない
  it('符号化した名前 (%74arget) も target として認識する', async () => {
    await proxy(`https://perldoc.jp${DIFF}?%74arget=${TARGET}`);
    assert.equal(calls[0].url.href, CANONICAL_DIFF);
  });

  it('異なる target は異なる上流 URL になる', async () => {
    await proxy(`https://perldoc.jp${DIFF}?target=${TARGET}`);
    await proxy(`https://perldoc.jp${DIFF}?target=perl%2F5.40.0%2Fperlfunc.pod`);
    assert.notEqual(calls[0].url.href, calls[1].url.href);
  });

  it('パス中の比較元が異なれば異なる上流 URL になる', async () => {
    await proxy(`https://perldoc.jp/docs/perl/5.40.0/perlfunc.pod/diff?target=${TARGET}`);
    await proxy(`https://perldoc.jp${DIFF}?target=${TARGET}`);
    assert.notEqual(calls[0].url.href, calls[1].url.href);
  });

  it('target 未指定は上流にクエリを渡さない', async () => {
    await proxy(`https://perldoc.jp${DIFF}`);
    assert.equal(calls[0].url.href, `${ORIGIN}${DIFF}`);
  });

  // Plack は `;` も区切りに使うため、素通しすると Worker には見えない target が
  // アプリに届く。Worker の解釈 (target 未指定) で上流クエリを確定させる
  it('`;` 区切りの target は未指定として扱い、元の search を渡さない', async () => {
    await proxy(`https://perldoc.jp${DIFF}?a=b;target=${TARGET}`);
    assert.equal(calls[0].url.href, `${ORIGIN}${DIFF}`);
  });

  it('空の target は正規化した空 target だけを渡す', async () => {
    await proxy(`https://perldoc.jp${DIFF}?target=`);
    assert.equal(calls[0].url.href, `${ORIGIN}${DIFF}?target=`);
  });

  // 値の中の `;` は %3B に符号化されて届く。Plack の分割はデコード前の
  // raw 文字列に対して行われるため、再分割で別パラメーターに化けない
  it('値中の `;` は符号化して渡す', async () => {
    await proxy(`https://perldoc.jp${DIFF}?target=a%3Bb`);
    assert.equal(calls[0].url.search, '?target=a%3Bb');
  });
});

describe('diff の重複 target の拒否', () => {
  // 重複時にどちらを使うかはパーサー依存で、解釈差はキャッシュ汚染に使える。
  // 意味が曖昧な入力は上流に渡さず 400 で止める
  for (const [name, query] of [
    ['同じ値', `target=${TARGET}&target=${TARGET}`],
    ['異なる値', `target=${TARGET}&target=perl%2F5.40.0%2Fperlfunc.pod`],
    ['空値が先', `target=&target=${TARGET}`],
    ['空値が後', `target=${TARGET}&target=`],
  ]) {
    it(`${name}の重複は 400 で、上流 fetch を呼ばない`, async () => {
      const res = await proxy(`https://perldoc.jp${DIFF}?${query}`);
      assert.equal(res.status, 400);
      assert.equal(calls.length, 0);
    });
  }

  it('HEAD でも重複 target は 400 になる', async () => {
    const res = await proxy(`https://perldoc.jp${DIFF}?target=${TARGET}&target=${TARGET}`, { method: 'HEAD' });
    assert.equal(res.status, 400);
    assert.equal(calls.length, 0);
  });

  // 分類はメソッドに依らない。POST で同じ曖昧な search を上流へ運ばせない
  it('POST でも重複 target は 400 になる', async () => {
    const res = await proxy(`https://perldoc.jp${DIFF}?target=${TARGET}&target=${TARGET}`, { method: 'POST', body: 'x' });
    assert.equal(res.status, 400);
    assert.equal(calls.length, 0);
  });

  it('400 は固定文言の text/plain で、ORIGIN のホスト名を含まない', async () => {
    const res = await proxy(`https://perldoc.jp${DIFF}?target=${TARGET}&target=${TARGET}`);
    assert.equal(res.headers.get('Content-Type'), 'text/plain; charset=utf-8');
    const body = await res.text();
    assert.equal(body, 'Bad Request\n');
    assert.ok(!body.includes(new URL(ORIGIN).hostname));
  });
});

// Plack は PATH_INFO を 1 回 URL デコードするため、%2F などのエスケープ入り
// パスでも同じ diff route に到達し得る。素通しすると「非正規化の別キーで
// 同じ高コスト計算を反復させる」抜け道になる。正規の POD パスに % は
// 現れないので、エスケープ入りの diff 形パスは一律 400 で止める
describe('diff のパス等価表現', () => {
  for (const [name, path] of [
    ['ディレクトリ区切りの %2F (raw では diff 形にならない)', `/docs/perl%2F5.42.0/perlfunc.pod/diff`],
    ['ファイル名中の %2F (raw でも diff 形になる)', `/docs/perl/5.42.0%2Fperlfunc.pod/diff`],
    ['unreserved の符号化 (%70erl / %64iff)', `/docs/%70erl/5.42.0/perlfunc.pod/%64iff`],
    ['二重符号化 (%252F)', `/docs/perl/5.42.0%252Fperlfunc.pod/diff`],
    ['不正なエスケープ (%zz)', `/docs/perl/5.42.0%zzperlfunc.pod/diff`],
  ]) {
    it(`${name} は 400 で、上流 fetch を呼ばない`, async () => {
      const res = await proxy(`https://perldoc.jp${path}?target=${TARGET}`);
      assert.equal(res.status, 400);
      assert.equal(calls.length, 0);
    });
  }

  it('diff 形でないエスケープ入りパスは現在どおり転送する', async () => {
    await proxy('https://perldoc.jp/func/%E3%81%82?foo=bar');
    assert.equal(calls.length, 1);
    assert.equal(calls[0].url.href, `${ORIGIN}/func/%E3%81%82?foo=bar`);
    assert.deepEqual(calls[0].init.cf, EDGE_CACHE);
  });
});

// diff 以外のクエリはアプリが意味を持ち得る (例: tmpl/pod.tt は c().req.uri() を
// Source link に使う) ため、削除も並べ替えもせずそのまま渡す。クエリ全体が
// 既定キャッシュキーに含まれるので、変種は別キー = 現在と同じ都度計算になる
describe('一般ルートのクエリ互換', () => {
  it('diff 以外はクエリを順序ごと素通しする', async () => {
    await proxy('https://perldoc.jp/docs/perl/5.42.0/perlfunc.pod?b=2&a=1');
    assert.equal(calls[0].url.href, `${ORIGIN}/docs/perl/5.42.0/perlfunc.pod?b=2&a=1`);
  });
});
