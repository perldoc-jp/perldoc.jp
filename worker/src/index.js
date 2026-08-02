// perldoc.jp のリクエストを Cloud Run (<service>.run.app) にリバースプロキシする。
// ORIGIN は wrangler deploy の --var で注入する (.github/workflows/deploy-worker.yml)。
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
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
    // Amon2::Web::redirect は Plack::Request->base (= HTTP_HOST 由来) で Location の
    // 絶対 URL を組む。fetch 先が run.app になるため、元のホスト名を明示的に
    // 引き継がないと /func/* などの正規化リダイレクトが
    // Location: https://<service>.run.app/... を返してしまう。
    // app.psgi の Plack::Middleware::ReverseProxy がこのヘッダを HTTP_HOST に戻す
    headers.set('X-Forwarded-Host', url.hostname);
    // ReverseProxy は X-Forwarded-Proto eq 'https' の完全一致でしか
    // psgi.url_scheme を https にしない
    headers.set('X-Forwarded-Proto', 'https');

    // アプリに POST ルートは無いのでボディは転送しない。
    // redirect: 'manual' が無いと Worker 側が 3xx を追ってしまい、
    // クライアントに Location が返らない
    const response = await fetch(target, { method: request.method, headers, redirect: 'manual' });
    if (!env.NOINDEX) return response;

    // staging (docs/cloud-run.md §9 の動作確認) が検索結果に出ると本番と
    // 重複するため、NOINDEX を渡したデプロイではクロール除けを足す
    const tagged = new Response(response.body, response);
    tagged.headers.set('X-Robots-Tag', 'noindex, nofollow');
    return tagged;
  },
};
