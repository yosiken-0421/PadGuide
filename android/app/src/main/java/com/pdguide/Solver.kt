package com.pdguide

/**
 * ビームサーチによるパズル経路探索。
 * 落ちコンは考慮せず（盤面上のドロップだけで）コンボ数を最大化し、同コンボなら手数の少ない経路を選ぶ。
 */
class Solver(
    private val maxSteps: Int,
    private val diagonal: Boolean,
    private val beamWidth: Int,
) {
    class Result(
        val path: IntArray,      // 通過するマスのindex（先頭が開始位置）
        val combos: Int,
        val cleared: Int,
        val maxCombos: Int,
    ) {
        val steps get() = path.size - 1
    }

    private class Node(
        val board: ByteArray,
        val pos: Int,
        val prev: Int,
        val parent: Node?,
        val depth: Int,
        val combos: Int,
        val cleared: Int,
        val score: Int,
    )

    private val dirs: Array<IntArray> = if (diagonal)
        arrayOf(intArrayOf(-1, 0), intArrayOf(1, 0), intArrayOf(0, -1), intArrayOf(0, 1),
            intArrayOf(-1, -1), intArrayOf(-1, 1), intArrayOf(1, -1), intArrayOf(1, 1))
    else
        arrayOf(intArrayOf(-1, 0), intArrayOf(1, 0), intArrayOf(0, -1), intArrayOf(0, 1))

    fun solve(board: ByteArray): Result {
        val maxCombos = theoreticalMax(board)
        val ev0 = evaluate(board)
        var best: Node? = null
        var beam = ArrayList<Node>(Orb.CELLS)
        for (p in 0 until Orb.CELLS) {
            beam.add(Node(board, p, -1, null, 0, ev0[0], ev0[1], score(board, ev0, 0)))
        }

        for (depth in 1..maxSteps) {
            val children = ArrayList<Node>(beam.size * dirs.size)
            val seen = HashSet<Long>(beam.size * dirs.size * 2)
            for (n in beam) {
                val r = n.pos / Orb.COLS
                val c = n.pos % Orb.COLS
                for (d in dirs) {
                    val nr = r + d[0]
                    val nc = c + d[1]
                    if (nr < 0 || nr >= Orb.ROWS || nc < 0 || nc >= Orb.COLS) continue
                    val np = nr * Orb.COLS + nc
                    if (np == n.prev) continue
                    val b = n.board.copyOf()
                    val t = b[n.pos]; b[n.pos] = b[np]; b[np] = t
                    val key = (b.contentHashCode().toLong() shl 8) or np.toLong()
                    if (!seen.add(key)) continue
                    val ev = evaluate(b)
                    val child = Node(b, np, n.pos, n, depth, ev[0], ev[1], score(b, ev, depth))
                    children.add(child)
                    if (best == null || better(child, best)) best = child
                }
            }
            if (children.isEmpty()) break
            children.sortByDescending { it.score }
            beam = if (children.size > beamWidth) ArrayList(children.subList(0, beamWidth)) else children
            val b = best
            if (b != null && b.combos >= maxCombos) break // 理論最大に到達
        }

        val b = best ?: return Result(intArrayOf(0), ev0[0], ev0[1], maxCombos)
        val list = ArrayList<Int>()
        var cur: Node? = b
        while (cur != null) { list.add(cur.pos); cur = cur.parent }
        list.reverse()
        return Result(list.toIntArray(), b.combos, b.cleared, maxCombos)
    }

    private fun better(a: Node, b: Node): Boolean {
        if (a.combos != b.combos) return a.combos > b.combos
        if (a.depth != b.depth) return a.depth < b.depth
        return a.cleared > b.cleared
    }

    /** ビーム内の並び順用スコア。コンボ最優先、次に「2個並び」を少し評価して探索を誘導 */
    private fun score(b: ByteArray, ev: IntArray, depth: Int): Int {
        var pairs = 0
        for (r in 0 until Orb.ROWS) for (c in 0 until Orb.COLS) {
            val v = b[r * Orb.COLS + c]
            if (v < 0 || v >= Orb.OTHER) continue
            if (c + 1 < Orb.COLS && b[r * Orb.COLS + c + 1] == v) pairs++
            if (r + 1 < Orb.ROWS && b[(r + 1) * Orb.COLS + c] == v) pairs++
        }
        return ev[0] * 1000 + ev[1] * 10 + pairs * 4 - depth
    }

    companion object {
        /** 各色 floor(個数/3) の合計 */
        fun theoreticalMax(board: ByteArray): Int {
            val cnt = IntArray(6)
            for (v in board) if (v in 0..5) cnt[v.toInt()]++
            return cnt.sumOf { it / 3 }
        }

        /** [コンボ数, 消したドロップ数]。落ちコンなし・連鎖（上から落ちてくる既存ドロップ）は考慮 */
        fun evaluate(src: ByteArray): IntArray {
            val g = src.copyOf()
            var combos = 0
            var cleared = 0
            val mark = BooleanArray(Orb.CELLS)
            val visited = BooleanArray(Orb.CELLS)
            val stack = IntArray(Orb.CELLS)
            while (true) {
                java.util.Arrays.fill(mark, false)
                var any = false
                for (r in 0 until Orb.ROWS) for (c in 0..Orb.COLS - 3) {
                    val i = r * Orb.COLS + c
                    val v = g[i]
                    if (v in 0..5 && g[i + 1] == v && g[i + 2] == v) {
                        mark[i] = true; mark[i + 1] = true; mark[i + 2] = true; any = true
                    }
                }
                for (r in 0..Orb.ROWS - 3) for (c in 0 until Orb.COLS) {
                    val i = r * Orb.COLS + c
                    val v = g[i]
                    if (v in 0..5 && g[i + Orb.COLS] == v && g[i + 2 * Orb.COLS] == v) {
                        mark[i] = true; mark[i + Orb.COLS] = true; mark[i + 2 * Orb.COLS] = true; any = true
                    }
                }
                if (!any) break
                java.util.Arrays.fill(visited, false)
                for (i in 0 until Orb.CELLS) {
                    if (!mark[i] || visited[i]) continue
                    val color = g[i]
                    combos++
                    var sp = 0
                    stack[sp++] = i
                    visited[i] = true
                    while (sp > 0) {
                        val p = stack[--sp]
                        cleared++
                        val pr = p / Orb.COLS
                        val pc = p % Orb.COLS
                        if (pr > 0) { val q = p - Orb.COLS; if (mark[q] && !visited[q] && g[q] == color) { visited[q] = true; stack[sp++] = q } }
                        if (pr < Orb.ROWS - 1) { val q = p + Orb.COLS; if (mark[q] && !visited[q] && g[q] == color) { visited[q] = true; stack[sp++] = q } }
                        if (pc > 0) { val q = p - 1; if (mark[q] && !visited[q] && g[q] == color) { visited[q] = true; stack[sp++] = q } }
                        if (pc < Orb.COLS - 1) { val q = p + 1; if (mark[q] && !visited[q] && g[q] == color) { visited[q] = true; stack[sp++] = q } }
                    }
                }
                for (i in 0 until Orb.CELLS) if (mark[i]) g[i] = Orb.EMPTY
                // 重力で落とす
                for (c in 0 until Orb.COLS) {
                    var w = Orb.ROWS - 1
                    for (r in Orb.ROWS - 1 downTo 0) {
                        val v = g[r * Orb.COLS + c]
                        if (v != Orb.EMPTY) { g[w * Orb.COLS + c] = v; w-- }
                    }
                    while (w >= 0) { g[w * Orb.COLS + c] = Orb.EMPTY; w-- }
                }
            }
            return intArrayOf(combos, cleared)
        }
    }
}
