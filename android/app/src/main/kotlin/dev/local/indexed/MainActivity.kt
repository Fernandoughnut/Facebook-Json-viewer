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
import java.io.InputStream

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "dev.local.indexed/folder"
        private const val REQUEST_PICK_FOLDER = 4242
        private const val BUFFER_SIZE = 256 * 1024
        private val MEDIA_EXTENSIONS = setOf(
            "jpg", "jpeg", "png", "gif", "webp", "bmp",
            "mp4", "m4v", "mov", "avi", "mkv", "webm", "3gp",
            "heic", "heif",
        )
        private val INVALID_NAME = Regex("[\\\\/:*?\"<>|\\r\\n]")
    }

    private data class Source(
        val doc: DocumentFile,
        val relDir: String,
        val name: String,
        val size: Long,
    )

    private var folderChannel: MethodChannel? = null
    private var pendingFolderResult: MethodChannel.Result? = null
    private var activeImportId: String? = null

    private fun isActive(id: String) = synchronized(this) { activeImportId == id }

    private fun clearImport(id: String) = synchronized(this) {
        if (activeImportId == id) activeImportId = null
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        folderChannel = channel
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "pickFolder" -> pickFolder(result)
                "importFolder" -> importFolder(call, result)
                "cancelImport" -> {
                    activeImportId = null
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun pickFolder(result: MethodChannel.Result) {
        val previous = pendingFolderResult
        pendingFolderResult = result
        if (previous != null) {
            previous.error("in_progress", "A folder pick is already open", null)
        }
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
        if (activeImportId != null) {
            result.error("already_importing", "Another folder is still importing", null)
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

        val importId = call.argument<String>("importId")
            ?: System.currentTimeMillis().toString()
        synchronized(this) { activeImportId = importId }

        // Listing and copying a few thousand SAF documents is far too slow for
        // the main thread. One thread owns the whole import; progress is sent
        // back over the same method channel.
        Thread {
            val copied = intArrayOf(0)
            val skipped = intArrayOf(0)
            val buffer = ByteArray(BUFFER_SIZE)
            var lastEmit = 0L

            fun emit(phase: String, current: Int, total: Int, name: String?) {
                val now = System.currentTimeMillis()
                if (phase != "done" && now - lastEmit < 100 && current % 25 != 0) return
                lastEmit = now
                try {
                    folderChannel?.invokeMethod(
                        "importProgress",
                        mapOf(
                            "importId" to importId,
                            "phase" to phase,
                            "current" to current,
                            "total" to total,
                            "copied" to copied[0],
                            "skipped" to skipped[0],
                            "name" to name,
                        ),
                    )
                } catch (_: Exception) {
                    // A progress frame is never worth failing the import.
                }
            }

            try {
                val sources = mutableListOf<Source>()
                collect(tree, "", sources, importId)
                val total = sources.size
                emit("listing", 0, total, null)
                val used = HashMap<String, MutableSet<String>>()
                for ((index, source) in sources.withIndex()) {
                    if (!isActive(importId)) break
                    try {
                        copyOne(source, dest, used, buffer, skipped, copied)
                    } catch (_: Exception) {
                        skipped[0]++
                    }
                    emit("copying", index + 1, total, source.name)
                }
                val cancelled = !isActive(importId)
                clearImport(importId)
                emit("done", total, total, null)
                val payload = mapOf(
                    "path" to dest.absolutePath,
                    "copied" to copied[0],
                    "skipped" to skipped[0],
                    "cancelled" to cancelled,
                )
                Handler(Looper.getMainLooper()).post { result.success(payload) }
            } catch (e: Exception) {
                clearImport(importId)
                Handler(Looper.getMainLooper()).post {
                    result.error("import_failed", e.toString(), null)
                }
            }
        }.start()
    }

    private fun collect(
        doc: DocumentFile,
        rel: String,
        out: MutableList<Source>,
        importId: String,
    ) {
        if (!isActive(importId)) return
        val children = doc.listFiles() ?: return
        for (child in children) {
            if (!isActive(importId)) return
            if (child.isDirectory) {
                val name = safeName(child.name)
                val childRel = if (rel.isEmpty()) name else "$rel/$name"
                collect(child, childRel, out, importId)
                continue
            }
            val raw = child.name ?: continue
            val dot = raw.lastIndexOf('.')
            if (dot <= 0) continue
            if (raw.substring(dot + 1).lowercase() !in MEDIA_EXTENSIONS) continue
            val size = try {
                child.length()
            } catch (_: Exception) {
                -1L
            }
            out.add(Source(child, rel, safeName(raw), size))
        }
    }

    private fun copyOne(
        source: Source,
        dest: File,
        used: HashMap<String, MutableSet<String>>,
        buffer: ByteArray,
        skipped: IntArray,
        copied: IntArray,
    ) {
        val parent = if (source.relDir.isEmpty()) dest else File(dest, source.relDir)
        if (!parent.exists() && !parent.mkdirs()) {
            skipped[0]++
            return
        }

        // Sanitizing can make two different names identical. Give each source
        // a unique lowercased name in its destination folder.
        val names = used.getOrPut(parent.path) { HashSet() }
        var name = source.name
        var suffix = 1
        while (!names.add(name.lowercase())) {
            val dot = source.name.lastIndexOf('.')
            val base = if (dot > 0) source.name.substring(0, dot) else source.name
            val ext = if (dot > 0) source.name.substring(dot) else ""
            name = "$base-$suffix$ext"
            suffix++
        }

        val target = File(parent, name)
        // Length is only a cheap hint: equal size with unknown source size is
        // never treated as "already there".
        if (source.size > 0 && target.exists() && target.length() == source.size) {
            skipped[0]++
            return
        }

        val input = contentResolver.openInputStream(source.doc.uri)
        if (input == null) {
            skipped[0]++
            return
        }
        // Write to a temporary file so a killed/ interrupted import can never
        // leave a truncated file that looks complete on the next run.
        val part = File(parent, "$name.part")
        try {
            input.use { sourceStream -> copyStream(sourceStream, part, buffer) }
        } catch (e: Exception) {
            part.delete()
            throw e
        }
        if (!part.renameTo(target)) {
            part.delete()
            skipped[0]++
            return
        }
        copied[0]++
    }

    private fun copyStream(input: InputStream, target: File, buffer: ByteArray) {
        FileOutputStream(target).use { out ->
            while (true) {
                val read = input.read(buffer)
                if (read <= 0) break
                out.write(buffer, 0, read)
            }
        }
    }

    private fun safeName(name: String?): String {
        val cleaned = name?.trim()?.replace(INVALID_NAME, "_")
        return if (cleaned.isNullOrEmpty()) "media" else cleaned
    }
}
