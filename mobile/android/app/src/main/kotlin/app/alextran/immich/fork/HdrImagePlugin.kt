package app.alextran.immich.fork

import android.animation.ValueAnimator
import android.app.Activity
import android.content.ContentUris
import android.content.Context
import android.content.pm.ActivityInfo
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.ImageDecoder
import android.graphics.Paint
import android.graphics.RectF
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.util.Log
import android.util.LruCache
import android.view.Display
import android.view.View
import android.view.ViewGroup
import android.view.animation.AccelerateDecelerateInterpolator
import androidx.annotation.RequiresApi
import io.flutter.embedding.android.FlutterView
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.InputStream
import java.util.concurrent.Executors
import java.util.function.Consumer
import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min

private const val TAG = "HdrImage"
private const val CHANNEL = "immich/fork/hdr_image"

/// Shows local Ultra HDR images (JPEGs with a gain map) in a view in the activity's window, below the Flutter texture
/// view, which Flutter leaves a transparent hole in. Flutter itself only renders SDR, and ColorOS only composes HDR
/// correctly in opaque windows drawn as a whole, not in layers created by the app. Android applies the gain map while the window is in HDR
/// color mode, and brightens it gradually
class HdrImagePlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler {
  private var channel: MethodChannel? = null
  private var context: Context? = null
  private var activity: Activity? = null
  private var view: HdrImageView? = null

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    context = binding.applicationContext
    channel = MethodChannel(binding.binaryMessenger, CHANNEL).also { it.setMethodCallHandler(this) }
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel?.setMethodCallHandler(null)
    channel = null
    context = null
  }

  override fun onAttachedToActivity(binding: ActivityPluginBinding) {
    activity = binding.activity
  }

  override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)

  override fun onDetachedFromActivity() {
    view?.let { (it.parent as? ViewGroup)?.removeView(it) }
    view = null
    activity = null
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    val context = context
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE || context == null) {
      if (call.method == "prepare") result.success(false) else result.success(null)
      return
    }
    when (call.method) {
      "prepare" -> HdrImages.prepare(context, call.argument<String>("localId")!!.toLong()) { result.success(it) }
      "show" -> show(context, call.argument<String>("localId")!!.toLong(), result)
      "update" -> {
        view?.place(
          call.argument<String>("localId")!!.toLong(),
          call.argument<Double>("left")!!.toFloat(),
          call.argument<Double>("top")!!.toFloat(),
          call.argument<Double>("width")!!.toFloat(),
          call.argument<Double>("height")!!.toFloat(),
        )
        result.success(null)
      }
      "hide" -> {
        view?.hide(call.argument<String>("localId")!!.toLong())
        result.success(null)
      }
      else -> result.notImplemented()
    }
  }

  @RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
  private fun show(context: Context, localId: Long, result: MethodChannel.Result) {
    val view = view ?: createView()
    if (view == null) {
      result.success(null)
      return
    }
    HdrImages.get(context, localId) { bitmap ->
      if (bitmap == null) {
        result.success(null)
        return@get
      }
      view.show(localId, bitmap)
      result.success(mapOf("width" to bitmap.width, "height" to bitmap.height))
    }
  }

  private fun createView(): HdrImageView? {
    val activity = activity ?: return null
    val content = activity.findViewById<ViewGroup>(android.R.id.content)
    val flutterView = content.findFlutterView()
    if (flutterView == null) {
      Log.w(TAG, "No Flutter view")
      return null
    }
    return HdrImageView(activity, flutterView).also {
      content.addView(it, 0, ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
      view = it
    }
  }
}

private fun View.findFlutterView(): FlutterView? {
  if (this is FlutterView) {
    return this
  }
  if (this is ViewGroup) {
    for (i in 0 until childCount) {
      getChildAt(i).findFlutterView()?.let { return it }
    }
  }
  return null
}

/// Detects gain maps and decodes images with their gain map at screen size in the background, keeping the last few
@RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
private object HdrImages {
  private const val CACHE_SIZE = 3

