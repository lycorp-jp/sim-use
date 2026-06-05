// SPDX-License-Identifier: Apache-2.0
package com.linecorp.simuse.devicebridge.handler

import android.graphics.Rect
import android.os.Build
import android.os.SystemClock
import android.util.Log
import android.view.accessibility.AccessibilityNodeInfo
import com.linecorp.simuse.devicebridge.model.ElementNode
import java.util.concurrent.Executors
import java.util.concurrent.ForkJoinPool
import java.util.concurrent.RecursiveTask

/**
 * Build the full P0+P1 a11y tree from an AccessibilityNodeInfo root.
 *
 * Replicates csat's `TreeHandler` shape but emits a richer schema and
 * returns an inline `JSONObject` (not a JSON-encoded string) so the
 * envelope can carry it as inline JSON per our wire spec.
 *
 * `safeRecycle` follows csat: we recycle every borrowed node, even on
 * API 33+ where it's a no-op, to keep the path identical across SDKs.
 */
class TreeHandler {

    fun buildTree(root: AccessibilityNodeInfo?, filter: Boolean): ElementNode? {
        if (root == null) return null
        val t0 = SystemClock.elapsedRealtime()
        nodeCount.set(0)
        try {
            // Walk the root's children in parallel via ForkJoinPool —
            // each `getChild()` is an independent Binder IPC to
            // system_server, which can serve them concurrently. On a
            // cold (post-window-change) tree of 380 nodes this drops
            // total walk time from ~2s to ~0.3s on emulator-5554.
            // The root itself is walked single-threaded (cheap) so we
            // can recycle it deterministically.
            val built = forkJoinPool.invoke(BuildTask(root, filter))
            val t1 = SystemClock.elapsedRealtime()
            Log.i(TAG, "buildTree: nodes=${nodeCount.get()}  total=${t1 - t0}ms  parallel=true")
            return built
        } finally {
            safeRecycle(root)
        }
    }

    private val nodeCount = java.util.concurrent.atomic.AtomicInteger(0)

    private inner class BuildTask(
        private val info: AccessibilityNodeInfo,
        private val filter: Boolean,
    ) : RecursiveTask<ElementNode?>() {
        override fun compute(): ElementNode? {
            nodeCount.incrementAndGet()
            val bounds = Rect().also(info::getBoundsInScreen)
            // Fork all child fetches in parallel. `getChild(i)` Binder
            // calls dispatch concurrently; the framework parallelizes
            // them across system_server threads.
            //
            // Ownership: each `getChild(i)` returns a borrowed node we
            // own and must recycle. If `getChild` throws partway
            // through the loop (rare Binder transient), the children
            // already collected in `tasks` would leak. Catch the
            // throw, recycle every child we've gathered so far, then
            // re-throw so the caller sees the original failure.
            val tasks = ArrayList<Pair<BuildTask, AccessibilityNodeInfo>>(info.childCount)
            try {
                for (i in 0 until info.childCount) {
                    val child = info.getChild(i) ?: continue
                    val task = BuildTask(child, filter)
                    task.fork()
                    tasks.add(task to child)
                }
            } catch (e: Throwable) {
                for ((_, leakedChild) in tasks) {
                    safeRecycle(leakedChild)
                }
                throw e
            }
            val children = ArrayList<ElementNode>(tasks.size)
            for ((task, child) in tasks) {
                try {
                    val built = task.join()
                    if (built != null) children.add(built)
                } finally {
                    safeRecycle(child)
                }
            }
            if (filter && bounds.isEmpty() && children.isEmpty()) return null
            return ElementNode(
                resourceId = info.viewIdResourceName ?: "",
                uniqueId = uniqueIdCompat(info),
                packageName = info.packageName?.toString() ?: "",
                className = info.className?.toString() ?: "",
                text = info.text?.toString() ?: "",
                contentDescription = info.contentDescription?.toString() ?: "",
                hintText = hintTextCompat(info),
                stateDescription = stateDescriptionCompat(info),
                boundsInScreen = bounds,
                clickable = info.isClickable,
                longClickable = info.isLongClickable,
                scrollable = info.isScrollable,
                focusable = info.isFocusable,
                focused = info.isFocused,
                enabled = info.isEnabled,
                checkable = info.isCheckable,
                checked = info.isChecked,
                selected = info.isSelected,
                password = info.isPassword,
                visibleToUser = info.isVisibleToUser,
                collectionInfo = info.collectionInfo?.let {
                    ElementNode.CollectionInfo(
                        rowCount = it.rowCount,
                        columnCount = it.columnCount,
                        itemCount = -1,
                        isHierarchical = it.isHierarchical,
                    )
                },
                collectionItemInfo = info.collectionItemInfo?.let {
                    ElementNode.CollectionItemInfo(
                        rowIndex = it.rowIndex,
                        columnIndex = it.columnIndex,
                        rowSpan = it.rowSpan,
                        columnSpan = it.columnSpan,
                        isHeading = it.isHeading,
                    )
                },
                children = children,
            )
        }
    }

    private fun Rect.isEmpty(): Boolean = width() <= 0 || height() <= 0

    private fun uniqueIdCompat(info: AccessibilityNodeInfo): String? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) info.uniqueId else null

    private fun hintTextCompat(info: AccessibilityNodeInfo): String? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) info.hintText?.toString() else null

    private fun stateDescriptionCompat(info: AccessibilityNodeInfo): String? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) info.stateDescription?.toString() else null

    companion object {
        private const val TAG = "SimuseTreeHandler"

        // ForkJoinPool sized to a multiple of CPU cores. The bottleneck
        // is Binder IPC latency, not CPU, so oversubscribing helps —
        // each thread blocks on `getChild`, and the framework's
        // system_server can answer multiple in parallel.
        //
        // Lifetime: `by lazy` makes the pool survive the
        // AccessibilityService's restart cycle (good for warmth — a
        // re-bind doesn't pay the pool startup cost) AND survive
        // bad state across restarts (potentially-not-great if a
        // worker is wedged on a Binder call against the dead
        // service). In practice the framework reaps the workers
        // when the service goes away because `getChild` throws on
        // a stale `AccessibilityNodeInfo`, so wedged state hasn't
        // shown up in practice. Documented here so a future agent
        // doesn't try to "fix" the lazy without understanding the
        // restart trade-off.
        private val forkJoinPool: ForkJoinPool by lazy {
            val parallelism = (Runtime.getRuntime().availableProcessors() * 4).coerceAtMost(32)
            ForkJoinPool(parallelism)
        }
    }

    @Suppress("DEPRECATION")
    private fun safeRecycle(node: AccessibilityNodeInfo) {
        try {
            node.recycle()
        } catch (_: Exception) {
            // recycle() is a no-op on API 33+ and may throw if the node
            // has already been recycled. csat swallows both.
        }
    }
}