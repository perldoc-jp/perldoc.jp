import { assertValidOrigin } from './origin.js';

// perldoc.jp のリクエストを Cloud Run (<service>.run.app) にリバースプロキシする。
// ORIGIN は scripts/deploy.sh が Worker の secret として注入する
// (--secrets-file。.github/workflows/deploy-worker.yml)。
export default {
  async fetch(request, env) {
    // origin 側の障害や設定ミスをそのまま例外にすると、利用者には Cloudflare の
    // 汎用エラーページが出て、原因の手掛かりもログに残らない。ハンドラ全体を
    // 包んで 502 に変え、調べるための情報だけを構造化ログに出す
    const url = safeUrl(request.url);
    try {
      return await proxy(request, env, url);
    } catch (error) {
      // catch 自身が例外を投げないようにする (throw null や文字列の reject でも
      // 502 を返しきる)
      console.error({
        message: 'proxy failed',
        ray: request.headers.get('CF-Ray'),
        path: url ? url.pathname : null,
        error: describe(error),
      });
      return new Response('Bad Gateway\n', {
        status: 502,
        headers: {
          'Content-Type': 'text/plain; charset=utf-8',
          'Cloudflare-CDN-Cache-Control': 'no-store',
        },
      });
    }
  },
};

async function proxy(request, env, url) {
  assertValidOrigin(env.ORIGIN);

  const diff = classifyDiffRequest(url);
  if (diff.kind === 'reject') {
    // 重複 target とエスケープ入りの diff 形パスは、キー分割や非正規化キーでの
    // 再計算強制に使えるため上流に渡さない。本文は固定文字列とし、502 と同じ
    // 方針で ORIGIN・入力値・スタックトレースを含めない
    return new Response('Bad Request\n', {
      status: 400,
      headers: {
        'Content-Type': 'text/plain; charset=utf-8',
        'Cloudflare-CDN-Cache-Control': 'no-store',
      },
    });
  }

  // ORIGIN の URL に pathname/search だけを差し替える。
  // new URL(url.pathname + url.search, env.ORIGIN) の形は pathname が
  // //host 形式のとき protocol-relative URL として解釈され、転送先が
  // ORIGIN 以外のホストに乗っ取られる (オープンプロキシになる)
  const target = new URL(env.ORIGIN);
  target.pathname = url.pathname;
  // diff の search は元の文字列を渡さず、Worker が分類した値から再構築する。
  // Plack 側のクエリパーサー (WWW::Form::UrlEncoded) は `;` も区切りに使うため、
  // 素通しすると Worker には見えない target が diff 計算へ到達し得る
  target.search = diff.kind === 'rebuild' ? diff.search : url.search;

  const headers = new Headers(request.headers);
  // Plack::Middleware::ReverseProxy が読む X-Forwarded-* は
  // For / Host / HTTPS / Port / Proto / Server の 6 つで、いずれもクライアントが
  // 自由に送れる。個別に上書きすると取りこぼす (例えば
  // X-Forwarded-Port: 443@evil.example は HTTP_HOST を
  // perldoc.jp:443@evil.example にし、Location の実ホストが evil.example になる)
  // ため、転送前に一掃してから必要なものだけをここで確定させる
  for (const name of [...headers.keys()]) {
    if (/^x-forwarded-/i.test(name) || name.toLowerCase() === 'forwarded') headers.delete(name);
  }
  // 一掃で Cloudflare が付けた実クライアント IP (X-Forwarded-For) も消えるため、
  // Cloudflare 自身が確定させる CF-Connecting-IP から設定し直す。
  // ただし Cloud Run のフロントエンドが受け取った X-Forwarded-For の末尾に
  // 自分から見た接続元 (= Cloudflare の egress IP) を足すため、origin の
  // ReverseProxy が採る「最後の値」は egress IP のままになる。ここで載せた
  // 実クライアント IP はヘッダの先頭に残るだけで、REMOTE_ADDR にはならない
  const clientIp = request.headers.get('CF-Connecting-IP');
  if (clientIp) headers.set('X-Forwarded-For', clientIp);
  // Amon2::Web::redirect は Plack::Request->base (= HTTP_HOST 由来) で Location の
  // 絶対 URL を組む。fetch 先が run.app になるため、元のホスト名を明示的に
  // 引き継がないと /func/* などの正規化リダイレクトが
  // Location: https://<service>.run.app/... を返してしまう。
  // app.psgi の Plack::Middleware::ReverseProxy がこのヘッダを HTTP_HOST に戻す
  headers.set('X-Forwarded-Host', url.hostname);
  // ReverseProxy は X-Forwarded-Proto eq 'https' の完全一致でしか
  // psgi.url_scheme を https にしない
  headers.set('X-Forwarded-Proto', 'https');

  // 全パスの GET/HEAD の status 200 をエッジの二層でキャッシュする
  // (docs/cloud-run.md §10 のエッジキャッシュ節)。この内側 (fetch の cf 設定) の
  // キャッシュキーは既定のまま、
  // つまり上流 URL 全体と Origin / method override 系 / X-Forwarded-Host などの
  // ヘッダーで決まる。値を変えるだけで同じ URL を別キーへ割って MISS を強制
  // できるヘッダーと、上流への再検証指示 (Cache-Control / Pragma)、認証状態を
  // 共有キャッシュへ持ち込む Cookie / Authorization は上流に渡さない。
  // アプリはこれらで応答を変えない (公開・非個人化のみ)。X-Forwarded-Host は
  // Worker が確定した信頼値で、production と staging のキー分離を担うため残す
  const cacheable = request.method === 'GET' || request.method === 'HEAD';
  if (cacheable) {
    for (const name of CACHE_NEUTRAL_HEADERS) headers.delete(name);
  }

  // redirect: 'manual' が無いと Worker 側が 3xx を追ってしまい、
  // クライアントに Location が返らない。
  // body はメソッドを問わず素通しする (GET/HEAD では null なので害はなく、
  // アプリに POST ルートが増えたときにここが黙って落とすことも無くなる)
  const init = {
    method: request.method,
    headers,
    body: request.body,
    redirect: 'manual',
  };
  if (cacheable) {
    // cacheTtlByStatus は cacheEverything を含意しないため両方指定する。
    // 200 だけを保存し、404 / 503 / 3xx などは負数 = 保存しない
    // (一時的な失敗やリダイレクトを固定しない)。エッジ TTL であり、
    // ブラウザー向けの Cache-Control はレスポンスへ足さない。
    // POST 等に cf を付けないのは、キャッシュ対象メソッドをコード上でも
    // 明示するため (Cloudflare 側でも cf のキャッシュ設定は GET/HEAD 限定)
    init.cf = {
      cacheEverything: true,
      cacheTtlByStatus: { '200': ORIGIN_CACHE_TTL, '201-599': -1 },
    };
  }
  const response = await fetch(target, init);

  // 外側の Workers Cache (wrangler.jsonc の cache.enabled。HIT ではこの
  // Worker 自体が起動しない) はレスポンスヘッダーで制御する。無指定は
  // オプトアウトにならず RFC 9111 のヒューリスティック (404 も 180 秒保持など)
  // が適用されるため、全レスポンスで明示する。保存するのは内側と同じ
  // GET/HEAD の 200 だけで、それ以外は no-store。
  // Cloudflare-CDN-Cache-Control はエッジで消費されクライアントへ届かない
  // ヘッダーなので、「ブラウザー向け TTL は app.psgi の Cache-Control が
  // 唯一の情報源」の所有境界は変わらない。オリジン由来の値に依存せず常に
  // 上書きする (set)
  const out = new Response(response.body, response);
  out.headers.set(
    'Cloudflare-CDN-Cache-Control',
    cacheable && response.status === 200 ? `max-age=${WORKERS_CACHE_TTL}` : 'no-store',
  );
  if (env.NOINDEX === '1') {
    // staging (docs/cloud-run.md §10 の動作確認) が検索結果に出ると本番と
    // 重複するため、staging のデプロイではクロール除けを足す。キャッシュには
    // このヘッダー付きで入るので、Worker が走らない HIT でも毎回付く。
    // vars は常に文字列を渡すので、'0' や 'false' を truthy と読まないよう
    // '1' との完全一致で判定する
    out.headers.set('X-Robots-Tag', 'noindex, nofollow');
  }
  return out;
}