  private val executor = Executors.newSingleThreadExecutor()
  private val mainHandler = Handler(Looper.getMainLooper())

  // Accessed on the main thread only
  private val isHdr = HashMap<Long, Boolean>()
  private val bitmaps = LruCache<Long, Bitmap>(CACHE_SIZE)
  private val pending = HashMap<Long, MutableList<(Bitmap?) -> Unit>>()

  /// Reports whether the image has a gain map, and if so starts decoding it
  fun prepare(context: Context, localId: Long, callback: (Boolean) -> Unit) {
    isHdr[localId]?.let { hdr ->
      if (hdr) get(context, localId) {}
      callback(hdr)
      return
    }
    executor.execute {
      val hdr = try {
        context.contentResolver.openInputStream(uri(localId))?.use(::hasGainMap) ?: false
      } catch (e: Exception) {
        Log.w(TAG, "Failed to read $localId", e)
        false
      }
      mainHandler.post {
        isHdr[localId] = hdr
        if (hdr) get(context, localId) {}
        callback(hdr)
      }
    }
  }

  /// Calls back on the main thread with the decoded bitmap, or null if decoding failed
  fun get(context: Context, localId: Long, callback: (Bitmap?) -> Unit) {
    bitmaps.get(localId)?.let {
      callback(it)
      return
    }
    pending[localId]?.let {
      it.add(callback)
      return
    }
    pending[localId] = mutableListOf(callback)
    executor.execute {
      val bitmap = try {
        decode(context, localId)
      } catch (e: Exception) {
        Log.w(TAG, "Failed to decode $localId", e)
        null
      }
      mainHandler.post {
        if (bitmap != null) {
          bitmaps.put(localId, bitmap)
        }
        pending.remove(localId)?.forEach { it(bitmap) }
      }
    }
  }

  private fun uri(localId: Long) = ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, localId)

  // Fits the image into the screen, comparing long and short sides so it also fits after rotating the device
  private fun decode(context: Context, localId: Long): Bitmap {
    val metrics = context.resources.displayMetrics
    val screenLong = max(metrics.widthPixels, metrics.heightPixels)
    val screenShort = min(metrics.widthPixels, metrics.heightPixels)
    val start = System.nanoTime()
    val bitmap = ImageDecoder.decodeBitmap(ImageDecoder.createSource(context.contentResolver, uri(localId))) { decoder, info, _ ->
      val imageLong = max(info.size.width, info.size.height)
      val imageShort = min(info.size.width, info.size.height)
      val scale = min(screenLong.toFloat() / imageLong, screenShort.toFloat() / imageShort)
      if (scale < 1) {
        decoder.setTargetSize((info.size.width * scale).toInt(), (info.size.height * scale).toInt())
      }
    }
    Log.i(
      TAG,
      "Decoded $localId: ${bitmap.width}x${bitmap.height} ${bitmap.config} gainmap=${bitmap.hasGainmap()} " +
        "in ${(System.nanoTime() - start) / 1_000_000}ms",
    )
    return bitmap
  }

  // Looks for Ultra HDR metadata in the JPEG headers: the gain map XMP namespace or the ISO 21496-1 marker
  private fun hasGainMap(input: InputStream): Boolean {
    if (input.read() != 0xFF || input.read() != 0xD8) {
      return false
    }
    while (true) {
      if (input.read() != 0xFF) {
        return false
      }
      val marker = input.read()
      // Start of scan, the headers are over
      if (marker == 0xDA || marker < 0) {
        return false
      }
      val length = (input.read() shl 8) or input.read()
      if (length < 2) {
        return false
      }
      if (marker == 0xE1 || marker == 0xE2) {
        val text = String(input.readNBytes(length - 2), Charsets.ISO_8859_1)
        if (text.contains("http://ns.adobe.com/hdr-gain-map/1.0/") || text.startsWith("urn:iso:std:iso:ts:21496:-1")) {
          return true
        }
      } else {
        input.skipNBytes((length - 2).toLong())
      }
    }
  }
}

