package com.gscamera.gs_camera

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.view.Surface
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import org.json.JSONArray
import org.json.JSONObject

class GsCameraPlugin : FlutterPlugin, ActivityAware,
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var motionChannel: EventChannel
    private lateinit var exportProgressChannel: EventChannel
    private var appContext: Context? = null
    private var activity: Activity? = null
    private var textureRegistry: TextureRegistry? = null
    private var textureEntry: TextureRegistry.SurfaceTextureEntry? = null
    private var previewSurface: Surface? = null

    private var session: CameraSession? = null

    private val cameraThread = HandlerThread("gs-camera").apply { start() }
    private val cameraHandler = Handler(cameraThread.looper)
    private val mainHandler = Handler(Looper.getMainLooper())
    private var motionSink: EventChannel.EventSink? = null
    private var motionListener: SensorEventListener? = null
    private var initialYawRad: Float? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        textureRegistry = binding.textureRegistry
        methodChannel = MethodChannel(binding.binaryMessenger, "gs_camera/control")
        methodChannel.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, "gs_camera/preview_frames")
        eventChannel.setStreamHandler(this)
        motionChannel = EventChannel(binding.binaryMessenger, "gs_camera/motion")
        motionChannel.setStreamHandler(motionStreamHandler)
        exportProgressChannel = EventChannel(binding.binaryMessenger, "gs_camera/export_progress")
        exportProgressChannel.setStreamHandler(exportProgressStreamHandler)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        motionChannel.setStreamHandler(null)
        exportProgressChannel.setStreamHandler(null)
        ExportForegroundService.setProgressSink(null)
        stopMotion()
        session?.close()
        releaseTexture()
        textureRegistry = null
        cameraThread.quitSafely()
    }

    private fun releaseTexture() {
        runCatching { previewSurface?.release() }
        runCatching { textureEntry?.release() }
        previewSurface = null
        textureEntry = null
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

    override fun onMethodCall(
        call: io.flutter.plugin.common.MethodCall,
        result: MethodChannel.Result
    ) {
        val ctx = appContext ?: return result.error("noctx", "no context", null)
        when (call.method) {
            "initSession" -> {
                val cameraIndex = call.argument<Int>("camera_index") ?: 1
                val registry = textureRegistry
                    ?: return result.error("noregistry", "no texture registry", null)
                if (textureEntry == null) {
                    textureEntry = registry.createSurfaceTexture()
                }
                val entry = textureEntry!!
                if (previewSurface == null) {
                    previewSurface = Surface(entry.surfaceTexture())
                }
                if (session == null) {
                    session = CameraSession(
                        ctx = ctx,
                        handler = cameraHandler,
                        previewSurface = previewSurface!!,
                        previewSurfaceTexture = entry.surfaceTexture(),
                        onPreviewFrame = { frame ->
                            mainHandler.post {
                                previewSink?.success(
                                    mapOf(
                                        "luma" to frame.luma,
                                        "width" to frame.width,
                                        "height" to frame.height,
                                        "timestamp_ms" to frame.timestampMs,
                                    )
                                )
                            }
                        },
                    )
                }
                session!!.openAndCalibrate(cameraIndex) { cfg, err ->
                    if (err != null) {
                        result.error("init", err.message, null)
                    } else {
                        val withTexture = cfg!!.toMutableMap().apply {
                            this["texture_id"] = entry.id()
                        }
                        result.success(withTexture)
                    }
                }
            }
            "selectCamera" -> {
                val s = session ?: return result.error("nosession", "init first", null)
                val cameraIndex = call.argument<Int>("camera_index") ?: 1
                s.selectCamera(cameraIndex) { cfg, err ->
                    if (err != null) {
                        result.error("selectCamera", err.message, null)
                    } else {
                        val withTexture = cfg!!.toMutableMap().apply {
                            textureEntry?.let { this["texture_id"] = it.id() }
                        }
                        result.success(withTexture)
                    }
                }
            }
            "getIntrinsics" -> {
                val s = session
                val cameraIndex = call.argument<Int>("camera_index") ?: 1
                if (s != null) {
                    result.success(s.intrinsicsFor(cameraIndex))
                } else {
                    result.success(intrinsicsFor(ctx, cameraIndex))
                }
            }
            "getCameraList" -> {
                result.success(CameraSession.cameraInventoryMap(ctx))
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
                    else {
                        val withTexture = cfg!!.toMutableMap().apply {
                            textureEntry?.let { this["texture_id"] = it.id() }
                        }
                        result.success(withTexture)
                    }
                }
            }
            "dispose" -> {
                session?.close()
                session = null
                releaseTexture()
                result.success(null)
            }
            "startBackgroundExport" -> {
                val shots = call.argument<List<Map<String, Any?>>>("shots") ?: emptyList()
                val sessionInfo = call.argument<Map<String, Any?>>("session_info") ?: emptyMap()
                val asZip = call.argument<Boolean>("as_zip") ?: false
                val outputPath = ExportForegroundService.buildOutputPath(ctx, asZip)
                ExportForegroundService.start(
                    ctx = ctx,
                    shotsJson = JSONArray(shots).toString(),
                    sessionInfoJson = JSONObject(sessionInfo).toString(),
                    asZip = asZip,
                    outputPath = outputPath,
                )
                result.success(
                    mapOf(
                        "output_path" to outputPath,
                        "as_zip" to asZip,
                    )
                )
            }
            "openExportLocation" -> {
                val path = call.argument<String>("path") ?: ""
                result.success(openExportLocation(ctx, path))
            }
            else -> result.notImplemented()
        }
    }

    private var previewSink: EventChannel.EventSink? = null

    private val motionStreamHandler = object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
            motionSink = events
            startMotion()
        }

        override fun onCancel(arguments: Any?) {
            stopMotion()
            motionSink = null
        }
    }

    private val exportProgressStreamHandler = object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
            ExportForegroundService.setProgressSink(events)
        }

        override fun onCancel(arguments: Any?) {
            ExportForegroundService.setProgressSink(null)
        }
    }

    private fun startMotion() {
        val ctx = appContext ?: return
        val sensorManager = ctx.getSystemService(Context.SENSOR_SERVICE) as SensorManager
        val sensor = sensorManager.getDefaultSensor(Sensor.TYPE_GAME_ROTATION_VECTOR)
            ?: sensorManager.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)
            ?: return
        initialYawRad = null
        val rotation = FloatArray(9)
        val listener = object : SensorEventListener {
            override fun onSensorChanged(event: SensorEvent) {
                SensorManager.getRotationMatrixFromVector(rotation, event.values)
                val east = -(rotation[2])
                val north = -(rotation[5])
                val up = -(rotation[8])
                val yaw = kotlin.math.atan2(east, north)
                val startYaw = initialYawRad ?: yaw.also { initialYawRad = it }
                var relYaw = yaw - startYaw
                while (relYaw < 0f) relYaw += (2f * Math.PI).toFloat()
                while (relYaw >= (2f * Math.PI).toFloat()) relYaw -= (2f * Math.PI).toFloat()
                val elevation = kotlin.math.asin(up.coerceIn(-1f, 1f))
                val roll = kotlin.math.atan2(rotation[3], rotation[4])
                mainHandler.post {
                    motionSink?.success(
                        mapOf(
                            "azimuth_deg" to Math.toDegrees(relYaw.toDouble()),
                            "elevation_deg" to Math.toDegrees(elevation.toDouble()),
                            "roll_deg" to Math.toDegrees(roll.toDouble()),
                            "timestamp_ms" to System.currentTimeMillis(),
                        )
                    )
                }
            }

            override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit
        }
        motionListener = listener
        sensorManager.registerListener(
            listener,
            sensor,
            SensorManager.SENSOR_DELAY_GAME,
            cameraHandler,
        )
    }

    private fun stopMotion() {
        val ctx = appContext ?: return
        val listener = motionListener ?: return
        val sensorManager = ctx.getSystemService(Context.SENSOR_SERVICE) as SensorManager
        sensorManager.unregisterListener(listener)
        motionListener = null
        initialYawRad = null
    }

    private fun intrinsicsFor(ctx: Context, cameraIndex: Int): Map<String, Double> {
        return CameraSession.intrinsicsFor(ctx, cameraIndex)
    }

    private fun openExportLocation(ctx: Context, path: String): Boolean {
        val targetUri = documentTreeUriForPath(path)
        val intents = listOf(
            Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                putExtra(DocumentsContract.EXTRA_INITIAL_URI, targetUri)
            },
            Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(targetUri, "vnd.android.document/directory")
                putExtra(DocumentsContract.EXTRA_INITIAL_URI, targetUri)
            },
            Intent(Intent.ACTION_VIEW).apply {
                setClassName(
                    "com.google.android.documentsui",
                    "com.android.documentsui.files.FilesActivity",
                )
                data = targetUri
                putExtra(DocumentsContract.EXTRA_INITIAL_URI, targetUri)
            },
            Intent(Intent.ACTION_VIEW).apply {
                data = Uri.parse("content://com.android.externalstorage.documents/root/primary")
                putExtra(DocumentsContract.EXTRA_INITIAL_URI, targetUri)
            },
        )
        for (intent in intents) {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            intent.putExtra("android.provider.extra.INITIAL_URI", Uri.parse(path))
            val ok = runCatching {
                ctx.startActivity(intent)
            }.isSuccess
            if (ok) return true
        }
        return false
    }

    private fun documentTreeUriForPath(path: String): Uri {
        val normalized = path.replace("\\", "/")
        val withoutFile = if (normalized.endsWith(".zip")) {
            normalized.substringBeforeLast("/", "")
        } else {
            normalized
        }
        val marker = "/storage/emulated/0/"
        val relative = if (withoutFile.startsWith(marker)) {
            withoutFile.removePrefix(marker)
        } else {
            "Download/GS-Camera"
        }
        val documentId = "primary:$relative"
        return DocumentsContract.buildTreeDocumentUri(
            "com.android.externalstorage.documents",
            documentId,
        )
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        previewSink = events
    }

    override fun onCancel(arguments: Any?) {
        previewSink = null
    }
}
