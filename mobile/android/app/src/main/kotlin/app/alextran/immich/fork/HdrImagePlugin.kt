package app.alextran.immich.fork

import android.app.Activity
import android.content.ContentUris
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapShader
import android.graphics.ColorSpace
import android.graphics.Gainmap
import android.graphics.HardwareBufferRenderer
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.RenderNode
import android.graphics.RuntimeShader
import android.graphics.Shader
import android.hardware.DataSpace
import android.hardware.HardwareBuffer
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.MediaStore
import android.util.Log
import android.util.LruCache
import android.view.Choreographer
import android.view.Display
import android.view.SurfaceControl
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import androidx.annotation.RequiresApi
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.InputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.function.Consumer
import kotlin.math.abs
import kotlin.math.log2
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow

private const val TAG = "HdrImage"
private const val CHANNEL = "immich/fork/hdr_image"

/// Shows local Ultra HDR images (JPEGs with a gain map) on a layer below the Flutter surface, which Flutter leaves a
/// transparent hole in. Flutter itself only renders SDR. The layer holds the image with its gain map applied for the
/// display's current HDR headroom, in an extended range buffer, and is moved along with Flutter's frames
class HdrImagePlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler {
  private var channel: MethodChannel? = null
  private var context: Context? = null
  private var activity: Activity? = null
  private var layer: Any? = null

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
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
      (layer as HdrLayer?)?.release()
    }
    layer = null
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
        (layer as HdrLayer?)?.update(
          call.argument<Double>("left")!!.toFloat(),
          call.argument<Double>("top")!!.toFloat(),
          call.argument<Double>("width")!!.toFloat(),
          call.argument<Double>("height")!!.toFloat(),
        )
        result.success(null)
      }
      "hide" -> {
        (layer as HdrLayer?)?.hide(call.argument<String>("localId")!!.toLong())
        result.success(null)
      }
      else -> result.notImplemented()
    }
  }

  @RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
  private fun show(context: Context, localId: Long, result: MethodChannel.Result) {
    val surfaceView = activity?.window?.decorView?.findSurfaceView()
    val display = surfaceView?.display
    if (surfaceView == null || display == null) {
      Log.w(TAG, "No Flutter surface view")
      result.success(null)
      return
    }
    val layer = (layer as HdrLayer?)?.takeIf { it.surfaceView === surfaceView } ?: HdrLayer(surfaceView, display).also {
      (layer as HdrLayer?)?.release()
      layer = it
    }
    HdrImages.get(context, localId) { source ->
      if (source == null) {
        result.success(null)
        return@get
      }
      layer.show(localId, source) { shown ->
        result.success(if (shown) mapOf("width" to source.width, "height" to source.height) else null)
      }
    }
  }
}

private fun View.findSurfaceView(): SurfaceView? {
  if (this is SurfaceView) {
    return this
  }
  if (this is ViewGroup) {
    for (i in 0 until childCount) {
      getChildAt(i).findSurfaceView()?.let { return it }
    }
  }
  return null
}

/// A decoded image without its gain map, and the gain map
@RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
private class HdrSource(val bitmap: Bitmap, val gainmap: Gainmap) {
  val width get() = bitmap.width
  val height get() = bitmap.height

  /// How much of the gain map to apply for a display HDR/SDR ratio, like Android does for gain mapped bitmaps
  fun weight(displayRatio: Float): Float {
    val minRatio = log2(gainmap.minDisplayRatioForHdrTransition)
    val fullRatio = log2(gainmap.displayRatioForFullHdr)
    if (fullRatio <= minRatio) {
      return if (displayRatio > gainmap.minDisplayRatioForHdrTransition) 1f else 0f
    }
    return ((log2(displayRatio) - minRatio) / (fullRatio - minRatio)).coerceIn(0f, 1f)
  }

  /// HDR/SDR ratio of the brightest part with the gain map fully applied
  val maxRatio get() = gainmap.ratioMax.max()
}

/// Detects gain maps and decodes images at screen size in the background, keeping the last few
@RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
private object HdrImages {
  private const val CACHE_SIZE = 3

  private val executor = Executors.newSingleThreadExecutor()
  private val mainHandler = Handler(Looper.getMainLooper())

  // Accessed on the main thread only
  private val isHdr = HashMap<Long, Boolean>()
  private val sources = LruCache<Long, HdrSource>(CACHE_SIZE)
  private val pending = HashMap<Long, MutableList<(HdrSource?) -> Unit>>()

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