/// Draws HDR images at rects given in physical pixels of the Flutter view, like the visible pages while swiping, with
/// the window in HDR color mode while it does. The HDR headroom the window asks for ramps up when the first image
/// appears, on a log scale. Once no HDR image is shown, the window leaves HDR mode right away, as ColorOS shows its SDR
/// content too bright otherwise. Leaving waits a moment, in case another image is about to be shown.
///
/// ColorOS maps the brightest value the window renders to the display's current peak brightness, so the images are
/// redrawn whenever the display's HDR headroom changes, otherwise their shadows show too bright
private class HdrImageView(private val activity: Activity, private val flutterView: View) : View(activity) {
  companion object {
    private const val RAMP_MS = 800L
    private const val LEAVE_HDR_DELAY_MS = 100L
  }

  private class Image(val bitmap: Bitmap) {
    val rect = RectF()
    var placed = false
  }

  private val paint = Paint(Paint.FILTER_BITMAP_FLAG)
  private val images = LinkedHashMap<Long, Image>()
  private val flutterLocation = IntArray(2)
  private val viewLocation = IntArray(2)
  private var headroom = 1f
  private var ramp: ValueAnimator? = null
  private val headroomListener = Consumer<Display> {
    if (images.isNotEmpty()) {
      invalidate()
    }
  }
  private val leaveHdr = Runnable {
    ramp?.cancel()
    headroom = 1f
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.VANILLA_ICE_CREAM) {
      activity.window.desiredHdrHeadroom = 0f
    }
    activity.window.colorMode = ActivityInfo.COLOR_MODE_DEFAULT
  }

  fun show(localId: Long, bitmap: Bitmap) {
    if (images[localId]?.bitmap !== bitmap) {
      images[localId] = Image(bitmap)
      invalidate()
    }
    removeCallbacks(leaveHdr)
    activity.window.colorMode = ActivityInfo.COLOR_MODE_HDR
    rampHeadroom(bitmap.gainmap?.displayRatioForFullHdr ?: 1f)
  }

  private fun rampHeadroom(target: Float) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.VANILLA_ICE_CREAM || target <= headroom || ramp?.isRunning == true) {
      return
    }
    val from = ln(headroom)
    val to = ln(target)
    ramp = ValueAnimator.ofFloat(0f, 1f).apply {
      duration = RAMP_MS
      interpolator = AccelerateDecelerateInterpolator()
      addUpdateListener {
        headroom = exp(from + (to - from) * it.animatedFraction)
        activity.window.desiredHdrHeadroom = headroom
        invalidate()
      }
      start()
    }
  }

  fun place(localId: Long, left: Float, top: Float, width: Float, height: Float) {
    val image = images[localId] ?: return
    flutterView.getLocationInWindow(flutterLocation)
    getLocationInWindow(viewLocation)
    val x = left + flutterLocation[0] - viewLocation[0]
    val y = top + flutterLocation[1] - viewLocation[1]
    image.rect.set(x, y, x + width, y + height)
    image.placed = true
    invalidate()
  }

  fun hide(localId: Long) {
    if (images.remove(localId) == null) {
      return
    }
    invalidate()
    if (images.isEmpty()) {
      removeCallbacks(leaveHdr)
      postDelayed(leaveHdr, LEAVE_HDR_DELAY_MS)
    }
  }

  override fun onAttachedToWindow() {
    super.onAttachedToWindow()
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
      display?.registerHdrSdrRatioChangedListener(context.mainExecutor, headroomListener)
    }
  }

  override fun onDetachedFromWindow() {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
      display?.unregisterHdrSdrRatioChangedListener(headroomListener)
    }
    super.onDetachedFromWindow()
  }

  override fun onDraw(canvas: Canvas) {
    for (image in images.values) {
      if (image.placed) {
        canvas.drawBitmap(image.bitmap, null, image.rect, paint)
      }
    }
  }
}
