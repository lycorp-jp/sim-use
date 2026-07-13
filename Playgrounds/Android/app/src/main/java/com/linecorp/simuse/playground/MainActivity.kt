// SPDX-License-Identifier: Apache-2.0
package com.linecorp.simuse.playground

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.text.Editable
import android.text.TextWatcher
import android.view.Gravity
import android.view.GestureDetector
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.InputMethodManager
import android.widget.Button
import android.widget.EditText
import android.widget.TextView
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import java.util.Locale
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.hypot

/**
 * Single-activity, deterministic-UI test fixture for the sim-use Android
 * E2E suites. Each screen exposes stable `android:id` short-names that
 * sim-use surfaces as `#<id>` selectors, and every interaction updates a
 * plain-text echo label so a describe-ui read can assert the effect of a
 * command.
 *
 * Screens are selected by intent extra:
 *   adb shell am start -n com.linecorp.simuse.playground/.MainActivity \
 *       -e screen tap-test
 * or from the in-app menu (each item id `menu_<screen>` with `_` in place
 * of the `-` that Android resource names forbid).
 */
class MainActivity : Activity() {

    private lateinit var container: ViewGroup
    private var currentScreen: String = SCREEN_MENU

    // Per-screen counters. Reset whenever the owning screen is (re)shown,
    // so a fresh `am start` always lands on a clean slate.
    private var tapCount = 0
    private var longPressCount = 0
    private var swipeCount = 0
    private var backPressCount = 0

    // Row ids are pre-declared in res/values/ids.xml so the 100 static
    // scroll rows expose `row_1`..`row_100` short-names in describe-ui.
    private val rowIds: List<Int> by lazy {
        (1..ROW_COUNT).map { resources.getIdentifier("row_$it", "id", packageName) }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        container = findViewById(R.id.screen_container)
        render(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // Persist the new intent so a singleTop re-launch that targets a
        // different screen is honoured on the next render().
        setIntent(intent)
        render(intent)
    }

    override fun onBackPressed() {
        // The button-test screen counts hardware Back presses instead of
        // finishing, so `sim-use button back` has an observable effect.
        if (currentScreen == SCREEN_BUTTON) {
            backPressCount++
            findViewById<TextView?>(R.id.back_press_count)?.text =
                getString(R.string.fmt_back_presses, backPressCount)
            return
        }
        @Suppress("DEPRECATION")
        super.onBackPressed()
    }

    private fun render(intent: Intent?) {
        val requested = intent?.getStringExtra(EXTRA_SCREEN)
        showScreen(normalize(requested))
    }

    /** Accept the `-` canonical names and the `_` menu-id variants alike. */
    private fun normalize(name: String?): String {
        val canonical = name?.trim()?.replace('_', '-')
        return when (canonical) {
            SCREEN_TAP, SCREEN_SWIPE, SCREEN_SCROLL,
            SCREEN_TEXT, SCREEN_MULTI, SCREEN_BUTTON -> canonical
            else -> SCREEN_MENU
        }
    }

    private fun showScreen(name: String) {
        currentScreen = name
        container.removeAllViews()
        val layout = when (name) {
            SCREEN_TAP -> R.layout.screen_tap
            SCREEN_SWIPE -> R.layout.screen_swipe
            SCREEN_SCROLL -> R.layout.screen_scroll
            SCREEN_TEXT -> R.layout.screen_text
            SCREEN_MULTI -> R.layout.screen_multitouch
            SCREEN_BUTTON -> R.layout.screen_button
            else -> R.layout.screen_menu
        }
        val root = layoutInflater.inflate(layout, container, false)
        container.addView(root)
        when (name) {
            SCREEN_MENU -> setupMenu(root)
            SCREEN_TAP -> setupTapScreen(root)
            SCREEN_SWIPE -> setupSwipeScreen(root)
            SCREEN_SCROLL -> setupScrollScreen(root)
            SCREEN_TEXT -> setupTextScreen(root)
            SCREEN_MULTI -> setupMultiTouchScreen(root)
            SCREEN_BUTTON -> setupButtonScreen(root)
        }
    }

    private fun setupMenu(root: View) {
        val screens = mapOf(
            R.id.menu_tap_test to SCREEN_TAP,
            R.id.menu_swipe_test to SCREEN_SWIPE,
            R.id.menu_scroll_test to SCREEN_SCROLL,
            R.id.menu_text_input to SCREEN_TEXT,
            R.id.menu_multi_touch to SCREEN_MULTI,
            R.id.menu_button_test to SCREEN_BUTTON,
        )
        for ((id, screen) in screens) {
            root.findViewById<Button>(id).setOnClickListener { showScreen(screen) }
        }
    }

    @SuppressLint("ClickableViewAccessibility")
    private fun setupTapScreen(root: View) {
        tapCount = 0
        longPressCount = 0
        val tapCountView = root.findViewById<TextView>(R.id.tap_count)
        val tapCoords = root.findViewById<TextView>(R.id.last_tap_coordinates)
        val longPressCountView = root.findViewById<TextView>(R.id.long_press_count)
        val longPressCoords = root.findViewById<TextView>(R.id.last_long_press_coordinates)
        val area = root.findViewById<View>(R.id.tap_test_area)

        val detector = GestureDetector(this, object : GestureDetector.SimpleOnGestureListener() {
            override fun onDown(e: MotionEvent): Boolean = true

            override fun onSingleTapUp(e: MotionEvent): Boolean {
                tapCount++
                tapCountView.text = getString(R.string.fmt_taps, tapCount)
                tapCoords.text = getString(R.string.fmt_tap, e.rawX.toInt(), e.rawY.toInt())
                return true
            }

            override fun onLongPress(e: MotionEvent) {
                longPressCount++
                longPressCountView.text = getString(R.string.fmt_long_presses, longPressCount)
                longPressCoords.text = getString(R.string.fmt_long_press, e.rawX.toInt(), e.rawY.toInt())
            }
        })
        area.setOnTouchListener { _, e -> detector.onTouchEvent(e) }
    }

    @SuppressLint("ClickableViewAccessibility")
    private fun setupSwipeScreen(root: View) {
        swipeCount = 0
        val countView = root.findViewById<TextView>(R.id.swipe_count)
        val directionView = root.findViewById<TextView>(R.id.last_swipe_direction)
        val distanceView = root.findViewById<TextView>(R.id.last_swipe_distance)
        val area = root.findViewById<View>(R.id.swipe_test_area)

        var downX = 0f
        var downY = 0f
        area.setOnTouchListener { _, e ->
            when (e.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downX = e.rawX
                    downY = e.rawY
                }
                MotionEvent.ACTION_UP -> {
                    val dx = e.rawX - downX
                    val dy = e.rawY - downY
                    if (hypot(dx, dy) >= SWIPE_MIN_DISTANCE) {
                        swipeCount++
                        val horizontal = abs(dx) > abs(dy)
                        val direction = when {
                            horizontal && dx > 0 -> "right"
                            horizontal -> "left"
                            dy > 0 -> "down"
                            else -> "up"
                        }
                        val distance = (if (horizontal) abs(dx) else abs(dy)).toInt()
                        countView.text = getString(R.string.fmt_swipes, swipeCount)
                        directionView.text = getString(R.string.fmt_direction, direction)
                        distanceView.text = getString(R.string.fmt_distance, distance)
                    }
                }
            }
            true
        }
    }

