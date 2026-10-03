/* パズルルート PC ビューアー（画面側）
 * サーバーから届く解析結果（盤面・信頼度・ルート）を表示する。画像は扱わない。 */
(function () {
  'use strict';
  const S = window.PuzzleSolver;
  const $ = (id) => document.getElementById(id);

  // 独自デザインのドロップ色と短い表記
  const ORB = [
    { fill: '#E8483C', mark: '火' }, { fill: '#2F8CEB', mark: '水' }, { fill: '#2FB866', mark: '木' },
    { fill: '#F4C531', mark: '光' }, { fill: '#9654D6', mark: '闇' }, { fill: '#F27BB8', mark: '回' },
    { fill: '#B7BFCC', mark: '邪' }, { fill: '#8E6AA8', mark: '毒' }, { fill: '#4A2A5E', mark: '猛' },
    { fill: '#5B6478', mark: '?' },
  ];
  const STATUS_TEXT = {
    unstable: '盤面が変化中です（操作中・ルーレットなど）。止まると表示します',
    dark: '画面が暗いためルートを確定しません（暗闇など）',
    invalid: '盤面が見つかりません。パズル画面を表示してください',
    nocombo: 'この盤面ではコンボが見つかりませんでした',
  };

  const st = {
    conn: null,          // サーバーの状態
    iphone: null,        // iPhone から届いた最新の結果
    board: null,         // { cols, rows, cells:int[], conf:number[] }
    route: null,         // { start, end, path, moves, arrows, combos, steps, elapsedMs, achieved, source }
    status: null,
    edited: false,
    p: 0,                // 再生位置（0〜手数）
    playing: false,
    lastQR: -1,
    worker: null, jobId: 0,
    pipCanvas: null,
  };

  // ---------- サーバーとの接続 ----------
  function connectEvents() {
    const es = new EventSource('/api/events');
    es.onmessage = (e) => {
      let m; try { m = JSON.parse(e.data); } catch { return; }
      if (m.kind === 'status') onStatus(m);
      else if (m.kind === 'result') onResult(m.data);
      else if (m.kind === 'cleared') clearAll();
    };
    es.onerror = () => {
      setPill('connPill', 'connText', 'off', 'ビューアーと通信できません');
    };
  }

  function setPill(id, textId, cls, text) {
    const el = $(id);
    el.className = 'pill ' + cls;
    $(textId).textContent = text;
  }

  function onStatus(s) {
    st.conn = s;
    if (s.connected) setPill('connPill', 'connText', 'on', 'iPhone 接続中' + (s.device ? '（' + s.device + '）' : ''));
    else setPill('connPill', 'connText', 'off', 'iPhone 未接続');
    if (s.sharing) setPill('sharePill', 'shareText', 'live', 'iPhone で画面共有中');
    else setPill('sharePill', 'shareText', 'off', '画面共有していません');
    $('disconnectBtn').hidden = !s.connected;
    $('connectPanel').hidden = s.connected;
    $('pairCode').textContent = s.code;
    const m = Math.max(0, Math.floor(s.codeExpiresIn / 60)), sec = Math.max(0, s.codeExpiresIn % 60);
    $('codeLeft').textContent = '（あと ' + m + ':' + String(sec).padStart(2, '0') + ' 有効）';
    $('lanInfo').textContent = 'この PC のアドレス: ' + s.lanIP + '（ポート ' + s.port + '）';
    if (s.qrVersion !== st.lastQR) { st.lastQR = s.qrVersion; $('qr').src = '/qr.png?v=' + s.qrVersion; }
  }

  function onResult(m) {
    st.iphone = m;
    useIphoneResult();
  }

  function useIphoneResult() {
    const m = st.iphone;
    if (!m) return;
    st.edited = false;
    $('revertBtn').hidden = true;
    st.status = m.status;
    st.board = { cols: m.cols, rows: m.rows, cells: m.cells.map(S.kindIndex), conf: m.confidence.length ? m.confidence.slice() : m.cells.map(() => 1) };
    st.route = m.status === 'ok' ? {
      start: m.start, end: m.end, path: m.path, moves: m.moves, arrows: m.arrows,
      combos: m.combos, steps: m.steps, elapsedMs: m.elapsedMs, achieved: m.achieved,
      source: m.source === 'iphone-manual' ? 'iPhone で修正した盤面' : 'iPhone の自動解析',
    } : null;
    st.p = st.route ? st.route.moves.length : 0;
    stop();
    renderAll();
  }

  function clearAll() {
    st.iphone = null; st.board = null; st.route = null; st.status = null; st.edited = false;
    stop();
    renderAll();
  }

  // ---------- 再探索（PC 側） ----------
  function goals() {
    return {
      priorityColor: Number($('optColor').value),
      heal: $('gHeal').checked, fiveColors: $('gFive').checked,
      lShape: $('gL').checked, cross: $('gCross').checked, row: $('gRow').checked, square: $('gSquare').checked,
    };
  }

  function resolve() {
    if (!st.board) return;
    if (st.worker) st.worker.terminate();   // 前の探索はキャンセル
    st.worker = new Worker('worker.js');
    const id = ++st.jobId;
    const opts = { maxSteps: Number($('optSteps').value), timeLimitMs: Number($('optTime').value), beamWidth: 2500, goals: goals() };
    $('solveBtn').disabled = true;
    $('solveBtn').textContent = '探索中…';
    st.worker.onmessage = (e) => {
      if (e.data.id !== id) return;
      const r = e.data;
      st.status = r.combos > 0 ? 'ok' : 'nocombo';
      st.route = r.combos > 0 ? { ...r, steps: r.moves.length, source: 'PC で再探索' } : null;
      st.p = st.route ? st.route.moves.length : 0;
      $('solveBtn').disabled = false;
      $('solveBtn').textContent = '再探索';
      stop();
      renderAll();
    };
    st.worker.postMessage({ id, cells: st.board.cells, cols: st.board.cols, rows: st.board.rows, opts });
  }

  // ---------- 描画 ----------
  function spectrum(t) {
    const h = 350 - 92 * t;  // コーラル → バイオレット
    return 'hsl(' + ((h + 360) % 360) + ' 88% 62%)';
  }

  function drawBoard(cv, opts) {
    const b = st.board;
    const ctx = cv.getContext('2d');
    const dpr = window.devicePixelRatio || 1;
    const cols = b ? b.cols : 6, rows = b ? b.rows : 5;
    const cssW = opts.width;
    const cssH = cssW * rows / cols;
    cv.width = Math.round(cssW * dpr); cv.height = Math.round(cssH * dpr);
    cv.style.aspectRatio = cols + ' / ' + rows;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    const cell = cssW / cols;
    ctx.clearRect(0, 0, cssW, cssH);
    for (let r = 0; r < rows; r++) for (let c = 0; c < cols; c++) {
      ctx.fillStyle = (r + c) % 2 ? '#2F3A57' : '#2A3450';
      ctx.fillRect(c * cell, r * cell, cell, cell);
    }
    if (!b) return;

    // ドロップ
    for (let i = 0; i < b.cells.length; i++) {
      const k = b.cells[i], r = Math.floor(i / cols), c = i % cols;
      const cx = (c + 0.5) * cell, cy = (r + 0.5) * cell;
      ctx.beginPath(); ctx.arc(cx, cy, cell * 0.4, 0, Math.PI * 2);
      ctx.fillStyle = ORB[k].fill; ctx.fill();
      ctx.fillStyle = 'rgba(255,255,255,.92)';
      ctx.font = '800 ' + Math.round(cell * 0.3) + 'px system-ui, sans-serif';
      ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
      ctx.fillText(ORB[k].mark, cx, cy + cell * 0.01);
      if (b.conf[i] < 0.5 || k === S.UNKNOWN) {   // 認識に自信がないマス
        ctx.strokeStyle = '#FFD400'; ctx.lineWidth = Math.max(3, cell * 0.06);
        ctx.strokeRect(c * cell + 3, r * cell + 3, cell - 6, cell - 6);
      }
    }

    const rt = st.route;
    if (!rt || !rt.arrows.length) return;
    const n = rt.arrows.length;
    const width = Number($('arrowWidth').value) * cell / 90;
    const colorMode = $('arrowColor').value;
    const showAll = st.p >= n && !st.playing;
    const segColor = (i) => colorMode === 'spectrum' ? spectrum(n > 1 ? i / (n - 1) : 0) : colorMode;

    ctx.lineCap = 'round'; ctx.lineJoin = 'round';
    for (let i = 0; i < n; i++) {
      const [x1, y1, x2, y2] = rt.arrows[i].map(v => v * cell);
      const done = showAll || i < Math.floor(st.p);
      const current = !showAll && i === Math.floor(st.p);
      ctx.globalAlpha = done || current ? 1 : 0.28;
      // 縁取り → 本体
      ctx.strokeStyle = 'rgba(10,14,28,.85)'; ctx.lineWidth = width + 4;
      ctx.beginPath(); ctx.moveTo(x1, y1); ctx.lineTo(x2, y2); ctx.stroke();
      ctx.strokeStyle = segColor(i); ctx.lineWidth = current ? width * 1.5 : width;
      ctx.beginPath(); ctx.moveTo(x1, y1); ctx.lineTo(x2, y2); ctx.stroke();
      drawHead(ctx, x1, y1, x2, y2, width * 2.1, segColor(i));
    }
    ctx.globalAlpha = 1;
    // 手順番号（交差しても順番が分かるように）
    const every = n > 30 ? 2 : 1;
    const rr = Math.max(9, cell * 0.13);
    const placed = [];
    for (let i = 0; i < n; i += every) {
      const [x1, y1, x2, y2] = rt.arrows[i].map(v => v * cell);
      // 番号どうしが重ならない位置を線の上で探す
      let mx = (x1 + x2) / 2, my = (y1 + y2) / 2;
      for (const t of [0.5, 0.3, 0.7, 0.18, 0.82]) {
        const tx = x1 + (x2 - x1) * t, ty = y1 + (y2 - y1) * t;
        if (placed.every(([px, py]) => Math.hypot(px - tx, py - ty) > rr * 1.9)) { mx = tx; my = ty; break; }
      }
      placed.push([mx, my]);
      ctx.beginPath(); ctx.arc(mx, my, rr, 0, Math.PI * 2);
      ctx.fillStyle = '#fff'; ctx.fill();
      ctx.lineWidth = 2; ctx.strokeStyle = segColor(i); ctx.stroke();
      ctx.fillStyle = '#1A2238';
      ctx.font = '800 ' + Math.round(rr * 1.1) + 'px system-ui, sans-serif';
      ctx.fillText(String(i + 1), mx, my + 1);
    }
    // 開始（緑の輪）と終了（四角）
    const sx = ((rt.start % cols) + 0.5) * cell, sy = (Math.floor(rt.start / cols) + 0.5) * cell;
    ctx.lineWidth = Math.max(4, cell * 0.08); ctx.strokeStyle = '#2BD48F';
    ctx.beginPath(); ctx.arc(sx, sy, cell * 0.46, 0, Math.PI * 2); ctx.stroke();
    const [, , ex, ey] = rt.arrows[n - 1].map(v => v * cell);
    const es = cell * 0.17;
    ctx.fillStyle = '#fff'; ctx.strokeStyle = '#1A2238'; ctx.lineWidth = 3;
    ctx.fillRect(ex - es, ey - es, es * 2, es * 2); ctx.strokeRect(ex - es, ey - es, es * 2, es * 2);
    ctx.fillStyle = '#1A2238'; ctx.font = '900 ' + Math.round(es * 1.3) + 'px system-ui'; ctx.fillText('終', ex, ey + 1);
    // 再生中の指の位置
    if (!showAll) {
      const k = Math.min(n - 1, Math.floor(st.p)), f = Math.min(1, st.p - k);
      const [x1, y1, x2, y2] = rt.arrows[k].map(v => v * cell);
      const fx = st.p >= n ? x2 : x1 + (x2 - x1) * f, fy = st.p >= n ? y2 : y1 + (y2 - y1) * f;
      ctx.beginPath(); ctx.arc(fx, fy, cell * 0.2, 0, Math.PI * 2);
      ctx.fillStyle = 'rgba(255,255,255,.95)'; ctx.fill();
      ctx.lineWidth = 4; ctx.strokeStyle = '#1A2238'; ctx.stroke();
    }
  }

  function drawHead(ctx, x1, y1, x2, y2, size, color) {
    const ang = Math.atan2(y2 - y1, x2 - x1);
    const tx = x1 + (x2 - x1) * 0.72, ty = y1 + (y2 - y1) * 0.72;
    ctx.beginPath();
    ctx.moveTo(tx + size * Math.cos(ang), ty + size * Math.sin(ang));
    ctx.lineTo(tx + size * 0.8 * Math.cos(ang + 2.45), ty + size * 0.8 * Math.sin(ang + 2.45));
    ctx.lineTo(tx + size * 0.8 * Math.cos(ang - 2.45), ty + size * 0.8 * Math.sin(ang - 2.45));
    ctx.closePath();
    ctx.fillStyle = color; ctx.fill();
    ctx.lineWidth = 2; ctx.strokeStyle = 'rgba(10,14,28,.85)'; ctx.stroke();
  }

  const ARROW = { U: '↑', D: '↓', L: '←', R: '→' };

  function renderCallStrip() {
    const rt = st.route, b = st.board;
    const list = $('callMoves');
    list.textContent = '';
    const mini = $('miniStart'), mc = mini.getContext('2d');
    mc.clearRect(0, 0, mini.width, mini.height);
    if (!rt || !b) {
      $('callPos').textContent = '—';
      $('callSummary').textContent = st.status && STATUS_TEXT[st.status] ? STATUS_TEXT[st.status]
        : (st.conn && st.conn.connected ? 'iPhone で画面共有を始めると、ここに手順が出ます' : 'iPhone と接続すると、ここに手順が出ます');
      return;
    }
    const r = Math.floor(rt.start / b.cols), c = rt.start % b.cols;
    $('callPos').textContent = '上から' + (r + 1) + '段目・左から' + (c + 1) + '列目';
    // 小さな盤面で開始位置を示す
    const cw = mini.width / b.cols, ch = mini.height / b.rows;
    for (let i = 0; i < b.cols * b.rows; i++) {
      mc.fillStyle = i === rt.start ? '#2BD48F' : 'rgba(255,255,255,.16)';
      mc.fillRect((i % b.cols) * cw + 1, Math.floor(i / b.cols) * ch + 1, cw - 2, ch - 2);
    }
    const show = Math.max(3, Math.floor(list.clientWidth / 76) - 1);
    const cur = st.playing || st.p < rt.moves.length ? Math.floor(st.p) : -1;
    rt.moves.slice(0, show).forEach((m, i) => {
      const li = document.createElement('li');
      li.textContent = ARROW[m];
      const num = document.createElement('small'); num.textContent = String(i + 1);
      li.prepend(num);
      if (i === cur) li.className = 'now'; else if (cur > i) li.className = 'done';
      list.appendChild(li);
    });
    if (rt.moves.length > show) {
      const li = document.createElement('li'); li.className = 'more';
      li.textContent = 'ほか ' + (rt.moves.length - show) + ' 手';
      list.appendChild(li);
    }
    $('callSummary').innerHTML = '';
    const strong = document.createElement('strong'); strong.textContent = rt.combos;
    $('callSummary').append(strong, ' コンボ ・ ' + rt.moves.length + ' 手で見つかった候補');
  }

  function renderStats() {
    const rt = st.route, b = st.board;
    $('statCombo').textContent = rt ? rt.combos : '—';
    $('statSteps').textContent = rt ? rt.moves.length + ' 手' : '—';
    $('statTime').textContent = rt ? (rt.elapsedMs / 1000).toFixed(1) + ' 秒' : '—';
    if (b) {
      const avg = b.conf.reduce((a, v) => a + v, 0) / b.conf.length;
      const low = b.conf.filter(v => v < 0.5).length;
      $('statConf').textContent = Math.round(avg * 100) + '%';
      $('statConf').title = '自信がないマス: ' + low;
      const unk = b.cells.filter(k => k === S.UNKNOWN).length;
      $('warnUnknown').hidden = unk === 0;
      $('warnUnknown').textContent = '不明なマスが ' + unk + ' 個あります。盤面のマスをクリックして色を直してください。';
    } else {
      $('statConf').textContent = '—';
      $('warnUnknown').hidden = true;
    }
    $('statAchieved').textContent = rt && rt.achieved && rt.achieved.length ? '達成：' + rt.achieved.join('、') : '';
    $('statSource').textContent = rt ? '計算：' + rt.source + (st.edited ? '（盤面を手で修正済み）' : '') : '';
    $('stepCount').textContent = (rt ? Math.min(rt.moves.length, Math.floor(st.p)) : 0) + ' / ' + (rt ? rt.moves.length : 0) + ' 手';
    const nt = $('notice');
    if (!rt && st.status && STATUS_TEXT[st.status]) { nt.hidden = false; nt.textContent = STATUS_TEXT[st.status]; }
    else nt.hidden = true;
  }

  function renderAll() {
    const wrap = $('boardWrap');
    const b = st.board;
    const cols = b ? b.cols : 6, rows = b ? b.rows : 5;
    const maxW = wrap.clientWidth - 32;
    const maxH = (document.fullscreenElement === wrap ? window.innerHeight * 0.96 : Math.max(300, window.innerHeight - 330));
    const w = Math.max(200, Math.min(maxW, maxH * cols / rows));
    drawBoard($('board'), { width: w });
    $('board').style.width = w + 'px';
    if (st.pipCanvas) {
      const pw = st.pipCanvas.ownerDocument.defaultView.innerWidth - 8;
      drawBoard(st.pipCanvas, { width: pw });
      st.pipCanvas.style.width = pw + 'px';
    }
    renderCallStrip();
    renderStats();
    $('playBtn').textContent = st.playing ? '⏸ 一時停止' : '▶ 再生';
  }

  // ---------- 再生 ----------
  let raf = 0, last = 0;
  function tick(t) {
    if (!st.playing) return;
    const dt = last ? (t - last) / 1000 : 0;
    last = t;
    const n = st.route ? st.route.moves.length : 0;
    st.p += dt * Number($('speed').value) / 0.55;
    if (st.p >= n) { st.p = n; st.playing = false; }
    renderAll();
    if (st.playing) raf = requestAnimationFrame(tick);
  }
  function play() {
    if (!st.route) return;
    if (st.p >= st.route.moves.length) st.p = 0;
    st.playing = true; last = 0;
    cancelAnimationFrame(raf); raf = requestAnimationFrame(tick);
    renderAll();
  }
  function stop() { st.playing = false; cancelAnimationFrame(raf); }
  function step(d) {
    if (!st.route) return;
    stop();
    st.p = Math.max(0, Math.min(st.route.moves.length, Math.floor(st.p) + d));
    renderAll();
  }

  // ---------- 盤面修正 ----------
  function openPalette(ev) {
    if (!st.board) return;
    const cv = $('board');
    const rect = cv.getBoundingClientRect();
    const b = st.board;
    const c = Math.floor((ev.clientX - rect.left) / rect.width * b.cols);
    const r = Math.floor((ev.clientY - rect.top) / rect.height * b.rows);
    if (c < 0 || r < 0 || c >= b.cols || r >= b.rows) return;
    const idx = r * b.cols + c;
    const pal = $('palette');
    pal.textContent = '';
    S.LABELS.forEach((label, k) => {
      const btn = document.createElement('button');
      btn.type = 'button';
      btn.style.background = ORB[k].fill;
      btn.textContent = label;
      btn.setAttribute('aria-pressed', String(b.cells[idx] === k));
      btn.addEventListener('click', () => {
        b.cells[idx] = k; b.conf[idx] = 1;
        st.edited = true; $('revertBtn').hidden = !st.iphone;
        pal.hidden = true;
        resolve();
      });
      pal.appendChild(btn);
    });
    const wrapRect = $('boardWrap').getBoundingClientRect();
    pal.hidden = false;
    const px = Math.min(ev.clientX - wrapRect.left, wrapRect.width - pal.offsetWidth - 8);
    const py = Math.min(ev.clientY - wrapRect.top + 10, wrapRect.height - pal.offsetHeight - 8);
    pal.style.left = Math.max(8, px) + 'px';
    pal.style.top = Math.max(8, py) + 'px';
    pal.querySelector('button').focus();
  }

  // ---------- 小窓（常に手前） ----------
  async function openPiP() {
    if (!('documentPictureInPicture' in window)) {
      alert('このブラウザは小窓表示に対応していません。Chrome または Edge の最新版を使うか、下の「常に手前に表示するには」をご覧ください。');
      return;
    }
    const win = await window.documentPictureInPicture.requestWindow({ width: 420, height: 380 });
    win.document.body.style.cssText = 'margin:0;background:#26304A;display:grid;place-items:center;';
    const cv = win.document.createElement('canvas');
    win.document.body.appendChild(cv);
    st.pipCanvas = cv;
    win.addEventListener('pagehide', () => { st.pipCanvas = null; });
    win.addEventListener('resize', renderAll);
    renderAll();
  }

  // ---------- イベント ----------
  $('playBtn').addEventListener('click', () => (st.playing ? (stop(), renderAll()) : play()));
  $('resetBtn').addEventListener('click', () => { stop(); st.p = 0; renderAll(); });
  $('backBtn').addEventListener('click', () => step(-1));
  $('fwdBtn').addEventListener('click', () => step(1));
  ['arrowWidth', 'arrowColor', 'speed'].forEach(id => $(id).addEventListener('input', renderAll));
  $('fullBtn').addEventListener('click', () => {
    if (document.fullscreenElement) document.exitFullscreen();
    else $('boardWrap').requestFullscreen().catch(() => {});
  });
  document.addEventListener('fullscreenchange', renderAll);
  $('pipBtn').addEventListener('click', openPiP);
  $('board').addEventListener('click', openPalette);
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') $('palette').hidden = true;
    if (e.target instanceof HTMLInputElement || e.target instanceof HTMLSelectElement) return;
    if (e.key === ' ') { e.preventDefault(); st.playing ? (stop(), renderAll()) : play(); }
    if (e.key === 'ArrowRight') step(1);
    if (e.key === 'ArrowLeft') step(-1);
  });
  $('solveBtn').addEventListener('click', resolve);
  $('revertBtn').addEventListener('click', useIphoneResult);
  $('disconnectBtn').addEventListener('click', () => fetch('/api/disconnect', { method: 'POST' }));
  $('rotateBtn').addEventListener('click', () => fetch('/api/rotate', { method: 'POST' }));
  window.addEventListener('resize', renderAll);

  renderAll();
  connectEvents();
})();
