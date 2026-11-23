package com.freescanner.free_scanner

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.pdf.PdfRenderer
import android.os.Build
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.view.GestureDetector
import android.view.Gravity
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.TextView
import java.io.File
import kotlin.math.max
import kotlin.math.min

class PdfViewerActivity : Activity() {
    private val pageBitmaps = mutableListOf<Bitmap>()
    private lateinit var root: FrameLayout

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        actionBar?.hide()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.setDecorFitsSystemWindows(true)
        }
        window.statusBarColor = Color.WHITE
        window.navigationBarColor = Color.rgb(245, 246, 248)
        window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR

        root = FrameLayout(this).apply {
            setBackgroundColor(Color.rgb(245, 246, 248))
        }
        val backButton = TextView(this).apply {
            text = "←"
            textSize = 24f
            gravity = Gravity.CENTER
            setTextColor(Color.rgb(30, 35, 40))
            setBackgroundColor(Color.WHITE)
            contentDescription = "Back"
            isClickable = true
            isFocusable = true
            elevation = dp(4).toFloat()
            setOnClickListener { finish() }
        }
        root.addView(backButton, FrameLayout.LayoutParams(dp(48), dp(48), Gravity.TOP or Gravity.START).apply {
            leftMargin = dp(12)
            topMargin = dp(12)
        })
        setContentView(root)

        try {
            val file = File(intent.getStringExtra("path") ?: error("Missing PDF"))
            ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor ->
                PdfRenderer(descriptor).use { renderer ->
                    val targetWidth = (resources.displayMetrics.widthPixels - dp(24))
                        .coerceAtLeast(dp(240)).coerceAtMost(1800)
                    for (index in 0 until renderer.pageCount) {
                        renderer.openPage(index).use { page ->
                            val height = (targetWidth * page.height.toFloat() / page.width)
                                .toInt().coerceAtLeast(1)
                            val bitmap = Bitmap.createBitmap(targetWidth, height, Bitmap.Config.ARGB_8888)
                            bitmap.eraseColor(Color.WHITE)
                            page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                            pageBitmaps.add(bitmap)
                        }
                    }
                }
            }
            val canvasView = DocumentCanvasView(this, pageBitmaps)
            root.addView(canvasView, 0, FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        } catch (_: Exception) {
            root.addView(TextView(this).apply {
                text = "This PDF could not be opened."
                textSize = 16f
                setTextColor(Color.DKGRAY)
                gravity = Gravity.CENTER
                setPadding(dp(20), dp(28), dp(20), dp(20))
            }, 0, FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        }
    }

    override fun onDestroy() {
        pageBitmaps.forEach { if (!it.isRecycled) it.recycle() }
        pageBitmaps.clear()
        super.onDestroy()
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    private class DocumentCanvasView(
        activity: Activity,
        private val pages: List<Bitmap>,
    ) : View(activity) {
        private val paint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
        private var scale = 1f
        private var fitScale = 1f
        private var offsetX = 0f
        private var offsetY = 0f
        private var lastX = 0f
        private var lastY = 0f
        private var initialized = false
        private val gapPx = dp(activity, 16).toFloat()

        private val scaleDetector = ScaleGestureDetector(context,
            object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
                override fun onScale(detector: ScaleGestureDetector): Boolean {
                    zoomAt(detector.focusX, detector.focusY, detector.scaleFactor)
                    return true
                }
            })

        private val gestureDetector = GestureDetector(context,
            object : GestureDetector.SimpleOnGestureListener() {
                override fun onDown(event: MotionEvent) = true

                override fun onDoubleTap(event: MotionEvent): Boolean {
                    val target = if (scale > fitScale * 1.05f) fitScale else fitScale * 2f
                    zoomAt(event.x, event.y, target / scale)
                    return true
                }
            })

        init {
            setBackgroundColor(Color.rgb(245, 246, 248))
            isClickable = true
            contentDescription = "PDF canvas. Drag to move, pinch to zoom, double-tap to zoom."
        }

        override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
            super.onSizeChanged(w, h, oldw, oldh)
            if (w > 0 && h > 0 && pages.isNotEmpty()) initializeCanvas(w, h)
        }

        private fun initializeCanvas(viewWidth: Int, viewHeight: Int) {
            val first = pages.first()
            val widthScale = viewWidth.toFloat() / first.width
            fitScale = if (pages.size == 1) {
                min(widthScale, viewHeight.toFloat() / first.height)
            } else {
                widthScale
            }.coerceAtLeast(0.01f)
            scale = fitScale
            val documentHeight = pages.sumOf { it.height.toDouble() }.toFloat() +
                gapPx / fitScale * (pages.size - 1)
            offsetX = (viewWidth - first.width * scale) / 2f
            offsetY = if (pages.size == 1) {
                (viewHeight - documentHeight * scale) / 2f
            } else {
                dp(context as Activity, 12).toFloat()
            }
            initialized = true
            invalidate()
        }

        override fun onDraw(canvas: Canvas) {
            super.onDraw(canvas)
            if (!initialized || pages.isEmpty()) return
            val saveCount = canvas.save()
            canvas.translate(offsetX, offsetY)
            canvas.scale(scale, scale)
            var top = 0f
            pages.forEach { page ->
                canvas.drawBitmap(page, 0f, top, paint)
                top += page.height + gapPx / fitScale
            }
            canvas.restoreToCount(saveCount)
        }

        override fun onTouchEvent(event: MotionEvent): Boolean {
            scaleDetector.onTouchEvent(event)
            gestureDetector.onTouchEvent(event)
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    lastX = event.x
                    lastY = event.y
                    return true
                }
                MotionEvent.ACTION_MOVE -> {
                    if (!scaleDetector.isInProgress && event.pointerCount == 1) {
                        offsetX += event.x - lastX
                        offsetY += event.y - lastY
                        invalidate()
                    }
                    lastX = event.x
                    lastY = event.y
                    return true
                }
                MotionEvent.ACTION_POINTER_DOWN, MotionEvent.ACTION_POINTER_UP -> return true
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    performClick()
                    return true
                }
            }
            return true
        }

        override fun performClick(): Boolean {
            super.performClick()
            return true
        }

        private fun zoomAt(x: Float, y: Float, factor: Float) {
            if (!initialized) return
            val nextScale = (scale * factor).coerceIn(fitScale, fitScale * 6f)
            val applied = nextScale / scale
            scale = nextScale
            offsetX = x - (x - offsetX) * applied
            offsetY = y - (y - offsetY) * applied
            invalidate()
        }

        companion object {
            private fun dp(activity: Activity, value: Int) =
                value * activity.resources.displayMetrics.density
        }
    }
}
