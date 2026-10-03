// node --test viewer/web/solver.test.cjs
const test = require('node:test');
const assert = require('node:assert');
const S = require('./solver.js');

const MAP = { R: 0, B: 1, G: 2, L: 3, D: 4, H: 5, J: 6, P: 7, M: 8, '?': 9 };
const board = s => [...s.replace(/\s/g, '')].map(ch => MAP[ch]);
const ev = (s, cols = 6, rows = 5) => S.evaluate(board(s), cols, rows);

function rnd(n, seed) {
  let s = BigInt(seed);
  const out = [];
  for (let i = 0; i < n; i++) {
    s = (s * 6364136223846793005n + 1442695040888963407n) & 0xFFFFFFFFFFFFFFFFn;
    out.push(Number((s >> 33n) % 6n));
  }
  return out;
}

test('横・縦3個で消える', () => {
  assert.strictEqual(ev('RRR???' + '?'.repeat(24)).combos, 1);
  assert.strictEqual(ev('R?????R?????R?????' + '?'.repeat(12)).cleared, 3);
});

test('L字に隣接しているだけでは消えない', () => {
  assert.strictEqual(ev(`R????? RR???? ?R???? ?????? ??????`).combos, 0);
});

test('L字・十字・横1列・3×3', () => {
  const l = ev(`R????? R????? RRR??? ?????? ??????`);
  assert.strictEqual(l.combos, 1); assert.ok(l.shapes.lShape);
  assert.ok(ev(`?R???? RRR??? ?R???? ?????? ??????`).shapes.cross);
  assert.ok(ev('?'.repeat(24) + 'BBBBBB').shapes.row);
  assert.ok(ev(`GGG??? GGG??? GGG??? ?????? ??????`).shapes.square);
});

test('複数コンボ・つながった同色は1コンボ', () => {
  assert.strictEqual(ev(`RRRBBB ?????? RRR??? ?????? HHHLLL`).combos, 5);
  assert.strictEqual(ev('RRR???RRR???' + '?'.repeat(18)).combos, 1);
});

test('落下と盤面内の連鎖', () => {
  const r = ev(`?????? G????? G????? RRR??? G?????`);
  assert.strictEqual(r.combos, 2); assert.strictEqual(r.cleared, 6);
});

test('盤面外への移動は拒否', () => {
  const b = rnd(30, 9);
  assert.strictEqual(S.applyMoves(b, 6, 5, 0, ['U']), null);
  assert.strictEqual(S.applyMoves(b, 6, 5, 5, ['R']), null);
  assert.notStrictEqual(S.applyMoves(b, 6, 5, 0, ['R', 'D', 'L']), null);
});

test('探索結果は有効で、同じ入力なら同じ結果', () => {
  const b = rnd(30, 11);
  const opt = { maxSteps: 20, timeLimitMs: null, beamWidth: 300 };
  const r1 = S.solve(b, 6, 5, opt), r2 = S.solve(b, 6, 5, opt);
  assert.deepStrictEqual(r1.path, r2.path);
  assert.ok(r1.moves.length <= 20);
  const after = S.applyMoves(b, 6, 5, r1.start, r1.moves);
  assert.deepStrictEqual(S.evaluate(after, 6, 5).combos, r1.result.combos);
  assert.ok(r1.result.combos >= 3);
  for (let i = 1; i < r1.path.length; i++) {
    const a = r1.path[i - 1], c = r1.path[i];
    assert.strictEqual(Math.abs(Math.floor(a / 6) - Math.floor(c / 6)) + Math.abs(a % 6 - c % 6), 1, '斜めなし');
  }
});

test('7×6 でも探索できる', () => {
  const r = S.solve(rnd(42, 12), 7, 6, { maxSteps: 20, timeLimitMs: null, beamWidth: 200 });
  assert.ok(r.result.combos >= 3);
});

test('同じ評価なら短いルート', () => {
  const r = S.solve(board(`RR?R?? ?????? ?????? ?????? ??????`), 6, 5, { maxSteps: 20, timeLimitMs: null, beamWidth: 200 });
  assert.strictEqual(r.result.combos, 1); assert.strictEqual(r.moves.length, 1);
});

test('時間制限で止まる', () => {
  let t = 0;
  const r = S.solve(rnd(42, 14), 7, 6, { maxSteps: 48, timeLimitMs: 1000, beamWidth: 3000, now: () => (t += 10) });
  assert.ok(r.stoppedEarly);
});