// エッジキャッシュは二層 (docs/cloud-run.md §10 のエッジキャッシュ節)。
//   外側: Workers Cache。Worker の手前で応答を保持し、HIT では Worker が
//         起動しない。キーには X-Forwarded-* や method override 系など
//         クライアントが自由に変えられるヘッダーが含まれるため、キー分割で
//         MISS を強制できる = 性能最適化であって防御層ではない
//   内側: fetch の cf 設定。Worker が一掃・確定したヘッダーと正規化した
//         上流 URL がキーになるため、外側をすり抜けた変種はここへ寄る。
//         オリジン保護の backstop はこちら
// 再デプロイ後の残留は最悪で二層の TTL の和になる (内側の失効直前の応答で
// 外側が充填された場合)。「最大 2 時間」の予算 (docs/cloud-run.md 構成の
// 概要) を保つため 3600 + 3600 に分割している。片方だけ変えないこと
const WORKERS_CACHE_TTL = 3600;
const ORIGIN_CACHE_TTL = 3600;

// diff の canonical path。エスケープ (%XX) を含む形は canonical になり得ない
// (実在する POD パスは英数と . _ / - だけで構成される。classifyDiffRequest 参照)
const DIFF_PATH = /^\/docs\/(?:modules|perl)\/.+\.pod\/diff$/;

