import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import { validateOrigin } from '../src/origin.js';

describe('ORIGIN の検証', () => {
  const valid = [
    'https://perldoc-jp-xxxxxxxxxx.asia-northeast1.run.app',
    // URL は末尾の / を付けても付けなくても pathname を '/' にする
    'https://perldoc-jp-xxxxxxxxxx.asia-northeast1.run.app/',
  ];
  for (const origin of valid) {
    it(`通す: ${origin}`, () => assert.equal(validateOrigin(origin), null));
  }

  const invalid = {
    '未設定': undefined,
    '空文字列': '',
    'URL でない': 'not-a-url',
    'http': 'http://perldoc-jp-x.run.app',
    'run.app 以外': 'https://evil.example',
    // ホスト名が空ラベルで終わると、endsWith だけの判定を素通りする
    'ホスト名がサフィックスだけ': 'https://.run.app',
    '空のラベルを含む': 'https://x..run.app',
    '資格情報付き': 'https://user:pass@perldoc-jp-x.run.app',
    'ポート付き': 'https://perldoc-jp-x.run.app:8443',
    'パス付き': 'https://perldoc-jp-x.run.app/api',
    'クエリ付き': 'https://perldoc-jp-x.run.app/?a=1',
    'フラグメント付き': 'https://perldoc-jp-x.run.app/#a',
  };
  for (const [name, origin] of Object.entries(invalid)) {
    it(`弾く: ${name}`, () => assert.notEqual(validateOrigin(origin), null));
  }
});