    private fun setupScrollScreen(root: View) {
        val list = root.findViewById<RecyclerView>(R.id.scroll_list)
        val topLabel = root.findViewById<TextView>(R.id.first_visible_row)
        val rowHeight = (ROW_HEIGHT_DP * resources.displayMetrics.density).toInt()

        // Lay out a screenful of extra rows above and below the viewport so
        // RecyclerView keeps them attached (but off-screen) in the a11y
        // tree — that is precisely the population `describe-ui
        // --include-offscreen` surfaces beyond the strictly-visible cells.
        val extraSpace = resources.displayMetrics.heightPixels
        val layoutManager = object : LinearLayoutManager(this) {
            override fun calculateExtraLayoutSpace(state: RecyclerView.State, extraLayoutSpace: IntArray) {
                extraLayoutSpace[0] = extraSpace
                extraLayoutSpace[1] = extraSpace
            }
        }
        list.layoutManager = layoutManager
        list.adapter = RowAdapter(rowIds, rowHeight)

        topLabel.text = getString(R.string.fmt_top_row, 1)
        list.addOnScrollListener(object : RecyclerView.OnScrollListener() {
            override fun onScrolled(recyclerView: RecyclerView, dx: Int, dy: Int) {
                val first = layoutManager.findFirstVisibleItemPosition()
                if (first != RecyclerView.NO_POSITION) {
                    topLabel.text = getString(R.string.fmt_top_row, first + 1)
                }
            }
        })
    }

