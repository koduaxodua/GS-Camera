package com.gscamera

import android.app.Activity
import android.content.Context
import android.os.Handler
import android.os.HandlerThread
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Flutter plugin entry. Wires the method-channel + event-channel that
 * `lib/services/camera_service.dart` calls into.
 *
 * Method channel (`gs_camera/control`):
 *   initSession   -> Map<String, Any> with cfg + texture id
 *   capture       -> String (absolute JPEG path)
 *   recalibrate   -> Map<String, Any>
 *   dispose       -> null
 *
 * Event channel (`gs_camera/preview_frames`):
 *   emits Map { luma: ByteArray, width: Int, height: Int, timestamp_ms: Long }
 *   at ~10 Hz (downscaled, grayscale).
 */
class GsCameraPlugin : FlutterPlugin, ActivityAware,
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var appContext: Context? = null
    private var activity: Activity? = null

    private var session: CameraSession? = null

    private val cameraThread = HandlerThread("gs-camera").apply { start() }
    private val cameraHandler = Handler(cameraThread.looper)

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, "gs_camera/control")
        methodChannel.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, "gs_camera/preview_frames")
        eventChannel.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        session?.close()
        cameraThread.quitSafely()
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    // -----------------------------------------------------------------
    // MethodChannel
    // -----------------------------------------------------------------
    override fun onMethodCall(call: io.flutter.plugin.common.MethodCall,
                              result: MethodChannel.Result) {
        val ctx = appContext ?: return result.error("noctx", "no context", null)
        when (call.method) {
            "initSession" -> {
                if (session == null) {
                    session = CameraSession(ctx, cameraHandler) { frame ->
                        previewSink?.success(mapOf(
                            "luma" to frame.luma,
                            "width" to frame.width,
                            "height" to frame.height,
                            "timestamp_ms" to frame.timestampMs,
                        ))
                    }
                }
                session!!.openAndCalibrate { cfg, err ->
                    if (err != null) result.error("init", err.message, null)
                    else result.success(cfg)
                }
            }
            "capture" -> {
                val s = session ?: return result.error("nosession", "init first", null)
                s.captureJpeg { path, err ->
                    if (err != null) result.error("capture", err.message, null)
                    else result.success(path)
                }
            }
            "recalibrate" -> {
                val s = session ?: return result.error("nosession", "init first", null)
                s.recalibrate { cfg, err ->
                    if (err != null) result.error("recalibrate", err.message, null)
                    else result.success(cfg)
                }
            }
            "dispose" -> {
                session?.close()
                session = null
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    // -----------------------------------------------------------------
    // EventChannel (preview frames)
    // -----------------------------------------------------------------
    private var previewSink: EventChannel.EventSink? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        previewSink = events
    }

    override fun onCancel(arguments: Any?) {
        previewSink = null
    }
}
