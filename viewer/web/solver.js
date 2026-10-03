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
    for (const v of cells) if (v !== UNKNOWN) cnt[v]++;
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

  function pairs(b, cols, rows) {
    let p = 0;
    for (let r = 0; r < rows; r++) for (let c = 0; c < cols; c++) {
      const v = b[r * cols + c];
      if (v < 0 || v === UNKNOWN) continue;
      if (c + 1 < cols && b[r * cols + c + 1] === v) p++;
      if (r + 1 < rows && b[(r + 1) * cols + c] === v) p++;
    }
    return p;
  }

  /**
   * ビームサーチ。opts: { maxSteps, timeLimitMs (null で無制限), beamWidth, goals, shouldStop, now }
   * 結果は「見つかった候補」（最大を保証しない）
   */
  function solve(cells, cols, rows, opts) {
    opts = opts || {};
    const now = opts.now || (() => Date.now());
    const N = cols * rows;
    const t0 = now();
    const deadline = opts.timeLimitMs == null ? null : t0 + opts.timeLimitMs;
    const maxSteps = Math.max(1, opts.maxSteps || 20);
    const beamWidth = Math.max(1, opts.beamWidth || 1200);
    const goals = opts.goals || {};
    const maxCombos = theoreticalMax(cells);
    const ev0 = evaluate(cells, cols, rows);

    let beamBoards = [], beamPos = [], beamPrev = [], beamDir = [], beamTurns = [];
    const layerParent = [], layerPos = [];
    for (let p = 0; p < N; p++) { beamBoards.push(Int8Array.from(cells)); beamPos.push(p); beamPrev.push(-1); beamDir.push(-1); beamTurns.push(0); }
    layerParent.push(new Array(N).fill(-1));
    layerPos.push([...Array(N).keys()]);

    let bestDepth = -1, bestParent = -1, bestLast = 0, bestRes = ev0, bestScore = goalScore(ev0, goals), bestSteps = 0, bestTurns = 0;
    let stopped = false, expanded = 0;
    const better = (score, steps, turns) => score !== bestScore ? score > bestScore : steps !== bestSteps ? steps < bestSteps : turns < bestTurns;

    outer:
    for (let depth = 1; depth <= maxSteps; depth++) {
      const cand = [];
      const seen = new Set();
      for (let i = 0; i < beamPos.length; i++) {
        const pos = beamPos[i];
        for (let di = 0; di < 4; di++) {
          const np = neighbor(pos, DIRS[di], cols, rows);
          if (np < 0 || np === beamPrev[i]) continue;
          const w = beamBoards[i].slice();
          const t = w[pos]; w[pos] = w[np]; w[np] = t;
          const key = w.join(',') + '|' + np;
          if (seen.has(key)) continue;
          seen.add(key);
          expanded++;
          const ev = evaluate(w, cols, rows);
          const score = goalScore(ev, goals);
          const turns = beamTurns[i] + (beamDir[i] >= 0 && beamDir[i] !== di ? 1 : 0);
          const heur = score + pairs(w, cols, rows) * 40 - depth * 2 - turns;
          cand.push({ w, parent: i, np, di, turns, heur, idx: cand.length });
          if (better(score, depth, turns)) {
            bestDepth = depth - 1; bestParent = i; bestLast = np;
            bestRes = ev; bestScore = score; bestSteps = depth; bestTurns = turns;
          }
          if ((expanded & 255) === 0) {
            if (opts.shouldStop && opts.shouldStop()) { stopped = true; break outer; }
            if (deadline != null && now() > deadline) { stopped = true; break outer; }
          }
        }
      }
      if (!cand.length) break;
      if (allGoalsMet(bestRes, goals, maxCombos) && bestSteps < depth) break;
      cand.sort((a, b) => a.heur !== b.heur ? b.heur - a.heur : a.idx - b.idx);
      const keep = cand.slice(0, beamWidth);
      const prevPos = beamPos;
      beamBoards = keep.map(c => c.w);
      beamPos = keep.map(c => c.np);
      beamPrev = keep.map(c => prevPos[c.parent]);
      beamDir = keep.map(c => c.di);
      beamTurns = keep.map(c => c.turns);
      layerParent.push(keep.map(c => c.parent));
      layerPos.push(keep.map(c => c.np));
      if (deadline != null && now() > deadline) { stopped = true; break; }
    }

    let path = [];
    if (bestDepth >= 0) {
      path.push(bestLast);
      let d = bestDepth, i = bestParent;
      while (d >= 0 && i >= 0) { path.push(layerPos[d][i]); i = layerParent[d][i]; d--; }
      path.reverse();
    } else path = [0];
    const moves = [];
    for (let k = 1; k < path.length; k++) {
      const a = path[k - 1], b = path[k];
      const dr = Math.floor(b / cols) - Math.floor(a / cols), dc = (b % cols) - (a % cols);
      moves.push(dr === -1 ? 'U' : dr === 1 ? 'D' : dc === -1 ? 'L' : 'R');
    }
    return { start: path[0], end: path[path.length - 1], path, moves, result: bestRes, score: bestScore,
      turns: bestTurns, elapsedMs: now() - t0, stoppedEarly: stopped, expanded };
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

  const api = { KINDS, LABELS, UNKNOWN, kindIndex, evaluate, solve, arrows, achieved, applyMoves, theoreticalMax, goalScore };
  root.PuzzleSolver = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof self !== 'undefined' ? self : globalThis);