    /** 100 numbered rows. Each bound view takes the pre-declared
     *  `row_<position+1>` id so describe-ui exposes stable `row_N`
     *  short-names even as RecyclerView recycles the underlying views. */
    private class RowAdapter(
        private val rowIds: List<Int>,
        private val rowHeightPx: Int,
    ) : RecyclerView.Adapter<RowAdapter.RowHolder>() {

        class RowHolder(val textView: TextView) : RecyclerView.ViewHolder(textView)

        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): RowHolder {
            val ctx = parent.context
            val tv = TextView(ctx)
            tv.layoutParams = ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, rowHeightPx)
            tv.textSize = 16f
            tv.gravity = Gravity.CENTER_VERTICAL
            val pad = (16 * ctx.resources.displayMetrics.density).toInt()
            tv.setPadding(pad, 0, pad, 0)
            tv.importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_YES
            return RowHolder(tv)
        }

        override fun onBindViewHolder(holder: RowHolder, position: Int) {
            holder.textView.id = rowIds[position]
            holder.textView.text = holder.textView.context.getString(R.string.fmt_row, position + 1)
        }

        override fun getItemCount(): Int = rowIds.size
    }

    private fun setupTextScreen(root: View) {
        val field = root.findViewById<EditText>(R.id.text_input_field)
        val charCount = root.findViewById<TextView>(R.id.char_count)
        val echo = root.findViewById<TextView>(R.id.text_echo)
        val focusButton = root.findViewById<Button>(R.id.focus_button)
        val unfocusButton = root.findViewById<Button>(R.id.unfocus_button)

        // Let the root take focus on unfocus so the sole EditText does not
        // immediately reclaim it (which would keep the IME up).
        (root as? ViewGroup)?.apply {
            isFocusableInTouchMode = true
            descendantFocusability = ViewGroup.FOCUS_AFTER_DESCENDANTS
        }

        field.setText("")
        field.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {}
            override fun afterTextChanged(s: Editable?) {
                val text = s?.toString() ?: ""
                charCount.text = getString(R.string.fmt_chars, text.length)
                echo.text = getString(R.string.fmt_echo, text)
            }
        })

        val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
        focusButton.setOnClickListener {
            field.requestFocus()
            field.setSelection(field.text.length)
            imm.showSoftInput(field, InputMethodManager.SHOW_IMPLICIT)
        }
        unfocusButton.setOnClickListener {
            imm.hideSoftInputFromWindow(field.windowToken, 0)
            field.clearFocus()
            root.requestFocus()
        }
    }

    @SuppressLint("ClickableViewAccessibility")
    private fun setupMultiTouchScreen(root: View) {
        val scaleView = root.findViewById<TextView>(R.id.pinch_scale)
        val rotationView = root.findViewById<TextView>(R.id.rotation_angle)
        val pointerView = root.findViewById<TextView>(R.id.pointer_count_max)
        val area = root.findViewById<View>(R.id.multi_touch_area)

        var cumulativeScale = 1f
        var cumulativeRotation = 0f
        var maxPointers = 0
        var previousAngle = 0f

        val scaleDetector = ScaleGestureDetector(this, object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
            override fun onScaleBegin(detector: ScaleGestureDetector): Boolean {
                cumulativeScale = 1f
                return true
            }

            override fun onScale(detector: ScaleGestureDetector): Boolean {
                cumulativeScale *= detector.scaleFactor
                scaleView.text = getString(
                    R.string.fmt_scale,
                    String.format(Locale.US, "%.2f", cumulativeScale)
                )
                return true
            }
        })

        area.setOnTouchListener { _, e ->
            scaleDetector.onTouchEvent(e)
            if (e.pointerCount > maxPointers) {
                maxPointers = e.pointerCount
                pointerView.text = getString(R.string.fmt_pointers, maxPointers)
            }
            if (e.pointerCount >= 2) {
                val angle = Math.toDegrees(
                    atan2((e.getY(1) - e.getY(0)).toDouble(), (e.getX(1) - e.getX(0)).toDouble())
                ).toFloat()
                when (e.actionMasked) {
                    MotionEvent.ACTION_POINTER_DOWN -> previousAngle = angle
                    MotionEvent.ACTION_MOVE -> {
                        var delta = angle - previousAngle
                        if (delta > 180f) delta -= 360f
                        if (delta < -180f) delta += 360f
                        cumulativeRotation += delta
                        previousAngle = angle
                        rotationView.text = getString(R.string.fmt_rotation, cumulativeRotation.toInt())
                    }
                }
            }
            true
        }
    }

    private fun setupButtonScreen(root: View) {
        backPressCount = 0
        root.findViewById<TextView>(R.id.back_press_count).text =
            getString(R.string.fmt_back_presses, backPressCount)
    }

    companion object {
        private const val EXTRA_SCREEN = "screen"

        private const val SCREEN_MENU = "menu"
        private const val SCREEN_TAP = "tap-test"
        private const val SCREEN_SWIPE = "swipe-test"
        private const val SCREEN_SCROLL = "scroll-test"
        private const val SCREEN_TEXT = "text-input"
        private const val SCREEN_MULTI = "multi-touch"
        private const val SCREEN_BUTTON = "button-test"

        private const val ROW_COUNT = 100
        private const val ROW_HEIGHT_DP = 56
        private const val SWIPE_MIN_DISTANCE = 40f
    }
}
