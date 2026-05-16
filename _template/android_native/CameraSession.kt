package com.gscamera

import android.content.Context
import android.graphics.ImageFormat
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
 * Owns a Camera2 capture session tuned for Gaussian Splatting:
 *
 * - Picks the back camera with the largest sensor.
 * - Runs an AE/AF/AWB sweep on session open, then locks those values via
 *   CONTROL_AE_LOCK / CONTROL_AWB_LOCK and a fixed LENS_FOCUS_DISTANCE.
 * - Disables HDR / scene mode / aggressive noise reduction.
 * - Holds two ImageReaders: one YUV at preview resolution streamed to
 *   Dart for blur/lighting analysis, one JPEG at full resolution for
 *   the actual captures.
 */
class CameraSession(
    private val ctx: Context,
    private val handler: Handler,
    private val onPreviewFrame: (PreviewFrame) -> Unit,
) {
    data class PreviewFrame(
        val luma: ByteArray,
        val width: Int,
        val height: Int,
        val timestampMs: Long,
    )

    private val cm = ctx.getSystemService(Context.CAMERA_SERVICE) as CameraManager
    private var device: CameraDevice? = null
    private var session: CameraCaptureSession? = null
    private var previewReader: ImageReader? = null
    private var jpegReader: ImageReader? = null

    private var cameraId: String = ""
    private var captureSize: Size = Size(0, 0)
    private var previewSize: Size = Size(320, 240)
    private var sensorOrientation: Int = 0

    private var lockedExposureNs: Long = 0
    private var lockedIso: Int = 0
    private var lockedFocusDistance: Float = 0f
    private val isCapturing = AtomicBoolean(false)

    fun openAndCalibrate(onResult: (Map<String, Any>?, Throwable?) -> Unit) {
        try {
            cameraId = pickBackCamera()
            val chars = cm.getCameraCharacteristics(cameraId)
            val streamMap = chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)!!
            captureSize = streamMap.getOutputSizes(ImageFormat.JPEG)
                .maxByOrNull { it.width.toLong() * it.height } ?: Size(4032, 3024)
            previewSize = streamMap.getOutputSizes(ImageFormat.YUV_420_888)
                .filter { it.width <= 640 }
                .maxByOrNull { it.width.toLong() * it.height } ?: Size(320, 240)
            sensorOrientation = chars.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0

            previewReader = ImageReader.newInstance(
                previewSize.width, previewSize.height, ImageFormat.YUV_420_888, 4
            ).apply {
                setOnImageAvailableListener({ reader ->
                    val img = reader.acquireLatestImage() ?: return@setOnImageAvailableListener
                    try {
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
                        onPreviewFrame(PreviewFrame(
                            luma = out,
                            width = w,
                            height = h,
                            timestampMs = System.currentTimeMillis(),
                        ))
                    } finally {
                        img.close()
                    }
                }, handler)
            }

            jpegReader = ImageReader.newInstance(
                captureSize.width, captureSize.height, ImageFormat.JPEG, 2
            )

            cm.openCamera(cameraId, object : CameraDevice.StateCallback() {
                override fun onOpened(d: CameraDevice) {
                    device = d
                    createSession(onResult)
                }
                override fun onDisconnected(d: CameraDevice) {
                    d.close()
                    device = null
                }
                override fun onError(d: CameraDevice, error: Int) {
                    d.close()
                    device = null
                    onResult(null, RuntimeException("Camera open error $error"))
                }
            }, handler)
        } catch (t: Throwable) {
            onResult(null, t)
        }
    }

    private fun createSession(onResult: (Map<String, Any>?, Throwable?) -> Unit) {
        val d = device ?: return onResult(null, IllegalStateException("device closed"))
        val previewSurface = previewReader!!.surface
        val jpegSurface = jpegReader!!.surface
        val surfaces = listOf(previewSurface, jpegSurface)

        val callback = object : CameraCaptureSession.StateCallback() {
            override fun onConfigured(s: CameraCaptureSession) {
                session = s
                runCalibrationSweep(onResult)
            }
            override fun onConfigureFailed(s: CameraCaptureSession) {
                onResult(null, RuntimeException("session configure failed"))
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
     * Run AE+AF+AWB precapture, then build a "locked" repeating preview
     * request so subsequent captures inherit identical photometry.
     */
    private fun runCalibrationSweep(onResult: (Map<String, Any>?, Throwable?) -> Unit) {
        val s = session!!
        val d = device!!
        val builder = d.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW).apply {
            addTarget(previewReader!!.surface)
            disableComputationalPhotography(this)
            set(CaptureRequest.CONTROL_MODE, CameraMetadata.CONTROL_MODE_AUTO)
            set(CaptureRequest.CONTROL_AE_MODE, CameraMetadata.CONTROL_AE_MODE_ON)
            set(CaptureRequest.CONTROL_AF_MODE, CameraMetadata.CONTROL_AF_MODE_AUTO)
            set(CaptureRequest.CONTROL_AWB_MODE, CameraMetadata.CONTROL_AWB_MODE_AUTO)
            set(CaptureRequest.CONTROL_AF_TRIGGER, CameraMetadata.CONTROL_AF_TRIGGER_START)
            set(CaptureRequest.CONTROL_AE_PRECAPTURE_TRIGGER,
                CameraMetadata.CONTROL_AE_PRECAPTURE_TRIGGER_START)
        }

        // Step 1: kick off AE+AF+AWB sweep.
        s.capture(builder.build(), object : CameraCaptureSession.CaptureCallback() {
            override fun onCaptureCompleted(
                session: CameraCaptureSession,
                request: CaptureRequest,
                tot: TotalCaptureResult,
            ) {
                // Read measured values to publish to Dart.
                lockedExposureNs = tot.get(CaptureResult.SENSOR_EXPOSURE_TIME) ?: 0
                lockedIso = tot.get(CaptureResult.SENSOR_SENSITIVITY) ?: 0
                lockedFocusDistance = tot.get(CaptureResult.LENS_FOCUS_DISTANCE) ?: 0f

                // Step 2: lock everything for the rest of the session.
                val locked = d.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW).apply {
                    addTarget(previewReader!!.surface)
                    disableComputationalPhotography(this)
                    set(CaptureRequest.CONTROL_MODE, CameraMetadata.CONTROL_MODE_AUTO)
                    set(CaptureRequest.CONTROL_AE_LOCK, true)
                    set(CaptureRequest.CONTROL_AWB_LOCK, true)
                    set(CaptureRequest.CONTROL_AF_MODE, CameraMetadata.CONTROL_AF_MODE_OFF)
                    set(CaptureRequest.LENS_FOCUS_DISTANCE, lockedFocusDistance)
                }
                try {
                    s.setRepeatingRequest(locked.build(), null, handler)
                    onResult(buildConfigMap(), null)
                } catch (t: Throwable) {
                    onResult(null, t)
                }
            }

            override fun onCaptureFailed(
                session: CameraCaptureSession,
                request: CaptureRequest,
                failure: CaptureFailure,
            ) {
                onResult(null, RuntimeException("calibration failed: ${failure.reason}"))
            }
        }, handler)
    }

    fun captureJpeg(onResult: (String?, Throwable?) -> Unit) {
        if (isCapturing.getAndSet(true)) {
            onResult(null, IllegalStateException("capture already in flight"))
            return
        }
        val s = session ?: run {
            isCapturing.set(false)
            return onResult(null, IllegalStateException("no session"))
        }
        val d = device ?: run {
            isCapturing.set(false)
            return onResult(null, IllegalStateException("no device"))
        }

        val out = File(captureDir(), "tmp_${System.currentTimeMillis()}.jpg")
        jpegReader!!.setOnImageAvailableListener({ r ->
            val img = r.acquireNextImage() ?: return@setOnImageAvailableListener
            try {
                val buf: ByteBuffer = img.planes[0].buffer
                val bytes = ByteArray(buf.remaining())
                buf.get(bytes)
                FileOutputStream(out).use { it.write(bytes) }
                onResult(out.absolutePath, null)
            } catch (t: Throwable) {
                onResult(null, t)
            } finally {
                img.close()
                isCapturing.set(false)
            }
        }, handler)

        val builder = d.createCaptureRequest(CameraDevice.TEMPLATE_STILL_CAPTURE).apply {
            addTarget(jpegReader!!.surface)
            disableComputationalPhotography(this)
            set(CaptureRequest.CONTROL_AE_LOCK, true)
            set(CaptureRequest.CONTROL_AWB_LOCK, true)
            set(CaptureRequest.CONTROL_AF_MODE, CameraMetadata.CONTROL_AF_MODE_OFF)
            set(CaptureRequest.LENS_FOCUS_DISTANCE, lockedFocusDistance)
            set(CaptureRequest.JPEG_QUALITY, 95.toByte())
            set(CaptureRequest.JPEG_ORIENTATION, sensorOrientation)
        }
        try {
            s.capture(builder.build(), null, handler)
        } catch (t: Throwable) {
            isCapturing.set(false)
            onResult(null, t)
        }
    }

    fun recalibrate(onResult: (Map<String, Any>?, Throwable?) -> Unit) {
        runCalibrationSweep(onResult)
    }

    fun close() {
        try { session?.close() } catch (_: Throwable) {}
        try { device?.close() } catch (_: Throwable) {}
        try { previewReader?.close() } catch (_: Throwable) {}
        try { jpegReader?.close() } catch (_: Throwable) {}
        session = null
        device = null
        previewReader = null
        jpegReader = null
    }

    private fun pickBackCamera(): String {
        for (id in cm.cameraIdList) {
            val chars = cm.getCameraCharacteristics(id)
            if (chars.get(CameraCharacteristics.LENS_FACING) ==
                CameraCharacteristics.LENS_FACING_BACK
            ) return id
        }
        throw RuntimeException("no back camera")
    }

    /**
     * Pushes the camera into "raw-ish" mode — turn off HDR, scene modes,
     * computational stacking, and aggressive noise reduction. These are
     * what cause photometric drift between adjacent frames and break
     * postshot.
     */
    private fun disableComputationalPhotography(b: CaptureRequest.Builder) {
        b.set(CaptureRequest.CONTROL_SCENE_MODE, CameraMetadata.CONTROL_SCENE_MODE_DISABLED)
        b.set(CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE,
            CameraMetadata.CONTROL_VIDEO_STABILIZATION_MODE_OFF)
        b.set(CaptureRequest.CONTROL_EFFECT_MODE,
            CameraMetadata.CONTROL_EFFECT_MODE_OFF)
        b.set(CaptureRequest.NOISE_REDUCTION_MODE,
            CameraMetadata.NOISE_REDUCTION_MODE_FAST)
        b.set(CaptureRequest.EDGE_MODE, CameraMetadata.EDGE_MODE_FAST)
        b.set(CaptureRequest.HOT_PIXEL_MODE, CameraMetadata.HOT_PIXEL_MODE_FAST)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            b.set(CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE,
                CameraMetadata.LENS_OPTICAL_STABILIZATION_MODE_ON)
        }
    }

    private fun captureDir(): File {
        val pics = ctx.getExternalFilesDir(Environment.DIRECTORY_PICTURES)!!
        val dir = File(pics, "tmp")
        if (!dir.exists()) dir.mkdirs()
        return dir
    }

    private fun buildConfigMap(): Map<String, Any> = mapOf(
        "iso" to lockedIso,
        "shutter_speed_ns" to lockedExposureNs,
        "exposure_value" to (lockedIso * (lockedExposureNs / 1e9)),
        "focus_distance" to lockedFocusDistance,
        "preview_width" to previewSize.width,
        "preview_height" to previewSize.height,
        "capture_width" to captureSize.width,
        "capture_height" to captureSize.height,
    )

    companion object {
        private const val TAG = "GsCameraSession"
    }
}
