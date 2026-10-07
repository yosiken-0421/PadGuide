/*
 * パズルルート 探索エンジン（ブラウザ・Web Worker・Node.js 共通）
 * iPhone 側（ios/PuzzleCore）と同じルール・同じアルゴリズム。
 *  - 上下左右のみ（斜めなし）、盤面外への移動は不可
 *  - 縦横に同色3個以上で消去、縦横でつながった同色は1コンボ
 *  - 消去後に落下、盤面内の連鎖は計算、盤面外からの落ちコンは計算しない
 */
(function (root) {
  'use strict';

  const KINDS = ['fire', 'water', 'wood', 'light', 'dark', 'heart', 'jammer', 'poison', 'mortal', 'unknown'];
  const LABELS = ['火', '水', '木', '光', '闇', '回復', 'お邪魔', '毒', '猛毒', '不明'];
  const UNKNOWN = 9;
  const SHAPES = { lShape: 'L字', cross: '十字', row: '横1列', square: '3×3正方形' };
  const DIRS = [['U', -1, 0], ['D', 1, 0], ['L', 0, -1], ['R', 0, 1]];

  function kindIndex(key) { const i = KINDS.indexOf(key); return i < 0 ? UNKNOWN : i; }

  function neighbor(pos, d, cols, rows) {
    const r = Math.floor(pos / cols) + d[1], c = (pos % cols) + d[2];
    if (r < 0 || r >= rows || c < 0 || c >= cols) return -1;
    return r * cols + c;
  }

  /** ルートを適用（盤面外に出る移動があれば null） */
  function applyMoves(cells, cols, rows, start, moves) {
    const b = cells.slice();
    let pos = start;
    for (const m of moves) {
      const d = DIRS.find(x => x[0] === m);
      const np = d ? neighbor(pos, d, cols, rows) : -1;
      if (np < 0) return null;
      const t = b[pos]; b[pos] = b[np]; b[np] = t;
      pos = np;
    }
    return b;
  }

  function evaluate(src, cols, rows) {
    const N = cols * rows;
    const g = Int8Array.from(src);
    const mark = new Uint8Array(N), visited = new Uint8Array(N), inGroup = new Uint8Array(N);
    const res = { combos: 0, cleared: 0, clearedByKind: new Array(10).fill(0), combosByKind: new Array(10).fill(0), shapes: {} };
    for (;;) {
      mark.fill(0);
      let any = false;
      for (let r = 0; r < rows; r++) for (let c = 0; c + 2 < cols; c++) {
        const i = r * cols + c, v = g[i];
        if (v >= 0 && v !== UNKNOWN && g[i + 1] === v && g[i + 2] === v) { mark[i] = mark[i + 1] = mark[i + 2] = 1; any = true; }
      }
      for (let r = 0; r + 2 < rows; r++) for (let c = 0; c < cols; c++) {
        const i = r * cols + c, v = g[i];
        if (v >= 0 && v !== UNKNOWN && g[i + cols] === v && g[i + 2 * cols] === v) { mark[i] = mark[i + cols] = mark[i + 2 * cols] = 1; any = true; }
      }
      if (!any) break;
      visited.fill(0);
      for (let i = 0; i < N; i++) {
        if (!mark[i] || visited[i]) continue;
        const color = g[i], group = [], stack = [i];
        visited[i] = 1;
        while (stack.length) {
          const p = stack.pop();
          group.push(p);
          const pr = Math.floor(p / cols), pc = p % cols;
          const nb = [];
          if (pr > 0) nb.push(p - cols);
          if (pr < rows - 1) nb.push(p + cols);
          if (pc > 0) nb.push(p - 1);
          if (pc < cols - 1) nb.push(p + 1);
          for (const q of nb) if (mark[q] && !visited[q] && g[q] === color) { visited[q] = 1; stack.push(q); }
        }
        res.combos++; res.cleared += group.length;
        res.combosByKind[color]++; res.clearedByKind[color] += group.length;
        detectShapes(group, cols, rows, inGroup, res.shapes);
      }
      for (let i = 0; i < N; i++) if (mark[i]) g[i] = -1;
      for (let c = 0; c < cols; c++) {
        let w = rows - 1;
        for (let r = rows - 1; r >= 0; r--) { const v = g[r * cols + c]; if (v !== -1) { g[w * cols + c] = v; w--; } }
        while (w >= 0) { g[w * cols + c] = -1; w--; }
      }
    }
    res.fiveColors = [0, 1, 2, 3, 4].every(k => res.combosByKind[k] > 0);
    return res;
  }

  function detectShapes(group, cols, rows, inGroup, shapes) {
    const n = group.length;
    if (!(n === 5 || n === 9 || n >= cols)) return;
    for (const p of group) inGroup[p] = 1;
    if (n >= cols) {
      for (let r = 0; r < rows; r++) {
        let full = true;
        for (let c = 0; c < cols; c++) if (!inGroup[r * cols + c]) { full = false; break; }
        if (full) { shapes.row = true; break; }
      }
    }
    if (n === 5) {
      for (const p of group) {
        const r = Math.floor(p / cols), c = p % cols;
        if (r > 0 && r < rows - 1 && c > 0 && c < cols - 1 && inGroup[p - cols] && inGroup[p + cols] && inGroup[p - 1] && inGroup[p + 1]) shapes.cross = true;
        for (const dc of [-1, 1]) for (const dr of [-1, 1]) {
          const c2 = c + 2 * dc, r2 = r + 2 * dr;
          if (c2 < 0 || c2 >= cols || r2 < 0 || r2 >= rows) continue;
          if (inGroup[p + dc] && inGroup[p + 2 * dc] && inGroup[p + dr * cols] && inGroup[p + 2 * dr * cols]) shapes.lShape = true;
        }
      }
    }
    if (n === 9) {
      const rs = group.map(p => Math.floor(p / cols)), cs = group.map(p => p % cols);
      if (Math.max(...rs) - Math.min(...rs) === 2 && Math.max(...cs) - Math.min(...cs) === 2) shapes.square = true;
    }
    for (const p of group) inGroup[p] = 0;
  }

  function theoreticalMax(cells) {
    const cnt = new Array(10).fill(0);
    for (const v of cells) if (v >= 0 && v !== UNKNOWN) cnt[v]++;
    return cnt.reduce((a, c) => a + Math.floor(c / 3), 0);
  }

  function shapeGoals(goals) { return Object.keys(SHAPES).filter(k => goals && goals[k]); }

  function goalScore(r, goals) {
    goals = goals || {};
    let s = r.combos * 10000 + r.cleared * 10;
    if (goals.priorityColor != null && goals.priorityColor >= 0) {
      const i = goals.priorityColor;
      s += r.clearedByKind[i] * 400 + (r.combosByKind[i] > 0 ? 3000 : 0);
    }
    if (goals.heal) s += (r.clearedByKind[5] > 0 ? 3000 : 0) + r.clearedByKind[5] * 100;
    if (goals.fiveColors && r.fiveColors) s += 30000;
    for (const k of shapeGoals(goals)) if (r.shapes[k]) s += 30000;
    return s;
  }

  function allGoalsMet(r, goals, maxCombos) {
    goals = goals || {};
    if (r.combos < maxCombos) return false;
    if (goals.fiveColors && !r.fiveColors) return false;
    for (const k of shapeGoals(goals)) if (!r.shapes[k]) return false;
    if (goals.heal && r.clearedByKind[5] === 0) return false;
    if (goals.priorityColor != null && goals.priorityColor >= 0 && r.combosByKind[goals.priorityColor] === 0) return false;
    return true;
  }

  /** 探索用の速い評価（メモリ確保なし）。結果は out に入る */
  function makeQuickEval(cols, rows) {
    const N = cols * rows;
    const g = new Int8Array(N), mark = new Uint8Array(N), visited = new Uint8Array(N), inGroup = new Uint8Array(N);
    const stack = new Int32Array(N), group = new Int32Array(N);
    const out = { combos: 0, cleared: 0, clearedByKind: new Int32Array(10), combosByKind: new Int32Array(10), shapes: {} };
    function run(src, off, wantShapes) {
      for (let i = 0; i < N; i++) g[i] = src[off + i];
      out.combos = 0; out.cleared = 0; out.clearedByKind.fill(0); out.combosByKind.fill(0);
      if (wantShapes) out.shapes = {};
      for (;;) {
        mark.fill(0);
        let any = false;
        for (let r = 0; r < rows; r++) {
          const base = r * cols;
          for (let c = 0; c + 2 < cols; c++) {
            const i = base + c, v = g[i];
            if (v >= 0 && v !== UNKNOWN && g[i + 1] === v && g[i + 2] === v) { mark[i] = mark[i + 1] = mark[i + 2] = 1; any = true; }
          }
        }
        for (let i = 0; i + 2 * cols < N; i++) {
          const v = g[i];
          if (v >= 0 && v !== UNKNOWN && g[i + cols] === v && g[i + 2 * cols] === v) { mark[i] = mark[i + cols] = mark[i + 2 * cols] = 1; any = true; }
        }
        if (!any) break;
        visited.fill(0);
        for (let i = 0; i < N; i++) {
          if (!mark[i] || visited[i]) continue;
          const color = g[i];
          let sp = 0, n = 0;
          stack[sp++] = i; visited[i] = 1;
          while (sp) {
            const p = stack[--sp];
            group[n++] = p;
            const pc = p % cols;
            let q = p - cols;
            if (q >= 0 && mark[q] && !visited[q] && g[q] === color) { visited[q] = 1; stack[sp++] = q; }
            q = p + cols;
            if (q < N && mark[q] && !visited[q] && g[q] === color) { visited[q] = 1; stack[sp++] = q; }
            if (pc > 0) { q = p - 1; if (mark[q] && !visited[q] && g[q] === color) { visited[q] = 1; stack[sp++] = q; } }
            if (pc < cols - 1) { q = p + 1; if (mark[q] && !visited[q] && g[q] === color) { visited[q] = 1; stack[sp++] = q; } }
          }
          out.combos++; out.cleared += n;
          out.combosByKind[color]++; out.clearedByKind[color] += n;
          if (wantShapes) detectShapes(Array.from(group.subarray(0, n)), cols, rows, inGroup, out.shapes);
        }
        for (let i = 0; i < N; i++) if (mark[i]) g[i] = -1;
        for (let c = 0; c < cols; c++) {
          let w = N - cols + c;
          for (let i = w; i >= 0; i -= cols) { const v = g[i]; if (v !== -1) { g[w] = v; w -= cols; } }
          while (w >= 0) { g[w] = -1; w -= cols; }
        }
      }
      out.fiveColors = out.combosByKind[0] > 0 && out.combosByKind[1] > 0 && out.combosByKind[2] > 0 &&
        out.combosByKind[3] > 0 && out.combosByKind[4] > 0;
      return out;
    }
    return run;
  }

  /** 最大コンボに向けた揃いやすさ（iPhone 側の Solver.potential と同じ） */
  function potential(b, off, cols, rows, e) {
    let pairs = 0, near = 0;
    for (let r = 0; r < rows; r++) for (let c = 0; c < cols; c++) {
      const i = off + r * cols + c, v = b[i];
      if (v < 0 || v === UNKNOWN) continue;
      if (c + 1 < cols && b[i + 1] === v) pairs++;
      if (r + 1 < rows && b[i + cols] === v) pairs++;
      if (c + 2 < cols && b[i + 2] === v && b[i + 1] !== v) near++;
      if (r + 2 < rows && b[i + 2 * cols] === v && b[i + cols] !== v) near++;
    }
    let waste = 0;
    for (let k = 0; k < 10; k++) if (e.combosByKind[k] > 0) waste += e.clearedByKind[k] - 3 * e.combosByKind[k];
    return pairs * 30 + near * 15 - waste * 100;
  }

  /**
   * 敵の妨害による縛り（iPhone 側の BoardConstraints と同じ）。
   * { cols, rows, fixedStart, blocked: [], thorns: [], hidden: [], unclearable: [種類番号] }
   */
  function activeConstraints(c, cols, rows) {
    if (!c) return null;
    // マスを指定する縛りは同じ大きさの盤面だけ。「消せない色」は大きさによらず使う
    const same = c.cols === cols && c.rows === rows;
    const x = { fixedStart: same && c.fixedStart != null ? c.fixedStart : null, blocked: same ? c.blocked || [] : [],
      thorns: same ? c.thorns || [] : [], hidden: same ? c.hidden || [] : [], unclearable: c.unclearable || [] };
    const empty = x.fixedStart == null && !x.blocked.length && !x.thorns.length && !x.hidden.length && !x.unclearable.length;
    return empty ? null : x;
  }
  function canEnter(c, i) { return !c || (c.blocked.indexOf(i) < 0 && c.thorns.indexOf(i) < 0); }
  /** 計算用の盤面：雲・ルーレットのマスと消せない種類は「消えないドロップ」として扱う */
  function solvingCells(cells, c) {
    if (!c) return Array.from(cells);
    return Array.from(cells, (v, i) => (c.hidden.indexOf(i) >= 0 || c.unclearable.indexOf(v) >= 0) ? UNKNOWN : v);
  }
  function startCells(c, N) {
    if (c && c.fixedStart != null && c.fixedStart >= 0 && c.fixedStart < N) return [c.fixedStart];
    const out = [];
    for (let i = 0; i < N; i++) if (canEnter(c, i)) out.push(i);
    return out;
  }

  /** 探索幅 width のビームサーチを1回（iPhone 側の Solver.beamRun と同じ手順） */
  function beamRun(cells, cols, rows, width, maxSteps, goals, maxCombos, run, deadline, opts, now, cons) {
    const N = cols * rows;
    const wantShapes = shapeGoals(goals).length > 0;
    const nbr = new Int32Array(N * 4);
    for (let p = 0; p < N; p++) for (let di = 0; di < 4; di++) {
      const q = neighbor(p, DIRS[di], cols, rows);
      nbr[p * 4 + di] = q >= 0 && canEnter(cons, q) ? q : -1;   // 通れないマスへは進まない
    }
    const starts = startCells(cons, N);
    const beamCap = Math.max(width, N), candCap = beamCap * 4;
    let beamBoards = new Int8Array(beamCap * N);
    const candBoards = new Int8Array(candCap * N);
    let beamPos = [], beamPrev = [], beamDir = [], beamTurns = [];
    starts.forEach((p, j) => {
      beamBoards.set(cells, j * N);
      beamPos.push(p); beamPrev.push(-1); beamDir.push(-1); beamTurns.push(0);
    });
    const layerParent = [new Array(starts.length).fill(-1)], layerPos = [starts.slice()];
    const res = { path: [], score: -Infinity, steps: 0, turns: 0, met: false, stopped: false, expanded: 0 };
    let bestDepth = -1, bestParent = -1, bestLast = 0;
    const seen = new Set();
    outer:
    for (let depth = 1; depth <= maxSteps; depth++) {
      const candParent = [], candPos = [], candDir = [], candTurns = [], candHeur = [];
      seen.clear();
      for (let i = 0; i < beamPos.length; i++) {
        const pos = beamPos[i], so = i * N;
        for (let di = 0; di < 4; di++) {
          const np = nbr[pos * 4 + di];
          if (np < 0 || np === beamPrev[i]) continue;
          const off = candPos.length * N;
          for (let k = 0; k < N; k++) candBoards[off + k] = beamBoards[so + k];
          const t = candBoards[off + pos]; candBoards[off + pos] = candBoards[off + np]; candBoards[off + np] = t;
          let h1 = 2166136261, h2 = 5381;
          for (let k = 0; k < N; k++) { const v = candBoards[off + k] + 1; h1 = Math.imul(h1 ^ v, 16777619); h2 = (Math.imul(h2, 33) + v) | 0; }
          h1 = Math.imul(h1 ^ np, 16777619);
          const key = (h1 >>> 0) * 2097152 + ((h2 >>> 0) & 2097151);
          if (seen.has(key)) continue;
          seen.add(key);
          res.expanded++;
          const e = run(candBoards, off, wantShapes);
          const score = goalScore(e, goals);
          const turns = beamTurns[i] + (beamDir[i] >= 0 && beamDir[i] !== di ? 1 : 0);
          const heur = score - e.cleared * 10 + potential(candBoards, off, cols, rows, e) - turns;
          candParent.push(i); candPos.push(np); candDir.push(di); candTurns.push(turns); candHeur.push(heur);
          if (score > res.score || (score === res.score && (depth < res.steps || (depth === res.steps && turns < res.turns)))) {
            bestDepth = depth - 1; bestParent = i; bestLast = np;
            res.score = score; res.steps = depth; res.turns = turns;
            res.met = allGoalsMet(e, goals, maxCombos);
          }
          if ((res.expanded & 255) === 0) {
            if (opts.shouldStop && opts.shouldStop()) { res.stopped = true; break outer; }
            if (deadline != null && now() > deadline) { res.stopped = true; break outer; }
          }
        }
      }
      if (!candPos.length || res.met) break;
      const order = candPos.map((_, i) => i);
      order.sort((a, b) => candHeur[a] !== candHeur[b] ? candHeur[b] - candHeur[a] : a - b);
      const keep = Math.min(width, order.length);
      const nb = new Int8Array(beamCap * N);
      const np = [], npr = [], nd = [], nt = [], lp = [], lpos = [];
      for (let j = 0; j < keep; j++) {
        const idx = order[j];
        nb.set(candBoards.subarray(idx * N, idx * N + N), j * N);
        np.push(candPos[idx]); npr.push(beamPos[candParent[idx]]); nd.push(candDir[idx]); nt.push(candTurns[idx]);
        lp.push(candParent[idx]); lpos.push(candPos[idx]);
      }
      beamBoards = nb; beamPos = np; beamPrev = npr; beamDir = nd; beamTurns = nt;
      layerParent.push(lp); layerPos.push(lpos);
      if (opts.shouldStop && opts.shouldStop()) { res.stopped = true; break; }
      if (deadline != null && now() > deadline) { res.stopped = true; break; }
    }
    if (bestDepth >= 0) {
      const path = [bestLast];
      let d = bestDepth, i = bestParent;
      while (d >= 0 && i >= 0) { path.push(layerPos[d][i]); i = layerParent[d][i]; d--; }
      res.path = path.reverse();
    }
    return res;
  }

  /**
   * ビームサーチ。opts: { maxSteps, timeLimitMs (null で無制限), beamWidth, maxBeamWidth, goals, shouldStop, now }
   * 盤面の色の数から決まる最大コンボ数に届くまで探す（時間内に届かなければ探索幅を広げて探し直す）。
   * 結果は「見つかった候補」（最大を保証しない）
   */
  function solve(cells, cols, rows, opts) {
    opts = opts || {};
    const now = opts.now || (() => Date.now());
    const t0 = now();
    const deadline = opts.timeLimitMs == null ? null : t0 + opts.timeLimitMs;
    const maxSteps = Math.max(1, opts.maxSteps || 48);
    const maxBeamWidth = opts.maxBeamWidth || 12000;
    const goals = opts.goals || {};
    const cons = activeConstraints(opts.constraints, cols, rows);
    cells = solvingCells(cells, cons);
    const maxCombos = theoreticalMax(cells);
    const ev0 = evaluate(cells, cols, rows);
    const run = makeQuickEval(cols, rows);
    let best = { path: [startCells(cons, cols * rows)[0] || 0], score: goalScore(ev0, goals), steps: 0, turns: 0, met: allGoalsMet(ev0, goals, maxCombos) };
    const better = (a, b) => a.score !== b.score ? a.score > b.score : a.steps !== b.steps ? a.steps < b.steps : a.turns < b.turns;
    let width = Math.max(1, opts.beamWidth || 800), stopped = false, expanded = 0;
    for (;;) {
      const runStart = now();
      const r = beamRun(cells, cols, rows, width, maxSteps, goals, maxCombos, run, deadline, opts, now, cons);
      expanded += r.expanded;
      if (r.path.length >= 2 && better(r, best)) best = r;
      if (r.stopped) { stopped = true; break; }
      if (best.met || deadline == null) break;
      const t = now(), rate = r.expanded / Math.max(t - runStart, 0.1), remaining = deadline - t;
      if (remaining <= 0) { stopped = true; break; }
      const next = Math.floor(Math.min(rate * remaining * 0.85 / (2.6 * maxSteps), maxBeamWidth));
      if (next < Math.floor(width * 13 / 10)) break;
      width = next;
    }
    const path = best.path;
    const b = Array.from(cells);
    for (let k = 1; k < path.length; k++) { const t = b[path[k - 1]]; b[path[k - 1]] = b[path[k]]; b[path[k]] = t; }
    const result = path.length >= 2 ? evaluate(b, cols, rows) : ev0;
    const moves = [];
    for (let k = 1; k < path.length; k++) {
      const a = path[k - 1], c = path[k];
      const dr = Math.floor(c / cols) - Math.floor(a / cols), dc = (c % cols) - (a % cols);
      moves.push(dr === -1 ? 'U' : dr === 1 ? 'D' : dc === -1 ? 'L' : 'R');
    }
    return { start: path[0], end: path[path.length - 1], path, moves, result, score: goalScore(result, goals),
      turns: best.turns, elapsedMs: now() - t0, stoppedEarly: stopped, expanded,
      maxCombos, reachedMax: result.combos >= maxCombos, constrained: !!cons };
  }

  /** ルートが縛りを守っているか */
  function allowsPath(constraints, cols, rows, path) {
    const c = activeConstraints(constraints, cols, rows);
    if (!c || !path.length) return true;
    if (c.fixedStart != null ? path[0] !== c.fixedStart : !canEnter(c, path[0])) return false;
    return path.slice(1).every(i => canEnter(c, i));
  }

  /** 矢印座標（iPhone 側と同じずらし方） */
  function arrows(path, cols) {
    if (path.length < 2) return [];
    const visits = {}, pts = [];
    path.forEach((p, i) => {
      const n = visits[p] || 0; visits[p] = n + 1;
      const off = i === 0 ? 0 : Math.min(n, 4) * 0.08;
      pts.push([(p % cols) + 0.5 + off, Math.floor(p / cols) + 0.5 + off]);
    });
    const out = [];
    for (let i = 1; i < pts.length; i++) out.push([pts[i - 1][0], pts[i - 1][1], pts[i][0], pts[i][1]]);
    return out;
  }

  function achieved(r, goals) {
    const a = [];
    if (r.fiveColors) a.push('5色同時消し');
    for (const k of Object.keys(SHAPES)) if (r.shapes[k]) a.push(SHAPES[k]);
    if (r.clearedByKind[5] > 0) a.push('回復' + r.clearedByKind[5] + '個');
    if (goals && goals.priorityColor != null && goals.priorityColor >= 0 && r.clearedByKind[goals.priorityColor] > 0) {
      a.push(LABELS[goals.priorityColor] + r.clearedByKind[goals.priorityColor] + '個');
    }
    return a;
  }

  const api = { KINDS, LABELS, UNKNOWN, kindIndex, evaluate, solve, arrows, achieved, applyMoves, theoreticalMax, goalScore,
    allowsPath, solvingCells: (cells, c, cols, rows) => solvingCells(cells, activeConstraints(c, cols, rows)) };
  root.PuzzleSolver = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof self !== 'undefined' ? self : globalThis);
