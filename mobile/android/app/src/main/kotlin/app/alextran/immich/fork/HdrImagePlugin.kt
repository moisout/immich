package app.alextran.immich.fork

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.ContentUris
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ActivityInfo
import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.util.Log
import android.util.LruCache
import android.view.View
import android.widget.ImageView
import androidx.annotation.RequiresApi
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.io.InputStream
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.min

private const val TAG = "HdrImage"
private const val VIEW_TYPE = "immich/fork/hdr_image"
private const val CHANNEL = "immich/fork/hdr_image"

// Measurements: `adb shell am broadcast -a dev.moisout.immich.HDR_MODE --es mode full|sdr|empty`, applies to views
// created afterwards
private const val ACTION_MODE = "dev.moisout.immich.HDR_MODE"

@Volatile private var mode = "full"

/// Shows local Ultra HDR images (JPEGs with a gain map) in a native view embedded with Hybrid Composition++, where
/// Android applies the gain map while the window is in HDR color mode. Flutter itself only renders SDR
class HdrImagePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
  private var channel: MethodChannel? = null
  private var context: Context? = null

  private val modeReceiver = object : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
      mode = intent.getStringExtra("mode") ?: "full"
      Log.i(TAG, "Mode $mode")
    }
  }

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    context = binding.applicationContext
    channel = MethodChannel(binding.binaryMessenger, CHANNEL).also { it.setMethodCallHandler(this) }
    binding.platformViewRegistry.registerViewFactory(VIEW_TYPE, HdrImageViewFactory())
    binding.applicationContext.registerReceiver(modeReceiver, IntentFilter(ACTION_MODE), Context.RECEIVER_EXPORTED)
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel?.setMethodCallHandler(null)
    channel = null
    context = null
    binding.applicationContext.unregisterReceiver(modeReceiver)
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    val context = context
    when {
      call.method == "prepare" && context != null -> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
          result.success(false)
          return
        }
        val localId = call.argument<String>("localId")!!.toLong()
        HdrBitmaps.prepare(context, localId) { result.success(it) }
      }
      else -> result.notImplemented()
    }
  }
}

/// Detects gain maps and decodes HDR bitmaps at screen size in the background, keeping the last few
@RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
private object HdrBitmaps {
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

/// Keeps the window in HDR color mode while HDR images are shown, and only leaves it a moment after the last one, so
/// it doesn't switch back and forth between consecutive HDR images
private object HdrWindowMode {
  private const val RELEASE_DELAY_MS = 300L

  private val handler = Handler(Looper.getMainLooper())
  private var count = 0
  private var activity: Activity? = null
  private val leave = Runnable {
    activity?.window?.colorMode = ActivityInfo.COLOR_MODE_DEFAULT
    activity = null
  }

  fun acquire(activity: Activity) {
    count++
    handler.removeCallbacks(leave)
    if (this.activity !== activity) {
      this.activity?.window?.colorMode = ActivityInfo.COLOR_MODE_DEFAULT
      this.activity = activity
      activity.window.colorMode = ActivityInfo.COLOR_MODE_HDR
    }
  }

  fun release() {
    count--
    if (count == 0) {
      handler.postDelayed(leave, RELEASE_DELAY_MS)
    }
  }
}

private class HdrImageViewFactory : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
  override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
    val localId = (args as Map<*, *>)["localId"] as String
    return HdrImagePlatformView(context, localId.toLong())
  }
}

private class HdrImagePlatformView(context: Context, localId: Long) : PlatformView {
  private val imageView = HdrImageView(context, hdr = mode == "full")
  private var disposed = false

  init {
    if (mode != "empty" && Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
      HdrBitmaps.get(context.applicationContext, localId) { bitmap ->
        if (!disposed && bitmap != null) {
          imageView.setImageBitmap(bitmap)
        }
      }
    }
  }

  override fun getView(): View = imageView

  override fun dispose() {
    disposed = true
    imageView.setImageDrawable(null)
  }
}

private class HdrImageView(context: Context, private val hdr: Boolean) : ImageView(context) {
  private var acquired = false

  init {
    scaleType = ScaleType.FIT_CENTER
  }

  override fun onAttachedToWindow() {
    super.onAttachedToWindow()
    val activity = context.findActivity()
    if (hdr && activity != null) {
      HdrWindowMode.acquire(activity)
      acquired = true
    }
  }

  override fun onDetachedFromWindow() {
    if (acquired) {
      HdrWindowMode.release()
      acquired = false
    }
    super.onDetachedFromWindow()
  }
}

private fun Context.findActivity(): Activity? {
  var context: Context? = this
  while (context is ContextWrapper) {
    if (context is Activity) {
      return context
    }
    context = context.baseContext
  }
  return null
}
