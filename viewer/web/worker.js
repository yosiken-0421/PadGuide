// 再探索をバックグラウンドで行う（画面が固まらないように）
importScripts('solver.js');

self.onmessage = (e) => {
  const { id, cells, cols, rows, opts } = e.data;
  const r = PuzzleSolver.solve(cells, cols, rows, opts);
  self.postMessage({
    id,
    start: r.start, end: r.end, path: r.path, moves: r.moves,
    arrows: PuzzleSolver.arrows(r.path, cols),
    combos: r.result.combos, cleared: r.result.cleared,
    elapsedMs: Math.round(r.elapsedMs),
    achieved: PuzzleSolver.achieved(r.result, opts.goals),
    maxCombos: r.maxCombos,
  });
};
