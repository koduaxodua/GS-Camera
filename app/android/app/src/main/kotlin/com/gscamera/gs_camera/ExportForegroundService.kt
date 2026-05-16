package com.gscamera.gs_camera

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Environment
import android.os.IBinder
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

class ExportForegroundService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val shotsJson = intent?.getStringExtra(EXTRA_SHOTS) ?: "[]"
        val infoJson = intent?.getStringExtra(EXTRA_SESSION_INFO) ?: "{}"
        val asZip = intent?.getBooleanExtra(EXTRA_AS_ZIP, false) ?: false
        val outputPath = intent?.getStringExtra(EXTRA_OUTPUT_PATH)
            ?: buildOutputPath(this, asZip)

        createChannel()
        startForeground(
            NOTIFICATION_ID,
            notification("Preparing export", 0, 1, false),
        )

        Thread {
            runCatching {
                export(
                    shots = JSONArray(shotsJson),
                    sessionInfo = JSONObject(infoJson),
                    outputPath = outputPath,
                    asZip = asZip,
                )
            }.onFailure {
                notifyFinal("Export failed", it.message ?: "Unknown error")
            }
            stopForeground(false)
            stopSelf(startId)
        }.start()

        return START_REDELIVER_INTENT
    }

    private fun export(
        shots: JSONArray,
        sessionInfo: JSONObject,
        outputPath: String,
        asZip: Boolean,
    ) {
        val total = shots.length() + 2
        var done = 0
        if (asZip) {
            ZipOutputStream(FileOutputStream(outputPath)).use { zip ->
                val exportedShots = JSONArray()
                for (i in 0 until shots.length()) {
                    val shot = shots.getJSONObject(i)
                    val src = File(shot.getString("path"))
                    val meta = shot.getJSONObject("meta")
                    val camera = meta.optString("camera", "main")
                    val name = "${(i + 1).toString().padStart(4, '0')}.jpg"
                    if (src.exists()) {
                        zip.putNextEntry(ZipEntry("images/$camera/$name"))
                        FileInputStream(src).use { it.copyTo(zip) }
                        zip.closeEntry()
                    }
                    meta.put("filename", name)
                    exportedShots.put(meta)
                    done++
                    updateProgress(done, total, name)
                }
                zipString(zip, "session.json", sessionJson(sessionInfo, exportedShots))
                done++
                updateProgress(done, total, "session.json")
                zipString(zip, "README.txt", README_BODY)
                done++
                updateProgress(done, total, "README.txt")
            }
        } else {
            val outDir = File(outputPath)
            outDir.mkdirs()
            val exportedShots = JSONArray()
            for (i in 0 until shots.length()) {
                val shot = shots.getJSONObject(i)
                val src = File(shot.getString("path"))
                val meta = shot.getJSONObject("meta")
                val camera = meta.optString("camera", "main")
                val name = "${(i + 1).toString().padStart(4, '0')}.jpg"
                val cameraDir = File(outDir, "images/$camera").apply { mkdirs() }
                val dest = File(cameraDir, name)
                if (src.exists()) {
                    if (!src.renameTo(dest)) {
                        src.copyTo(dest, overwrite = true)
                        src.delete()
                    }
                }
                meta.put("filename", name)
                exportedShots.put(meta)
                done++
                updateProgress(done, total, name)
            }
            File(outDir, "session.json").writeText(
                sessionJson(sessionInfo, exportedShots),
            )
            done++
            updateProgress(done, total, "session.json")
            File(outDir, "README.txt").writeText(README_BODY)
            done++
            updateProgress(done, total, "README.txt")
        }
        notifyFinal("Export complete", outputPath)
    }

    private fun sessionJson(sessionInfo: JSONObject, shots: JSONArray): String {
        val out = JSONObject(sessionInfo.toString())
        out.put("shot_count", shots.length())
        out.put("shots", shots)
        return out.toString(2)
    }

    private fun zipString(zip: ZipOutputStream, name: String, body: String) {
        zip.putNextEntry(ZipEntry(name))
        zip.write(body.toByteArray(Charsets.UTF_8))
        zip.closeEntry()
    }

    private fun updateProgress(done: Int, total: Int, current: String) {
        val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        mgr.notify(
            NOTIFICATION_ID,
            notification("Exporting $done / $total", done, total, false, current),
        )
    }

    private fun notifyFinal(title: String, text: String) {
        val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        mgr.notify(NOTIFICATION_ID, notification(title, 1, 1, true, text))
    }

    private fun notification(
        title: String,
        done: Int,
        total: Int,
        finished: Boolean,
        text: String = "",
    ): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        builder
            .setSmallIcon(android.R.drawable.stat_sys_upload_done)
            .setContentTitle(title)
            .setContentText(text)
            .setOngoing(!finished)
            .setOnlyAlertOnce(true)
        if (!finished) builder.setProgress(total, done, false)
        return builder.build()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channel = NotificationChannel(
            CHANNEL_ID,
            "GS Camera exports",
            NotificationManager.IMPORTANCE_LOW,
        )
        mgr.createNotificationChannel(channel)
    }

    companion object {
        private const val CHANNEL_ID = "gs_camera_exports"
        private const val NOTIFICATION_ID = 4107
        private const val EXTRA_SHOTS = "shots_json"
        private const val EXTRA_SESSION_INFO = "session_info_json"
        private const val EXTRA_AS_ZIP = "as_zip"
        private const val EXTRA_OUTPUT_PATH = "output_path"

        fun buildOutputPath(ctx: Context, asZip: Boolean): String {
            val root = File(
                ctx.getExternalFilesDir(Environment.DIRECTORY_PICTURES) ?: ctx.filesDir,
                "GSCamera",
            ).apply { mkdirs() }
            val stamp = SimpleDateFormat("yyyy-MM-dd_HHmm", Locale.US).format(Date())
            val base = File(root, "Session_$stamp").absolutePath
            return if (asZip) "$base.zip" else base
        }

        fun start(
            ctx: Context,
            shotsJson: String,
            sessionInfoJson: String,
            asZip: Boolean,
            outputPath: String,
        ) {
            val intent = Intent(ctx, ExportForegroundService::class.java)
                .putExtra(EXTRA_SHOTS, shotsJson)
                .putExtra(EXTRA_SESSION_INFO, sessionInfoJson)
                .putExtra(EXTRA_AS_ZIP, asZip)
                .putExtra(EXTRA_OUTPUT_PATH, outputPath)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                ctx.startForegroundService(intent)
            } else {
                ctx.startService(intent)
            }
        }

        private const val README_BODY = """
GS Camera session - for postshot

Drop this entire folder into postshot as an image sequence project.
- Frames are JPEG, sequential, EXIF preserved.
- Camera exposure/focus/white balance were locked across all frames.
- session.json contains sensor metadata.
"""
    }
}