  /// Calls back on the main thread with the decoded image, or null if that failed
  fun get(context: Context, localId: Long, callback: (HdrSource?) -> Unit) {
    sources.get(localId)?.let {
      callback(it)
      return
    }
    pending[localId]?.let {
      it.add(callback)
      return
    }
    pending[localId] = mutableListOf(callback)
    executor.execute {
      val source = try {
        decode(context, localId)
      } catch (e: Exception) {
        Log.w(TAG, "Failed to decode $localId", e)
        null
      }
      mainHandler.post {
        if (source != null) {
          sources.put(localId, source)
        }
        pending.remove(localId)?.forEach { it(source) }
      }
    }
  }

  private fun uri(localId: Long) = ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, localId)

  // Fits the image into the screen, comparing long and short sides so it also fits after rotating the device. Decodes
  // into a mutable bitmap so the gain map can be taken off, the shader applies it instead of HWUI
  private fun decode(context: Context, localId: Long): HdrSource {
    val metrics = context.resources.displayMetrics
    val screenLong = max(metrics.widthPixels, metrics.heightPixels)
    val screenShort = min(metrics.widthPixels, metrics.heightPixels)
    val start = System.nanoTime()
    val bitmap = ImageDecoder.decodeBitmap(ImageDecoder.createSource(context.contentResolver, uri(localId))) { decoder, info, _ ->
      decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
      decoder.isMutableRequired = true
      val imageLong = max(info.size.width, info.size.height)
      val imageShort = min(info.size.width, info.size.height)
      val scale = min(screenLong.toFloat() / imageLong, screenShort.toFloat() / imageShort)
      if (scale < 1) {
        decoder.setTargetSize((info.size.width * scale).toInt(), (info.size.height * scale).toInt())
      }
    }
    val gainmap = bitmap.gainmap ?: error("No gain map")
    bitmap.gainmap = null
    Log.i(
      TAG,
      "Decoded $localId: ${bitmap.width}x${bitmap.height}, gain map ${gainmap.gainmapContents.config} " +
        "ratio ${gainmap.ratioMin.toList()}..${gainmap.ratioMax.toList()} gamma ${gainmap.gamma.toList()} " +
        "display ratio ${gainmap.minDisplayRatioForHdrTransition}..${gainmap.displayRatioForFullHdr} " +
        "in ${(System.nanoTime() - start) / 1_000_000}ms",
    )
    return HdrSource(bitmap, gainmap)
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

/// Renders an image with its gain map applied into an extended range buffer
@RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
private object HdrRenderer {
  private val executor = Executors.newSingleThreadExecutor()
  private val fenceExecutor = Executors.newSingleThreadExecutor()
  private val mainHandler = Handler(Looper.getMainLooper())

  // Applies the gain map following the Ultra HDR spec, in linear light: hdr = (sdr + epsilonSdr) * 2^(log2 ratio *
  // weight) - epsilonHdr, with the ratio interpolated between its min and max by the gain map value. Then scales it so
  // the display's peak brightness is 1, see HdrLayer
  private const val SHADER = """
    uniform shader base;
    uniform shader gain;
    uniform float3 logRatioMin;
    uniform float3 logRatioMax;
    uniform float3 gammaInv;
    uniform float3 epsilonSdr;
    uniform float3 epsilonHdr;
    uniform float weight;
    uniform float scale;
    uniform int singleChannel;

    half4 main(float2 coord) {
      half4 sdr = base.eval(coord);
      float3 linearSdr = toLinearSrgb(sdr.rgb);
      half4 g = gain.eval(coord);
      float3 gainValue = singleChannel == 1 ? float3(g.a) : float3(g.rgb);
      float3 logRatio = mix(logRatioMin, logRatioMax, pow(gainValue, gammaInv)) * weight;
      float3 hdr = (linearSdr + epsilonSdr) * exp2(logRatio) - epsilonHdr;
      return half4(fromLinearSrgb(hdr * scale), 1.0);
    }
  """

  fun createBuffer(width: Int, height: Int): HardwareBuffer = HardwareBuffer.create(
    width,
    height,
    HardwareBuffer.RGBA_FP16,
    1,
    HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE or HardwareBuffer.USAGE_GPU_COLOR_OUTPUT or
      HardwareBuffer.USAGE_COMPOSER_OVERLAY,
  )

  /// Renders into the buffer and calls back on the main thread with the HDR/SDR ratio of its brightest part
  fun render(source: HdrSource, weight: Float, scale: Float, buffer: HardwareBuffer, callback: (Float) -> Unit) {
    executor.execute {
      val start = System.nanoTime()
      render(source, weight, scale, buffer)
      val ratio = source.maxRatio.pow(weight)
      Log.d(
        TAG,
        "Rendered with weight $weight, ratio $ratio, scale $scale, in ${(System.nanoTime() - start) / 1_000_000}ms",
      )
      mainHandler.post { callback(ratio) }
    }
  }

  private fun render(source: HdrSource, weight: Float, scale: Float, buffer: HardwareBuffer) {
    val width = source.width
    val height = source.height
    val gainmap = source.gainmap
    val contents = gainmap.gainmapContents
    val gainShader = BitmapShader(contents, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP).apply {
      setLocalMatrix(Matrix().apply { setScale(width.toFloat() / contents.width, height.toFloat() / contents.height) })
    }
    val ratioMin = gainmap.ratioMin
    val ratioMax = gainmap.ratioMax
    val gamma = gainmap.gamma
    val epsilonSdr = gainmap.epsilonSdr
    val epsilonHdr = gainmap.epsilonHdr
    val shader = RuntimeShader(SHADER).apply {
      setInputShader("base", BitmapShader(source.bitmap, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP))
      setInputBuffer("gain", gainShader)
      setFloatUniform("logRatioMin", log2(ratioMin[0]), log2(ratioMin[1]), log2(ratioMin[2]))
      setFloatUniform("logRatioMax", log2(ratioMax[0]), log2(ratioMax[1]), log2(ratioMax[2]))
      setFloatUniform("gammaInv", 1 / gamma[0], 1 / gamma[1], 1 / gamma[2])
      setFloatUniform("epsilonSdr", epsilonSdr[0], epsilonSdr[1], epsilonSdr[2])
      setFloatUniform("epsilonHdr", epsilonHdr[0], epsilonHdr[1], epsilonHdr[2])
      setFloatUniform("weight", weight)
      setFloatUniform("scale", scale)
      setIntUniform("singleChannel", if (contents.config == Bitmap.Config.ALPHA_8) 1 else 0)
    }

    val node = RenderNode("hdr-image").apply { setPosition(0, 0, width, height) }
    node.beginRecording().drawPaint(Paint().apply { this.shader = shader })
    node.endRecording()

    val renderer = HardwareBufferRenderer(buffer)
    renderer.setContentRoot(node)
    val done = CountDownLatch(1)
    // Gamma encoded like HWUI's HDR output, the display pipeline doesn't handle linear extended range correctly
    renderer.obtainRenderRequest()
      .setColorSpace(ColorSpace.get(ColorSpace.Named.EXTENDED_SRGB))
      .draw(fenceExecutor) { result ->
        result.fence.awaitForever()
        result.fence.close()
        done.countDown()
      }
    done.await()
    renderer.close()
    node.discardDisplayList()
  }
}

/// A layer just below the Flutter surface's content, showing one HDR image. Geometry changes are applied with
/// Flutter's next frame, so the image moves in sync with the hole Flutter leaves for it.
///
/// When the layer appears, the HDR headroom it asks for ramps up, and the image is re-rendered for the headroom the
/// display has, so it brightens gradually. Buffers are reused once the compositor releases them.
///
/// ColorOS composes extended range layers with 1.0 at the display's current peak brightness rather than at SDR white,
/// ignoring the buffer's HDR/SDR ratio, so the image is scaled down by the display's HDR/SDR ratio
@RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
private class HdrLayer(val surfaceView: SurfaceView, private val display: Display) {
  companion object {
    private const val RAMP_MS = 800L

    // A layer hidden for less than this keeps its headroom, like when swiping between HDR images
    private const val KEEP_HEADROOM_MS = 300L

    // Re-rendering for smaller weight or relative scale changes isn't visible
    private const val MIN_WEIGHT_CHANGE = 0.02f
  }

  private val mainHandler = Handler(Looper.getMainLooper())
  private val releaseExecutor = Executors.newSingleThreadExecutor()
  private val control = SurfaceControl.Builder()
    .setName("immich-hdr-image")
    .setParent(surfaceView.surfaceControl)
    .setHidden(true)
    .build()

  private var source: HdrSource? = null
  private var localId: Long? = null
  private var weight = -1f
  private var scale = 1f
  private var ratio = 1f
  private var rendering = false
  private val freeBuffers = ArrayDeque<HardwareBuffer>()

  private var rampStart = 0L
  private var hiddenSince: Long? = 0L
  private var released = false

  private val ratioListener = Consumer<Display> { renderIfNeeded() }
  private val rampTick = Choreographer.FrameCallback { tick() }

  init {
    SurfaceControl.Transaction().setLayer(control, -1).apply()
    display.registerHdrSdrRatioChangedListener(surfaceView.context.mainExecutor, ratioListener)
  }

  private fun now() = SystemClock.uptimeMillis()

  private fun rampProgress() = ((now() - rampStart).toFloat() / RAMP_MS).coerceIn(0f, 1f)

  // The headroom asked for, easing in and out on a log scale
  private fun desiredRatio(source: HdrSource): Float {
    val t = rampProgress()
    val eased = if (t < 0.5f) 4 * t * t * t else 1 - (-2 * t + 2).pow(3) / 2
    return source.maxRatio.pow(eased)
  }

  private fun displayRatio() = if (display.isHdrSdrRatioAvailable) display.hdrSdrRatio else 1f

  private fun targetWeight(source: HdrSource) = source.weight(min(displayRatio(), desiredRatio(source)))

  private fun targetScale() = 1 / displayRatio()

  fun show(localId: Long, source: HdrSource, callback: (Boolean) -> Unit) {
    this.localId = localId
    if (this.source === source) {
      callback(true)
      return
    }
    this.source = source
    weight = -1f
    val hiddenSince = hiddenSince
    if (hiddenSince != null && now() - hiddenSince > KEEP_HEADROOM_MS) {
      rampStart = now()
    }
    this.hiddenSince = null
    render(source) { callback(it) }
  }

  private fun render(source: HdrSource, callback: (Boolean) -> Unit = {}) {
    val weight = targetWeight(source)
    val scale = targetScale()
    val buffer = obtainBuffer(source)
    rendering = true
    HdrRenderer.render(source, weight, scale, buffer) { ratio ->
      rendering = false
      if (released || this.source !== source) {
        recycle(buffer)
        callback(false)
        return@render
      }
      setBuffer(buffer, weight, scale, ratio, source)
      callback(true)
      renderIfNeeded()
    }
  }

  private fun obtainBuffer(source: HdrSource): HardwareBuffer {
    while (true) {
      val buffer = freeBuffers.removeFirstOrNull() ?: return HdrRenderer.createBuffer(source.width, source.height)
      if (buffer.width == source.width && buffer.height == source.height) {
        return buffer
      }
      buffer.close()
    }
  }

  private fun recycle(buffer: HardwareBuffer) {
    if (released) buffer.close() else freeBuffers.addLast(buffer)
  }

  private fun setBuffer(buffer: HardwareBuffer, weight: Float, scale: Float, ratio: Float, source: HdrSource) {
    SurfaceControl.Transaction()
      .setBuffer(control, buffer, null) { releaseFence ->
        releaseExecutor.execute {
          releaseFence.awaitForever()
          releaseFence.close()
          mainHandler.post { recycle(buffer) }
        }
      }
      .setDataSpace(control, DataSpace.DATASPACE_SCRGB)
      .setExtendedRangeBrightness(control, ratio, desiredRatio(source))
      .setOpaque(control, true)
      .apply()
    this.weight = weight
    this.scale = scale
    this.ratio = ratio
    if (rampProgress() < 1) {
      Choreographer.getInstance().removeFrameCallback(rampTick)
      Choreographer.getInstance().postFrameCallback(rampTick)
    }
  }

  private fun tick() {
    val source = source ?: return
    if (rampProgress() < 1) {
      Choreographer.getInstance().postFrameCallback(rampTick)
    }
    SurfaceControl.Transaction().setExtendedRangeBrightness(control, ratio, desiredRatio(source)).apply()
    renderIfNeeded()
  }

  private fun renderIfNeeded() {
    val source = source ?: return
    if (rendering || weight < 0 || released) {
      return
    }
    if (abs(targetWeight(source) - weight) >= MIN_WEIGHT_CHANGE || abs(targetScale() / scale - 1) >= MIN_WEIGHT_CHANGE) {
      render(source)
    }
  }

  /// Places the image at the given rect in physical pixels of the Flutter surface
  fun update(left: Float, top: Float, width: Float, height: Float) {
    val source = source ?: return
    surfaceView.applyTransactionToFrame(
      SurfaceControl.Transaction()
        .setPosition(control, left, top)
        .setScale(control, width / source.width, height / source.height)
        .setVisibility(control, true),
    )
  }

  fun hide(localId: Long) {
    if (this.localId != localId) {
      return
    }
    this.localId = null
    source = null
    hiddenSince = now()
    surfaceView.applyTransactionToFrame(SurfaceControl.Transaction().setVisibility(control, false))
  }

  fun release() {
    released = true
    Choreographer.getInstance().removeFrameCallback(rampTick)
    display.unregisterHdrSdrRatioChangedListener(ratioListener)
    source = null
    SurfaceControl.Transaction().reparent(control, null).apply()
    control.release()
    freeBuffers.forEach { it.close() }
    freeBuffers.clear()
  }
}
