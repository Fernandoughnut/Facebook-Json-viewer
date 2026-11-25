package dev.local.indexed

import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.documentfile.provider.DocumentFile
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "dev.local.indexed/folder"
        private const val REQUEST_PICK_FOLDER = 4242
        private val MEDIA_EXTENSIONS = setOf(
            "jpg", "jpeg", "png", "gif", "webp", "bmp",
            "mp4", "m4v", "mov", "avi", "mkv", "webm", "3gp",
            "heic", "heif",
        )
    }

    private var pendingFolderResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickFolder" -> pickFolder(result)
                    "importFolder" -> importFolder(call, result)
                    else -> result.notImplemented()
                }
            }
    }

    private fun pickFolder(result: MethodChannel.Result) {
        pendingFolderResult?.error("in_progress", "A folder pick is already open", null)
        pendingFolderResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            flags = flags or
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                Intent.FLAG_GRANT_PREFIX_URI_PERMISSION
        }
        try {
            startActivityForResult(intent, REQUEST_PICK_FOLDER)
        } catch (e: Exception) {
            pendingFolderResult = null
            result.error("no_file_manager", e.toString(), null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == REQUEST_PICK_FOLDER) {
            val result = pendingFolderResult
            pendingFolderResult = null
            if (resultCode != RESULT_OK || data?.data == null) {
                result?.success(null)
            } else {
                val uri = data.data!!
                try {
                    contentResolver.takePersistableUriPermission(
                        uri,
                        Intent.FLAG_GRANT_READ_URI_PERMISSION,
                    )
                } catch (_: SecurityException) {
                    // Some providers do not allow persisting; the import below
                    // still works for as long as this process is alive.
                }
                result?.success(uri.toString())
            }
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    private fun importFolder(call: MethodCall, result: MethodChannel.Result) {
        val uriString = call.argument<String>("uri")
        val destPath = call.argument<String>("destDir")
        if (uriString == null || destPath == null) {
            result.error("invalid_args", "uri and destDir are required", null)
            return
        }
        val tree = DocumentFile.fromTreeUri(this, Uri.parse(uriString))
        if (tree == null) {
            result.error("bad_uri", "Could not open that folder", null)
            return
        }
        val dest = File(destPath)
        if (!dest.exists() && !dest.mkdirs()) {
            result.error("mkdir_failed", "Could not create ${dest.absolutePath}", null)
            return
        }

        // Streaming thousands of large videos can take a while. Keep it off
        // the main thread, then deliver the result on the main looper.
        Thread {
            val stats = intArrayOf(0, 0)
            try {
                copyTree(tree, dest, "", stats)
                Handler(Looper.getMainLooper()).post {
                    result.success(
                        mapOf(
                            "path" to dest.absolutePath,
                            "copied" to stats[0],
                            "skipped" to stats[1],
                        ),
                    )
                }
            } catch (e: Exception) {
                Handler(Looper.getMainLooper()).post {
                    result.error("import_failed", e.toString(), null)
                }
            }
        }.start()
    }

    private fun copyTree(doc: DocumentFile, dest: File, rel: String, stats: IntArray) {
        if (doc.isDirectory) {
            val childRel =
                if (rel.isEmpty()) safeName(doc.name) else "$rel/${safeName(doc.name)}"
            File(dest, childRel).mkdirs()
            for (child in doc.listFiles()) copyTree(child, dest, childRel, stats)
            return
        }

        val name = safeName(doc.name)
        val ext = name.substringAfterLast('.', "").lowercase()
        if (ext !in MEDIA_EXTENSIONS) return

        val parent = if (rel.isEmpty()) dest else File(dest, rel)
        if (!parent.exists()) parent.mkdirs()
        val target = File(parent, name)
        if (target.exists() && target.length() == doc.length()) {
            stats[1]++
            return
        }

        val input = contentResolver.openInputStream(doc.uri)
        if (input == null) {
            stats[1]++
            return
        }
        input.use { source ->
            FileOutputStream(target).use { out ->
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    val read = source.read(buffer)
                    if (read <= 0) break
                    out.write(buffer, 0, read)
                }
            }
        }
        stats[0]++
    }

    private fun safeName(name: String?): String {
        val cleaned = name?.trim()?.replace(Regex("[\\\\/:*?\"<>|\\r\\n]"), "_")
        return if (cleaned.isNullOrEmpty()) "media" else cleaned
    }
}
