import { assertValidOrigin } from './origin.js';

// perldoc.jp のリクエストを Cloud Run (<service>.run.app) にリバースプロキシする。
// ORIGIN は wrangler deploy の --var で注入する (.github/workflows/deploy-worker.yml)。
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
        headers: { 'Content-Type': 'text/plain; charset=utf-8' },
      });
    }
  },
};

async function proxy(request, env, url) {
  assertValidOrigin(env.ORIGIN);

  // ORIGIN の URL に pathname/search だけを差し替える。
  // new URL(url.pathname + url.search, env.ORIGIN) の形は pathname が
  // //host 形式のとき protocol-relative URL として解釈され、転送先が
  // ORIGIN 以外のホストに乗っ取られる (オープンプロキシになる)
  const target = new URL(env.ORIGIN);
  target.pathname = url.pathname;
  target.search = url.search;

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

  // redirect: 'manual' が無いと Worker 側が 3xx を追ってしまい、
  // クライアントに Location が返らない。
  // body はメソッドを問わず素通しする (GET/HEAD では null なので害はなく、
  // アプリに POST ルートが増えたときにここが黙って落とすことも無くなる)
  const response = await fetch(target, {
    method: request.method,
    headers,
    body: request.body,
    redirect: 'manual',
  });
  if (env.NOINDEX !== '1') return response;

  // staging (docs/cloud-run.md §9 の動作確認) が検索結果に出ると本番と
  // 重複するため、staging のデプロイではクロール除けを足す。
  // --var は常に文字列を渡すので、'0' や 'false' を truthy と読まないよう
  // '1' との完全一致で判定する
  const tagged = new Response(response.body, response);
  tagged.headers.set('X-Robots-Tag', 'noindex, nofollow');
  return tagged;
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
