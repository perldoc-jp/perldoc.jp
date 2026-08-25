// ORIGIN (Cloud Run のサービス URL) の検証。
//
// Worker 本体とデプロイ手順の両方から呼ぶ。空でないことだけを見ていると、
// 値の設定ミスがデプロイでは通り、その後の全リクエストが例外になるまで
// 気づけない。手元からの手動デプロイ (docs/cloud-run.md §10) は workflow の
// ガードを通らないので、同じ検証をここに置いて両方から使う。
export function assertValidOrigin(origin) {
  const error = validateOrigin(origin);
  if (error) throw new Error(`invalid ORIGIN: ${error}`);
  return origin;
}

// 問題があればその説明を、無ければ null を返す。メッセージに入力値は含めない
// (§7: URL は機密 locator。このメッセージは CI ログや Workers Logs に残る)
export function validateOrigin(origin) {
  if (typeof origin !== 'string' || origin === '') return 'not set';

  let url;
  try {
    url = new URL(origin);
  } catch {
    return 'not a URL';
  }

  if (url.protocol !== 'https:') return 'not https';
  if (url.username || url.password) return 'has credentials';
  if (url.port) return 'has a port';
  // URL は path 無しの入力も pathname を '/' にするため、'/' だけを許す
  if (url.pathname !== '/') return 'has a path';
  if (url.search || url.hash) return 'has a query or fragment';

  const suffix = '.run.app';
  if (!url.hostname.endsWith(suffix)) return 'not a Cloud Run host';
  const labels = url.hostname.slice(0, -suffix.length).split('.');
  if (labels.some((label) => label === '')) return 'has an empty host label';

  return null;
}
