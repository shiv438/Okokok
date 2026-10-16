package PKG

import android.content.ContentValues
import android.graphics.Matrix
import android.net.Uri
import android.os.Environment
import android.provider.MediaStore
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.MatrixTransformation
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.Transformer
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

private fun Any?.d(): Double = (this as Number).toDouble()

@androidx.annotation.OptIn(UnstableApi::class)
class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "editpro/export")
            .setMethodCallHandler { call, result ->
                if (call.method == "export") export(call.arguments as Map<*, *>, result)
                else result.notImplemented()
            }
    }

    private fun export(args: Map<*, *>, result: MethodChannel.Result) {
        val path = args["path"] as String
        @Suppress("UNCHECKED_CAST")
        val segs = args["segments"] as List<Map<*, *>>
        @Suppress("UNCHECKED_CAST")
        val keys = (args["keys"] as List<Map<*, *>>)
            .map { doubleArrayOf(it["t"].d(), it["x"].d(), it["y"].d(), it["s"].d()) }
            .sortedBy { it[0] }

        // returns [x, y, scale] at timeline time t (ms), linear between keyframes
        fun valueAt(t: Double): DoubleArray {
            if (keys.isEmpty()) return doubleArrayOf(0.0, 0.0, 1.0)
            if (t <= keys.first()[0]) return doubleArrayOf(keys.first()[1], keys.first()[2], keys.first()[3])
            if (t >= keys.last()[0]) return doubleArrayOf(keys.last()[1], keys.last()[2], keys.last()[3])
            for (i in 0 until keys.size - 1) {
                val a = keys[i]
                val b = keys[i + 1]
                if (t >= a[0] && t <= b[0]) {
                    val f = if (b[0] == a[0]) 0.0 else (t - a[0]) / (b[0] - a[0])
                    return doubleArrayOf(
                        a[1] + (b[1] - a[1]) * f,
                        a[2] + (b[2] - a[2]) * f,
                        a[3] + (b[3] - a[3]) * f
                    )
                }
            }
            return doubleArrayOf(0.0, 0.0, 1.0)
        }

        val items = segs.map { s ->
            val start = s["start"].d().toLong()
            val end = s["end"].d().toLong()
            val offset = s["offset"].d()
            val clip = MediaItem.ClippingConfiguration.Builder()
                .setStartPositionMs(start)
                .setEndPositionMs(end)
                .build()
            val mediaItem = MediaItem.Builder()
                .setUri(Uri.fromFile(File(path)))
                .setClippingConfiguration(clip)
                .build()
            val move = MatrixTransformation { presentationTimeUs ->
                val v = valueAt(offset + presentationTimeUs / 1000.0)
                Matrix().apply {
                    postScale(v[2].toFloat(), v[2].toFloat())
                    // NDC spans 2 units across the frame; screen Y points down, NDC Y up
                    postTranslate((2 * v[0]).toFloat(), (-2 * v[1]).toFloat())
                }
            }
            EditedMediaItem.Builder(mediaItem)
                .setEffects(Effects(emptyList(), listOf(move)))
                .build()
        }

        val sequence = EditedMediaItemSequence.Builder(*items.toTypedArray()).build()
        val out = File(cacheDir, "editpro_${System.currentTimeMillis()}.mp4")

        val transformer = Transformer.Builder(this)
            .setVideoMimeType(MimeTypes.VIDEO_H264)
            .setAudioMimeType(MimeTypes.AUDIO_AAC)
            .addListener(object : Transformer.Listener {
                override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                    Thread {
                        try {
                            saveToMovies(out)
                            runOnUiThread { result.success(null) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("SAVE", e.message, null) }
                        }
                    }.start()
                }

                override fun onError(
                    composition: Composition,
                    exportResult: ExportResult,
                    exportException: ExportException
                ) {
                    result.error("EXPORT", exportException.message, null)
                }
            })
            .build()

        transformer.start(Composition.Builder(sequence).build(), out.absolutePath)
    }

    private fun saveToMovies(file: File) {
        val values = ContentValues().apply {
            put(MediaStore.Video.Media.DISPLAY_NAME, file.name)
            put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
            put(MediaStore.Video.Media.RELATIVE_PATH, Environment.DIRECTORY_MOVIES + "/EditPro")
        }
        val uri = contentResolver.insert(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, values)
            ?: throw Exception("Could not create file in Movies")
        contentResolver.openOutputStream(uri)!!.use { o ->
            file.inputStream().use { it.copyTo(o) }
        }
        file.delete()
    }
}