// キャッシュ対象の GET/HEAD で上流サブリクエストから削るヘッダー。
// Origin と override 系 6 つは Cloudflare の既定キャッシュキーに含まれ、
// 値を変えるだけで同じ URL を別キーへ分割して MISS を強制できる。
// Cache-Control / Pragma は上流への再検証指示になり、Cookie / Authorization は
// キャッシュの BYPASS 誘発と認証状態の共有キャッシュへの持ち込みを招く。
// 公開・非個人化のアプリではいずれも上流に必要ない。
// Forwarded / X-Forwarded-* は proxy() の一掃と再構築が別途扱う
const CACHE_NEUTRAL_HEADERS = [
  'Origin',
  'X-HTTP-Method-Override',
  'X-HTTP-Method',
  'X-Method-Override',
  'X-Host',
  'X-Original-URL',
  'X-Rewrite-URL',
  'Cache-Control',
  'Pragma',
  'Authorization',
  'Cookie',
];

// diff リクエストの分類。メソッドには依らない (曖昧な search はどのメソッドでも
// 上流に渡さない)。戻り値の kind:
//   ordinary — diff ではない。search を素通しする既存の汎用プロキシ挙動のまま
//   reject   — 400。上流 fetch を呼ばない
//   rebuild  — diff。search は分類結果から再構築した文字列に差し替える
function classifyDiffRequest(url) {
  const pathname = url.pathname;
  if (pathname.includes('%')) {
    // Plack は PATH_INFO を 1 回 URL デコードするため、%2F 入りの表現でも
    // 同じ diff route に到達し得る (スラッシュの encode 可否 × hex の大文字
    // 小文字で、1 つの diff に多数の非正規化キーを鋳造できる)。正規の
    // diff URL に % は現れないので、デコードの前後どちらかが diff の形なら
    // 上流に渡さず 400 で止める。ゾーンの URL 正規化設定に依存せず、
    // この不変条件を Worker の中だけで閉じる
    const decoded = tryDecodePath(pathname);
    if (DIFF_PATH.test(pathname) || (decoded !== null && DIFF_PATH.test(decoded))) {
      return { kind: 'reject' };
    }
    return { kind: 'ordinary' };
  }
  if (!DIFF_PATH.test(pathname)) return { kind: 'ordinary' };

  // target 以外のパラメーターは現行アプリと同様に受理するが、上流へは
  // 書き戻さない (同じ比較をキー分割させない)。重複だけは解釈がパーサー
  // 依存で曖昧なので 400 にする
  const targets = url.searchParams.getAll('target');
  if (targets.length > 1) return { kind: 'reject' };
  if (targets.length === 0) return { kind: 'rebuild', search: '' };

  // URLSearchParams の再シリアライズを唯一の canonical 形にする。
  // %2f / %2F や %20 / + の表記差が同じ上流 URL = 同じキャッシュキーに寄り、
  // 値中の `;` 等の区切り文字は符号化されて Plack 側で再分割されない
  return { kind: 'rebuild', search: new URLSearchParams([['target', targets[0]]]).toString() };
}

// 不正なエスケープ (%zz 等) はデコードできない。null を返し、diff の形と
// 一致する場合の扱いは呼び出し側が決める
function tryDecodePath(pathname) {
  try {
    return decodeURIComponent(pathname);
  } catch {
    return null;
  }
}

function safeUrl(value) {
  try {
    return new URL(value);
  } catch {
    return null;
  }
}

// Error 以外が投げられてもログの組み立てで落ちないようにする。
// String() 自体が投げる値もある (Object.create(null) は toString を持たない)。
// run.app のホスト名は削る (§7: ORIGIN は機密 locator。ランタイムの fetch
// エラーが接続先を含んでも Workers Logs に実ホスト名を残さない)
function describe(error) {
  try {
    if (error instanceof Error) return redact(`${error.name}: ${error.message}`);
    return redact(`non-error thrown: ${String(error)}`);
  } catch {
    return 'non-error thrown: (not representable)';
  }
}

function redact(text) {
  return text.replace(/[0-9a-z.-]+\.run\.app/gi, '<origin>');
}
