package com.gscamera.gs_camera

import android.content.Context
import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.SurfaceTexture
import android.hardware.camera2.*
import android.media.ImageReader
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.util.Log
import android.util.Size
import android.view.Surface
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Camera2 session tuned for Gaussian Splatting.
 *
 * Adapts to the device's hardware level:
 *   - FULL / LEVEL_3 with MANUAL_SENSOR  -> use LENS_FOCUS_DISTANCE for true
 *     manual focus lock, plus CONTROL_AE_LOCK / CONTROL_AWB_LOCK.
 *   - LIMITED / LEGACY (typical mid-range phones)  -> rely on AE_LOCK,
 *     AWB_LOCK and CONTROL_AF_TRIGGER_CANCEL after a single auto-focus
 *     sweep, which on virtually every Android device freezes the focus
 *     ring at the current distance.
 */
class CameraSession(
    private val ctx: Context,
    private val handler: Handler,
    private val previewSurface: Surface,
    private val previewSurfaceTexture: SurfaceTexture,
    private val onPreviewFrame: (PreviewFrame) -> Unit,
) {
    data class PreviewFrame(
        val luma: ByteArray,
        val width: Int,
        val height: Int,
        val timestampMs: Long,
    )

    private data class CameraInfo(
        val id: String,
        val focalMm: Float,
        val label: String,
        val sensorWidthMm: Float,
        val sensorHeightMm: Float,
        val activeArrayWidth: Int,
        val activeArrayHeight: Int,
        val realTele: Boolean = false,
    )

    private data class CameraSelection(
        val info: CameraInfo,
        val requestedName: String,
        val resolvedIndex: Int,
        val reason: String,
        val inventory: List<CameraInfo>,
    )

    private val cm = ctx.getSystemService(Context.CAMERA_SERVICE) as CameraManager
    private var device: CameraDevice? = null
    private var session: CameraCaptureSession? = null
    private var previewReader: ImageReader? = null
    private var jpegReader: ImageReader? = null

    private var cameraId: String = ""
    private var captureSize: Size = Size(0, 0)
    private var previewSize: Size = Size(320, 240)
    private var displayPreviewSize: Size = Size(1280, 720)
    private var sensorOrientation: Int = 0
    private var currentCameraIndex: Int = 1
    private var currentCameraName: String = "main"
    private var currentFocalLengthMm: Float = 0f
    private var cameraInventory: List<CameraInfo> = emptyList()

    private var supportsManualSensor = false
    private var supportedNrModes: IntArray = intArrayOf()
    private var supportedEdgeModes: IntArray = intArrayOf()
    private var supportedHotPixelModes: IntArray = intArrayOf()
    private var supportedOisModes: IntArray = intArrayOf()
    private var sensorIsoMin: Int = 50
    private var sensorIsoMax: Int = 3200
    private var sensorExposureMinNs: Long = 1_000_000L
    private var sensorExposureMaxNs: Long = 1_000_000_000L

    private var lockedExposureNs: Long = 0
    private var lockedIso: Int = 0
    private var lockedFocusDistance: Float = 0f
    private val isCapturing = AtomicBoolean(false)
    private var lastPreviewFrameEmitMs: Long = 0

    // Preview analysis does not need camera-frame rate. Throttling here
    // avoids pushing large Y planes over the Flutter bridge every frame.
    private val previewFrameMinIntervalMs: Long = 250

    /**
     * 1 / 125 s = 8 ms = 8,000,000 ns. Industry guidance for handheld
     * Gaussian Splatting capture: anything slower than this lets motion
     * blur slip through and breaks postshot's pose estimation. We override
     * AE to keep shutter at or below this on devices that support manual
     * sensor control.
     */
    private val shutterFloorNs: Long = 8_000_000L

    fun openAndCalibrate(
        cameraIndex: Int = 1,
        onResult: (Map<String, Any>?, Throwable?) -> Unit
    ) {
        try {
            val selection = pickBackCamera(cameraIndex.coerceIn(0, 2))
            currentCameraIndex = selection.resolvedIndex
            currentCameraName = selection.info.label
            currentFocalLengthMm = selection.info.focalMm
            cameraInventory = selection.inventory
            cameraId = selection.info.id
            Log.i(TAG, "requested lens=${selection.requestedName} " +
                "selected lens=$currentCameraName camera_id=$cameraId " +
                "focal=${currentFocalLengthMm}mm reason=${selection.reason}")
            val chars = cm.getCameraCharacteristics(cameraId)

            val streamMap = chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
                ?: throw RuntimeException("camera reports no stream configuration map")
            captureSize = streamMap.getOutputSizes(ImageFormat.JPEG)
                ?.maxByOrNull { it.width.toLong() * it.height }
                ?: throw RuntimeException("camera supports no JPEG output sizes")
            val yuvSizes = streamMap.getOutputSizes(ImageFormat.YUV_420_888)
                ?.toList()
                ?: emptyList()
            previewSize = yuvSizes
                .filter { it.width <= 320 && it.height <= 240 }
                .maxByOrNull { it.width.toLong() * it.height }
                ?: yuvSizes
                    .filter { it.width <= 640 && it.height <= 480 }
                    .minByOrNull { it.width.toLong() * it.height }
                ?: Size(320, 240)
            // Display surface: a "preview-sized" output for what the user sees
            // on screen. Camera2 LIMITED guarantees PRIV+YUV+JPEG combo as
            // long as PRIV stays at PREVIEW size (≤1920×1080).
            displayPreviewSize = streamMap.getOutputSizes(SurfaceTexture::class.java)
                ?.filter { it.width <= 1280 && it.height <= 720 }
                ?.maxByOrNull { it.width.toLong() * it.height }
                ?: Size(1280, 720)
            previewSurfaceTexture.setDefaultBufferSize(
                displayPreviewSize.width, displayPreviewSize.height
            )
            sensorOrientation = chars.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0

            val capabilities = chars.get(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES)
                ?: intArrayOf()
            supportsManualSensor = capabilities.contains(
                CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_MANUAL_SENSOR
            )
            supportedNrModes = chars.get(
                CameraCharacteristics.NOISE_REDUCTION_AVAILABLE_NOISE_REDUCTION_MODES
            ) ?: intArrayOf()
            supportedEdgeModes = chars.get(
                CameraCharacteristics.EDGE_AVAILABLE_EDGE_MODES
            ) ?: intArrayOf()
            supportedHotPixelModes = chars.get(
                CameraCharacteristics.HOT_PIXEL_AVAILABLE_HOT_PIXEL_MODES
            ) ?: intArrayOf()
            supportedOisModes = chars.get(
                CameraCharacteristics.LENS_INFO_AVAILABLE_OPTICAL_STABILIZATION
            ) ?: intArrayOf()
            chars.get(CameraCharacteristics.SENSOR_INFO_SENSITIVITY_RANGE)?.let {
                sensorIsoMin = it.lower
                sensorIsoMax = it.upper
            }
            chars.get(CameraCharacteristics.SENSOR_INFO_EXPOSURE_TIME_RANGE)?.let {
                sensorExposureMinNs = it.lower
                sensorExposureMaxNs = it.upper
            }

            Log.i(TAG, "camera $cameraId capture=$captureSize yuv=$previewSize " +
                "display=$displayPreviewSize manualSensor=$supportsManualSensor " +
                "iso=[$sensorIsoMin..$sensorIsoMax] " +
                "exposure=[${sensorExposureMinNs}ns..${sensorExposureMaxNs}ns]")

            previewReader = ImageReader.newInstance(
                previewSize.width, previewSize.height, ImageFormat.YUV_420_888, 4
            ).apply { setOnImageAvailableListener(::onPreviewImage, handler) }

            jpegReader = ImageReader.newInstance(
                captureSize.width, captureSize.height, ImageFormat.JPEG, 2
            )

            cm.openCamera(cameraId, object : CameraDevice.StateCallback() {
                override fun onOpened(d: CameraDevice) {
                    device = d
                    try {
                        createSession(onResult)
                    } catch (t: Throwable) {
                        Log.e(TAG, "createSession threw", t)
                        onResult(null, t)
                    }
                }
                override fun onDisconnected(d: CameraDevice) {
                    Log.w(TAG, "camera disconnected")
                    d.close(); device = null
                }
                override fun onError(d: CameraDevice, error: Int) {
                    Log.e(TAG, "camera open error $error")
                    d.close(); device = null
                    onResult(null, RuntimeException("camera open error $error"))
                }
            }, handler)
        } catch (t: Throwable) {
            Log.e(TAG, "openAndCalibrate threw", t)
            onResult(null, t)
        }
    }

    private fun onPreviewImage(reader: ImageReader) {
        val img = reader.acquireLatestImage() ?: return
        try {
            val now = System.currentTimeMillis()
            if (now - lastPreviewFrameEmitMs < previewFrameMinIntervalMs) return
            lastPreviewFrameEmitMs = now

            val plane = img.planes[0]
            val buf = plane.buffer
            val rowStride = plane.rowStride
            val pixelStride = plane.pixelStride
            val w = img.width
            val h = img.height
            val out = ByteArray(w * h)
            if (rowStride == w && pixelStride == 1) {
                buf.get(out, 0, w * h)
            } else {
                val row = ByteArray(rowStride)
                for (y in 0 until h) {
                    buf.position(y * rowStride)
                    buf.get(row, 0, minOf(rowStride, buf.remaining()))
                    if (pixelStride == 1) {
                        System.arraycopy(row, 0, out, y * w, w)
                    } else {
                        var di = y * w
                        var si = 0
                        for (x in 0 until w) {
                            out[di++] = row[si]
                            si += pixelStride
                        }
                    }
                }
            }
            onPreviewFrame(PreviewFrame(out, w, h, now))
        } catch (t: Throwable) {
            Log.w(TAG, "preview frame parse failed", t)
        } finally {
            img.close()
        }
    }

    private fun createSession(onResult: (Map<String, Any>?, Throwable?) -> Unit) {
        val d = device ?: return onResult(null, IllegalStateException("device closed"))
        val yuvSurface = previewReader?.surface
            ?: return onResult(null, IllegalStateException("preview reader missing"))
        val jpegSurface = jpegReader?.surface
            ?: return onResult(null, IllegalStateException("jpeg reader missing"))
        // Three outputs: PRIV preview-sized for the on-screen Texture,
        // YUV preview-sized for blur/lighting analysis, JPEG max-sized for
        // captures. Camera2 LIMITED guarantees this combo.
        val surfaces = listOf(previewSurface, yuvSurface, jpegSurface)

        val callback = object : CameraCaptureSession.StateCallback() {
            override fun onConfigured(s: CameraCaptureSession) {
                session = s
                try {
                    runCalibrationSweep(onResult)
                } catch (t: Throwable) {
                    Log.e(TAG, "calibration sweep threw", t)
                    onResult(null, t)
                }
            }
            override fun onConfigureFailed(s: CameraCaptureSession) {
                Log.e(TAG, "session configure failed")
                onResult(null, RuntimeException("camera session configure failed"))
            }
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val outputs = surfaces.map { android.hardware.camera2.params.OutputConfiguration(it) }
            val sessionCfg = android.hardware.camera2.params.SessionConfiguration(
                android.hardware.camera2.params.SessionConfiguration.SESSION_REGULAR,
                outputs,
                { it.run() },
                callback,
            )
            d.createCaptureSession(sessionCfg)
        } else {
            @Suppress("DEPRECATION")
            d.createCaptureSession(surfaces, callback, handler)
        }
    }

    /**
     * Run a repeating preview request that drives AE/AWB/AF to convergence,
     * then transition to a locked repeating request.
     */
    private fun runCalibrationSweep(onResult: (Map<String, Any>?, Throwable?) -> Unit) {
        val s = session ?: return onResult(null, IllegalStateException("no session"))
        val d = device ?: return onResult(null, IllegalStateException("no device"))

        val sweepBuilder = d.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW).apply {
            addTarget(previewSurface)
            addTarget(previewReader!!.surface)
            applySafeQualityFlags(this)
            set(CaptureRequest.CONTROL_MODE, CameraMetadata.CONTROL_MODE_AUTO)
            set(CaptureRequest.CONTROL_AE_MODE, CameraMetadata.CONTROL_AE_MODE_ON)
            set(CaptureRequest.CONTROL_AF_MODE,
                CameraMetadata.CONTROL_AF_MODE_CONTINUOUS_PICTURE)
            set(CaptureRequest.CONTROL_AWB_MODE, CameraMetadata.CONTROL_AWB_MODE_AUTO)
        }

        var convergedHandled = false
        val sweepCallback = object : CameraCaptureSession.CaptureCallback() {
            override fun onCaptureCompleted(
                session: CameraCaptureSession,
                request: CaptureRequest,
                tot: TotalCaptureResult,
            ) {
                if (convergedHandled) return
                val ae = tot.get(CaptureResult.CONTROL_AE_STATE)
                val awb = tot.get(CaptureResult.CONTROL_AWB_STATE)
                val af = tot.get(CaptureResult.CONTROL_AF_STATE)

                val aeOk = ae == CaptureResult.CONTROL_AE_STATE_CONVERGED ||
                        ae == CaptureResult.CONTROL_AE_STATE_FLASH_REQUIRED ||
                        ae == CaptureResult.CONTROL_AE_STATE_LOCKED
                val awbOk = awb == null ||
                        awb == CaptureResult.CONTROL_AWB_STATE_CONVERGED ||
                        awb == CaptureResult.CONTROL_AWB_STATE_LOCKED
                val afOk = af == null ||
                        af == CaptureResult.CONTROL_AF_STATE_PASSIVE_FOCUSED ||
                        af == CaptureResult.CONTROL_AF_STATE_FOCUSED_LOCKED ||
                        af == CaptureResult.CONTROL_AF_STATE_PASSIVE_UNFOCUSED ||
                        af == CaptureResult.CONTROL_AF_STATE_NOT_FOCUSED_LOCKED

                if (aeOk && awbOk && afOk) {
                    convergedHandled = true
                    val measuredExposure =
                        tot.get(CaptureResult.SENSOR_EXPOSURE_TIME) ?: 0L
                    val measuredIso =
                        tot.get(CaptureResult.SENSOR_SENSITIVITY) ?: 0
                    val capped = capExposureForBlur(measuredExposure, measuredIso)
                    lockedExposureNs = capped.first
                    lockedIso = capped.second
                    lockedFocusDistance =
                        tot.get(CaptureResult.LENS_FOCUS_DISTANCE) ?: 0f
                    Log.i(TAG, "AE converged: measured=${measuredExposure}ns/${measuredIso}iso " +
                        "→ locked=${lockedExposureNs}ns/${lockedIso}iso " +
                        "manual=$supportsManualSensor")
                    try {
                        applyLockedRepeating(s, d)
                        onResult(buildConfigMap(), null)
                    } catch (t: Throwable) {
                        Log.e(TAG, "applying locked repeating failed", t)
                        onResult(null, t)
                    }
                }
            }

            override fun onCaptureFailed(
                session: CameraCaptureSession,
                request: CaptureRequest,
                failure: CaptureFailure,
            ) {
                if (convergedHandled) return
                convergedHandled = true
                onResult(null, RuntimeException("calibration capture failed: ${failure.reason}"))
            }
        }

        s.setRepeatingRequest(sweepBuilder.build(), sweepCallback, handler)

        // Safety net: even on a quirky device, after 4 seconds we accept
        // whatever values we have rather than hanging forever.
        handler.postDelayed({
            if (!convergedHandled) {
                convergedHandled = true
                Log.w(TAG, "calibration timed out — locking with last known values")
                try {
                    applyLockedRepeating(s, d)
                    onResult(buildConfigMap(), null)
                } catch (t: Throwable) {
                    onResult(null, t)
                }
            }
        }, 4000)
    }

    private fun applyLockedRepeating(s: CameraCaptureSession, d: CameraDevice) {
        val locked = d.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW).apply {
            addTarget(previewSurface)
            addTarget(previewReader!!.surface)
            applySafeQualityFlags(this)
            set(CaptureRequest.CONTROL_MODE, CameraMetadata.CONTROL_MODE_AUTO)
            applyExposureLock(this)
            set(CaptureRequest.CONTROL_AWB_LOCK, true)
            applyFocusLock(this)
        }
        s.setRepeatingRequest(locked.build(), null, handler)
    }

    /**
     * Lock exposure for the rest of the session.
     *
     * On phones with manual sensor support we explicitly set
     * [SENSOR_EXPOSURE_TIME] / [SENSOR_SENSITIVITY] to the values produced
     * by [capExposureForBlur], which guarantees a fast-enough shutter.
     * On limited phones we fall back to [CONTROL_AE_LOCK], which freezes
     * whatever the auto-exposure picked — not always blur-safe but better
     * than nothing.
     */
    private fun applyExposureLock(b: CaptureRequest.Builder) {
        if (supportsManualSensor && lockedExposureNs > 0 && lockedIso > 0) {
            b.set(CaptureRequest.CONTROL_AE_MODE,
                CameraMetadata.CONTROL_AE_MODE_OFF)
            b.set(CaptureRequest.SENSOR_EXPOSURE_TIME, lockedExposureNs)
            b.set(CaptureRequest.SENSOR_SENSITIVITY, lockedIso)
        } else {
            b.set(CaptureRequest.CONTROL_AE_LOCK, true)
        }
    }

    /**
     * If [exposureNs] is slower than the blur-safe shutter floor and the
     * device supports manual sensor control, cap it at the floor and
     * raise ISO proportionally to keep the same overall exposure value.
     * Returns (exposureNs, iso) clamped to the device's supported ranges.
     */
    private fun capExposureForBlur(exposureNs: Long, iso: Int): Pair<Long, Int> {
        if (!supportsManualSensor) return exposureNs to iso
        if (exposureNs <= shutterFloorNs) return exposureNs to iso
        val ratio = exposureNs.toDouble() / shutterFloorNs.toDouble()
        val targetIso = (iso * ratio).toInt()
            .coerceIn(sensorIsoMin, sensorIsoMax)
        val newExposure = shutterFloorNs.coerceIn(
            sensorExposureMinNs, sensorExposureMaxNs
        )
        return newExposure to targetIso
    }

    private fun applyFocusLock(b: CaptureRequest.Builder) {
        if (supportsManualSensor && lockedFocusDistance > 0f) {
            b.set(CaptureRequest.CONTROL_AF_MODE, CameraMetadata.CONTROL_AF_MODE_OFF)
            b.set(CaptureRequest.LENS_FOCUS_DISTANCE, lockedFocusDistance)
        } else {
            // Fall back: keep continuous-picture but cancel the AF trigger so
            // the lens stops hunting. Most Android cameras hold the last
            // achieved focus distance under this combo.
            b.set(CaptureRequest.CONTROL_AF_MODE,
                CameraMetadata.CONTROL_AF_MODE_CONTINUOUS_PICTURE)
            b.set(CaptureRequest.CONTROL_AF_TRIGGER,
                CameraMetadata.CONTROL_AF_TRIGGER_CANCEL)
        }
    }

    fun captureJpeg(onResult: (String?, Throwable?) -> Unit) {
        if (isCapturing.getAndSet(true)) {
            return onResult(null, IllegalStateException("capture already in flight"))
        }
        val s = session ?: run {
            isCapturing.set(false); return onResult(null, IllegalStateException("no session"))
        }
        val d = device ?: run {
            isCapturing.set(false); return onResult(null, IllegalStateException("no device"))
        }

        val out = File(captureDir(), "tmp_${System.currentTimeMillis()}.jpg")
        val completed = AtomicBoolean(false)
        val timeoutRunnable = Runnable {
            if (!completed.compareAndSet(false, true)) return@Runnable
            Log.w(TAG, "still capture timed out; releasing capture lock")
            runCatching { jpegReader?.setOnImageAvailableListener(null, null) }
            isCapturing.set(false)
            onResult(null, RuntimeException("still capture timed out"))
        }
        handler.postDelayed(timeoutRunnable, 5000)
        fun finish(path: String?, err: Throwable?) {
            if (!completed.compareAndSet(false, true)) return
            handler.removeCallbacks(timeoutRunnable)
            runCatching { jpegReader?.setOnImageAvailableListener(null, null) }
            isCapturing.set(false)
            onResult(path, err)
        }
        jpegReader!!.setOnImageAvailableListener({ r ->
            val img = r.acquireNextImage() ?: return@setOnImageAvailableListener
            try {
                val buf: ByteBuffer = img.planes[0].buffer
                val bytes = ByteArray(buf.remaining())
                buf.get(bytes)
                FileOutputStream(out).use { it.write(bytes) }
                finish(out.absolutePath, null)
            } catch (t: Throwable) {
                finish(null, t)
            } finally {
                img.close()
            }
        }, handler)

        try {
            val builder = d.createCaptureRequest(CameraDevice.TEMPLATE_STILL_CAPTURE).apply {
                addTarget(jpegReader!!.surface)
                applySafeQualityFlags(this)
                applyExposureLock(this)
                set(CaptureRequest.CONTROL_AWB_LOCK, true)
                applyFocusLock(this)
                // Quality 98 keeps JPEG artefacts well under postshot's
                // SfM noise floor without ballooning file size like 100
                // does (which disables Huffman optimisation on some
                // ISPs and produces 1.5× bigger files for no quality
                // gain).
                set(CaptureRequest.JPEG_QUALITY, 98.toByte())
                set(CaptureRequest.JPEG_ORIENTATION, sensorOrientation)
            }
            s.capture(builder.build(), object : CameraCaptureSession.CaptureCallback() {
                override fun onCaptureFailed(
                    session: CameraCaptureSession,
                    request: CaptureRequest,
                    failure: CaptureFailure,
                ) {
                    finish(null, RuntimeException("still capture failed: ${failure.reason}"))
                }
            }, handler)
        } catch (t: Throwable) {
            finish(null, t)
        }
    }

    fun recalibrate(onResult: (Map<String, Any>?, Throwable?) -> Unit) {
        try {
            runCalibrationSweep(onResult)
        } catch (t: Throwable) {
            onResult(null, t)
        }
    }

    fun selectCamera(cameraIndex: Int, onResult: (Map<String, Any>?, Throwable?) -> Unit) {
        close()
        openAndCalibrate(cameraIndex, onResult)
    }

    fun intrinsicsFor(cameraIndex: Int): Map<String, Double> {
        val id = pickBackCamera(cameraIndex.coerceIn(0, 2)).info.id
        val chars = cm.getCameraCharacteristics(id)
        val intr = chars.get(CameraCharacteristics.LENS_INTRINSIC_CALIBRATION)
        val streamMap = chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
        val size = streamMap?.getOutputSizes(ImageFormat.JPEG)
            ?.maxByOrNull { it.width.toLong() * it.height }
            ?: Size(0, 0)
        return mapOf(
            "fx" to ((intr?.getOrNull(0) ?: 0f).toDouble()),
            "fy" to ((intr?.getOrNull(1) ?: 0f).toDouble()),
            "cx" to ((intr?.getOrNull(2) ?: (size.width / 2f)).toDouble()),
            "cy" to ((intr?.getOrNull(3) ?: (size.height / 2f)).toDouble()),
            "width" to size.width.toDouble(),
            "height" to size.height.toDouble(),
        )
    }

    fun cameraList(): List<Map<String, Any>> = cameraInventoryMap(ctx)

    fun close() {
        runCatching { session?.close() }
        runCatching { device?.close() }
        runCatching { previewReader?.close() }
        runCatching { jpegReader?.close() }
        session = null
        device = null
        previewReader = null
        jpegReader = null
    }

    /**
     * Pick the standard "main" back camera. Multi-camera phones expose
     * ultrawide and telephoto lenses too; ultrawide is bad for Gaussian
     * Splatting because the heavy distortion confuses pose estimation, and
     * telephoto rarely covers enough of the scene.
     *
     * Heuristic: among back-facing cameras with BACKWARD_COMPATIBLE
     * capability, prefer focal lengths in the standard 4–7 mm range
     * (≈ 26–50 mm 35-mm equivalent on a typical phone sensor) and break
     * ties by sensor area (the main lens almost always has the biggest
     * sensor).
     */
    private fun pickBackCamera(cameraIndex: Int = 1): CameraSelection {
        val inventory = backCameraInventory()
        if (inventory.isEmpty()) {
            throw RuntimeException("no suitable back camera available")
        }

        val requestedName = lensName(cameraIndex)
        val main = inventory.firstOrNull { it.label == "main" }
            ?: inventory.minByOrNull { kotlin.math.abs(it.focalMm - 5.0f) }
            ?: inventory.first()
        val selected = when (requestedName) {
            "uw" -> inventory.firstOrNull { it.label == "uw" } ?: main
            "tele" -> inventory.firstOrNull { it.label == "tele" } ?: main
            else -> main
        }
        val reason = if (selected.label == requestedName) {
            "direct"
        } else {
            "fallback_to_${selected.label}"
        }
        return CameraSelection(
            info = selected,
            requestedName = requestedName,
            resolvedIndex = lensIndex(selected.label),
            reason = reason,
            inventory = inventory,
        )
    }

    private fun backCameraInventory(): List<CameraInfo> {
        val raw = collectBackCameraInfo(cm)
        if (raw.isEmpty()) return emptyList()

        val sorted = raw.sortedBy { it.focalMm }
        val main = sorted.minByOrNull { kotlin.math.abs(it.focalMm - 5.0f) }
            ?: sorted.last()
        val uw = sorted
            .filter { it.focalMm < 2.5f && it.focalMm < main.focalMm - 0.5f }
            .minByOrNull { it.focalMm }
        val tele = sorted
            .filter { isRealTeleCandidate(it, main) }
            .maxByOrNull { it.focalMm }

        return sorted.map { info ->
            val label = when (info.id) {
                tele?.id -> "tele"
                uw?.id -> "uw"
                main.id -> "main"
                else -> "main"
            }
            val realTele = label == "tele"
            Log.i(TAG, "back camera ${info.id} focal=${info.focalMm}mm " +
                "sensor=${info.sensorWidthMm}x${info.sensorHeightMm} " +
                "active=${info.activeArrayWidth}x${info.activeArrayHeight} " +
                "label=$label realTele=$realTele")
            info.copy(label = label, realTele = realTele)
        }
    }

    private fun lensName(cameraIndex: Int): String = when (cameraIndex.coerceIn(0, 2)) {
        0 -> "uw"
        2 -> "tele"
        else -> "main"
    }

    private fun lensIndex(label: String): Int = when (label) {
        "uw" -> 0
        "tele" -> 2
        else -> 1
    }

    /**
     * Push the camera away from "make it look pretty" defaults that break
     * postshot, but only set fields the device actually supports. Samsung,
     * Xiaomi, etc. throw or silently drop the request when an unsupported
     * mode is set.
     */
    private fun applySafeQualityFlags(b: CaptureRequest.Builder) {
        b.set(CaptureRequest.CONTROL_SCENE_MODE, CameraMetadata.CONTROL_SCENE_MODE_DISABLED)
        b.set(CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE,
            CameraMetadata.CONTROL_VIDEO_STABILIZATION_MODE_OFF)
        b.set(CaptureRequest.CONTROL_EFFECT_MODE,
            CameraMetadata.CONTROL_EFFECT_MODE_OFF)
        if (CameraMetadata.NOISE_REDUCTION_MODE_FAST in supportedNrModes) {
            b.set(CaptureRequest.NOISE_REDUCTION_MODE,
                CameraMetadata.NOISE_REDUCTION_MODE_FAST)
        }
        if (CameraMetadata.EDGE_MODE_FAST in supportedEdgeModes) {
            b.set(CaptureRequest.EDGE_MODE, CameraMetadata.EDGE_MODE_FAST)
        }
        if (CameraMetadata.HOT_PIXEL_MODE_FAST in supportedHotPixelModes) {
            b.set(CaptureRequest.HOT_PIXEL_MODE, CameraMetadata.HOT_PIXEL_MODE_FAST)
        }
        if (CameraMetadata.LENS_OPTICAL_STABILIZATION_MODE_ON in supportedOisModes) {
            b.set(CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE,
                CameraMetadata.LENS_OPTICAL_STABILIZATION_MODE_ON)
        }
        // postshot's photometric loss assumes a roughly linear tone
        // response across all input frames. The default ISP applies
        // an aggressive S-curve plus per-frame contrast adjustments;
        // CONTRAST_CURVE / GAMMA_VALUE are the closest "consistent
        // look" modes that all Camera2 LIMITED+ devices accept.
        b.set(CaptureRequest.TONEMAP_MODE,
            CameraMetadata.TONEMAP_MODE_GAMMA_VALUE)
        b.set(CaptureRequest.TONEMAP_GAMMA, 2.2f)
        // Lock colour correction so AWB drift can't change colour
        // balance between adjacent frames once the session starts.
        b.set(CaptureRequest.COLOR_CORRECTION_MODE,
            CameraMetadata.COLOR_CORRECTION_MODE_HIGH_QUALITY)
    }

    private fun captureDir(): File {
        val pics = ctx.getExternalFilesDir(Environment.DIRECTORY_PICTURES)
            ?: ctx.filesDir
        val dir = File(pics, "tmp")
        if (!dir.exists()) dir.mkdirs()
        return dir
    }

    private fun buildConfigMap(): Map<String, Any> = mapOf(
        "iso" to lockedIso,
        "shutter_speed_ns" to lockedExposureNs,
        "exposure_value" to (lockedIso * (lockedExposureNs / 1e9)),
        "focus_distance" to lockedFocusDistance.toDouble(),
        "preview_width" to previewSize.width,
        "preview_height" to previewSize.height,
        "capture_width" to captureSize.width,
        "capture_height" to captureSize.height,
        "display_preview_width" to displayPreviewSize.width,
        "display_preview_height" to displayPreviewSize.height,
        "sensor_orientation" to sensorOrientation,
        "camera_index" to currentCameraIndex,
        "camera_name" to currentCameraName,
        "camera_id" to cameraId,
        "focal_length_mm" to currentFocalLengthMm.toDouble(),
        "available_lenses" to cameraInventory.map { it.label }.distinct(),
        "camera_inventory" to cameraInventory.map {
            mapOf(
                "camera_id" to it.id,
                "camera_name" to it.label,
                "focal_length_mm" to it.focalMm.toDouble(),
                "sensor_width_mm" to it.sensorWidthMm.toDouble(),
                "sensor_height_mm" to it.sensorHeightMm.toDouble(),
                "active_array_width" to it.activeArrayWidth,
                "active_array_height" to it.activeArrayHeight,
                "real_tele" to it.realTele,
            )
        },
        "real_tele_available" to cameraInventory.any { it.realTele },
    )

    private operator fun IntArray.contains(v: Int): Boolean = indexOf(v) >= 0

    companion object {
        private const val TAG = "GsCameraSession"

        fun intrinsicsFor(ctx: Context, cameraIndex: Int): Map<String, Double> {
            val cm = ctx.getSystemService(Context.CAMERA_SERVICE) as CameraManager
            val labeled = cameraInventoryMap(ctx)
            if (labeled.isEmpty()) throw RuntimeException("no back camera")
            val requested = when (cameraIndex.coerceIn(0, 2)) {
                0 -> "uw"
                2 -> "tele"
                else -> "main"
            }
            val selected = labeled.firstOrNull { it["camera_name"] == requested }
                ?: labeled.firstOrNull { it["camera_name"] == "main" }
                ?: labeled.first()
            val id = selected["camera_id"] as String
            val chars = cm.getCameraCharacteristics(id)
            val intr = chars.get(CameraCharacteristics.LENS_INTRINSIC_CALIBRATION)
            val streamMap = chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            val size = streamMap?.getOutputSizes(ImageFormat.JPEG)
                ?.maxByOrNull { it.width.toLong() * it.height }
                ?: Size(0, 0)
            return mapOf(
                "fx" to ((intr?.getOrNull(0) ?: 0f).toDouble()),
                "fy" to ((intr?.getOrNull(1) ?: 0f).toDouble()),
                "cx" to ((intr?.getOrNull(2) ?: (size.width / 2f)).toDouble()),
                "cy" to ((intr?.getOrNull(3) ?: (size.height / 2f)).toDouble()),
                "width" to size.width.toDouble(),
                "height" to size.height.toDouble(),
            )
        }

        fun cameraInventoryMap(ctx: Context): List<Map<String, Any>> {
            val cm = ctx.getSystemService(Context.CAMERA_SERVICE) as CameraManager
            val raw = collectBackCameraInfo(cm)
            if (raw.isEmpty()) return emptyList()
            val sorted = raw.sortedBy { it.focalMm }
            val main = sorted.minByOrNull { kotlin.math.abs(it.focalMm - 5.0f) }
                ?: sorted.last()
            val uw = sorted
                .filter { it.focalMm < 2.5f && it.focalMm < main.focalMm - 0.5f }
                .minByOrNull { it.focalMm }
            val tele = sorted
                .filter { isRealTeleCandidate(it, main) }
                .maxByOrNull { it.focalMm }
            return sorted.map { info ->
                val label = when (info.id) {
                    tele?.id -> "tele"
                    uw?.id -> "uw"
                    main.id -> "main"
                    else -> "main"
                }
                cameraInfoMap(info.copy(label = label, realTele = label == "tele"))
            }
        }

        private fun collectBackCameraInfo(cm: CameraManager): List<CameraInfo> {
            val out = mutableListOf<CameraInfo>()
            for (id in cm.cameraIdList) {
                val chars = cm.getCameraCharacteristics(id)
                if (chars.get(CameraCharacteristics.LENS_FACING) !=
                    CameraCharacteristics.LENS_FACING_BACK) continue
                val capabilities = chars.get(
                    CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES
                ) ?: intArrayOf()
                if (capabilities.indexOf(
                        CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_BACKWARD_COMPATIBLE
                    ) < 0) continue

                val focalMm = chars.get(
                    CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS
                )?.firstOrNull() ?: 0f
                val physical = chars.get(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE)
                val active: Rect? = chars.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE)
                out.add(
                    CameraInfo(
                        id = id,
                        focalMm = focalMm,
                        label = "main",
                        sensorWidthMm = physical?.width ?: 0f,
                        sensorHeightMm = physical?.height ?: 0f,
                        activeArrayWidth = active?.width() ?: 0,
                        activeArrayHeight = active?.height() ?: 0,
                    )
                )
            }
            return out
        }

        private fun isRealTeleCandidate(info: CameraInfo, main: CameraInfo): Boolean {
            val focalLooksTele = info.focalMm > 7.0f && info.focalMm > main.focalMm + 1.5f
            val hasSensorData = info.sensorWidthMm > 0f && main.sensorWidthMm > 0f
            val sensorDiffers = if (hasSensorData) {
                kotlin.math.abs(info.sensorWidthMm - main.sensorWidthMm) > 0.2f ||
                    kotlin.math.abs(info.sensorHeightMm - main.sensorHeightMm) > 0.2f ||
                    kotlin.math.abs(info.activeArrayWidth - main.activeArrayWidth) > 200 ||
                    kotlin.math.abs(info.activeArrayHeight - main.activeArrayHeight) > 200
            } else {
                true
            }
            return focalLooksTele && sensorDiffers
        }

        private fun cameraInfoMap(info: CameraInfo): Map<String, Any> = mapOf(
            "camera_id" to info.id,
            "camera_name" to info.label,
            "focal_length_mm" to info.focalMm.toDouble(),
            "sensor_width_mm" to info.sensorWidthMm.toDouble(),
            "sensor_height_mm" to info.sensorHeightMm.toDouble(),
            "active_array_width" to info.activeArrayWidth,
            "active_array_height" to info.activeArrayHeight,
            "real_tele" to info.realTele,
        )
    }
}
