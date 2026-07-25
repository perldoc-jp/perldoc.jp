// perldoc.jp のリクエストを Cloud Run (<service>.run.app) にリバースプロキシする。
// ORIGIN は wrangler deploy の --var で注入する (.github/workflows/deploy-worker.yml)。
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const target = new URL(url.pathname + url.search, env.ORIGIN);

    const headers = new Headers(request.headers);
    // Amon2::Web::redirect は Plack::Request->base (= HTTP_HOST 由来) で Location の
    // 絶対 URL を組む。fetch 先が run.app になるため、元のホスト名を明示的に
    // 引き継がないと /func/* などの正規化リダイレクトが
    // Location: https://<service>.run.app/... を返してしまう。
    // app.psgi の Plack::Middleware::ReverseProxy がこのヘッダを HTTP_HOST に戻す
    headers.set('X-Forwarded-Host', url.hostname);

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
