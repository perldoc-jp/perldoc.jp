// ORIGIN を検証して、問題があれば非ゼロで終了する。
//
// デプロイの手順は workflow と手元 (docs/cloud-run.md) の両方にあるので、
// どちらからも同じ検証を通せるように実行の入口を 1 つにしてある。
// 使い方: ORIGIN=https://... node scripts/assert-origin.mjs
import { assertValidOrigin } from '../src/origin.js';

try {
  assertValidOrigin(process.env.ORIGIN);
} catch (error) {
  console.error(String(error.message ?? error));
  process.exit(1);
}
