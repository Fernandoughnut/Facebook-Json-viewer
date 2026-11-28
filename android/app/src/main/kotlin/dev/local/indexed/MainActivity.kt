package dev.local.indexed

import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import androidx.documentfile.provider.DocumentFile
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.InputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "dev.local.indexed/folder"
        private const val EXPORT_CHANNEL = "dev.local.indexed/export"
        private const val REQUEST_PICK_FOLDER = 4242
        private const val REQUEST_PICK_EXPORT_FOLDER = 4243
        private const val BUFFER_SIZE = 256 * 1024
        private val MEDIA_EXTENSIONS = setOf(
            "jpg", "jpeg", "png", "gif", "webp", "bmp",
            "mp4", "m4v", "mov", "avi", "mkv", "webm", "3gp",
            "heic", "heif",
        )
        private val MEDIA_MIMES = listOf("image/", "video/", "audio/")
        private val INVALID_NAME = Regex("[\\\\/:*?\"<>|\\r\\n]")
        private val DOCUMENT_COLUMNS = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
        )
    }

    private data class Source(
        val uri: Uri,
        val relDir: String,
        val name: String,
        val size: Long,
        val modified: Long,
    )

    private var folderChannel: MethodChannel? = null
    private var exportChannel: MethodChannel? = null
    private var pendingFolderResult: MethodChannel.Result? = null
    private var pendingExportFolderResult: MethodChannel.Result? = null
    private val activeImports = HashSet<String>()

    private fun isActive(id: String) = synchronized(this) { activeImports.contains(id) }

    private fun clearImport(id: String) = synchronized(this) { activeImports.remove(id) }

    private fun cancelImport(id: String?) = synchronized(this) {
        if (id == null) activeImports.clear() else activeImports.remove(id)
    }

    private fun beginImport(id: String): Boolean = synchronized(this) {
        activeImports.add(id)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        folderChannel = channel
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "pickFolder" -> pickFolder(result)
                "importFolder" -> importFolder(call, result)
                "importJsonFolder" -> importJsonFolder(call, result)
                "cancelImport" -> {
                    cancelImport(call.argument<String>("importId"))
                    result.success(null)
                }
                "openLink" -> openLink(call, result)
                else -> result.notImplemented()
            }
        }

        val export = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, EXPORT_CHANNEL)
        exportChannel = export
        export.setMethodCallHandler { call, result ->
            when (call.method) {
                "pickExportFolder" -> pickExportFolder(result)
                "writeFileToFolder" -> writeFileToFolder(call, result)
                "copyFilesToFolder" -> copyFilesToFolder(call, result)
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        pendingFolderResult?.error(
            "engine_stopped",
            "The folder picker was closed by app shutdown",
            null,
        )
        pendingExportFolderResult?.error(
            "engine_stopped",
            "The folder picker was closed by app shutdown",
            null,
        )
        pendingFolderResult = null
        pendingExportFolderResult = null
        cancelImport(null)
        super.onDestroy()
    }

    private fun openLink(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url")
        if (url == null) {
            result.success(false)
            return
        }
        try {
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url)).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            result.success(true)
        } catch (e: Exception) {
            result.success(false)
        }
    }

    private fun pickFolder(result: MethodChannel.Result) {
        val previous = pendingFolderResult
        if (previous != null) {
            pendingFolderResult = null
            previous.error("in_progress", "A folder pick is already open", null)
            result.error("in_progress", "A folder pick is already open", null)
            return
        }
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

    private fun pickExportFolder(result: MethodChannel.Result) {
        val previous = pendingExportFolderResult
        if (previous != null) {
            pendingExportFolderResult = null
            previous.error("in_progress", "A folder pick is already open", null)
            result.error("in_progress", "A folder pick is already open", null)
            return
        }
        pendingExportFolderResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            flags = flags or
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                Intent.FLAG_GRANT_PREFIX_URI_PERMISSION
        }
        try {
            startActivityForResult(intent, REQUEST_PICK_EXPORT_FOLDER)
        } catch (e: Exception) {
            pendingExportFolderResult = null
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
                    // Some providers cannot persist; imports still work while the process lives.
                }
                result?.success(uri.toString())
            }
            return
        }
        if (requestCode == REQUEST_PICK_EXPORT_FOLDER) {
            val result = pendingExportFolderResult
            pendingExportFolderResult = null
            if (resultCode != RESULT_OK || data?.data == null) {
                result?.success(null)
            } else {
                val uri = data.data!!
                try {
                    contentResolver.takePersistableUriPermission(
                        uri,
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or
                            Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
                    )
                } catch (_: SecurityException) {
                    // Some providers refuse persistence; writes still work while the process lives.
                }
                result?.success(uri.toString())
            }
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    private fun writeFileToFolder(call: MethodCall, result: MethodChannel.Result) {
        val uriString = call.argument<String>("uri")
        val sourcePath = call.argument<String>("sourcePath")
        val fileName = call.argument<String>("fileName")
        val exportId = call.argument<String>("exportId")
        if (uriString == null || sourcePath == null || fileName == null || exportId == null) {
            result.error("invalid_args", "uri, sourcePath and fileName are required", null)
            return
        }
        val tree = DocumentFile.fromTreeUri(this, Uri.parse(uriString))
        if (tree == null || !tree.canWrite()) {
            result.error("bad_folder", "That folder is not writable", null)
            return
        }
        val source = File(sourcePath)
        if (!source.exists()) {
            result.error("missing_source", "The archive could not be read", null)
            return
        }

        Thread {
            var staged: DocumentFile? = null
            try {
                val name = safeName(fileName)
                // Stage the replacement first: the previous archive stays intact
                // until the new one has been written and verified.
                val tempName = "$name.part-$exportId"
                tree.findFile(tempName)?.delete()
                staged = tree.createFile("application/octet-stream", tempName)
                    ?: throw IllegalStateException("Could not create $tempName")
                val target = staged!!
                val total = source.length()
                val out = contentResolver.openOutputStream(target.uri, "rwt")
                    ?: throw IllegalStateException("Could not open $name for writing")

                val buffer = ByteArray(BUFFER_SIZE)
                var done = 0L
                var lastEmit = 0L
                fun emit(final: Boolean = false) {
                    val now = System.currentTimeMillis()
                    if (!final && now - lastEmit < 150) return
                    lastEmit = now
                    try {
                        exportChannel?.invokeMethod(
                            "exportProgress",
                            mapOf(
                                "exportId" to exportId,
                                "current" to done,
                                "total" to total,
                            ),
                        )
                    } catch (_: Exception) {
                        // Progress frames must never fail an export.
                    }
                }

                FileInputStream(source).use { input ->
                    out.use { output ->
                        while (true) {
                            val read = input.read(buffer)
                            if (read <= 0) break
                            output.write(buffer, 0, read)
                            done += read.toLong()
                            emit()
                        }
                        output.flush()
                    }
                }
                if (target.length() != total) {
                    throw IllegalStateException("The staged archive is incomplete")
                }
                val existing = tree.findFile(name)
                if (existing != null && !existing.delete()) {
                    throw IllegalStateException("Could not replace $name")
                }
                if (!target.renameTo(name)) {
                    throw IllegalStateException("Could not name the new archive $name")
                }
                emit(final = true)
                val finalDoc = tree.findFile(name) ?: target
                Handler(Looper.getMainLooper()).post {
                    result.success(
                        mapOf(
                            "uri" to finalDoc.uri.toString(),
                            "name" to (finalDoc.name ?: name),
                        ),
                    )
                }
            } catch (e: Exception) {
                staged?.delete()
                Handler(Looper.getMainLooper()).post {
                    result.error("export_failed", e.toString(), null)
                }
            }
        }.start()
    }

    /// Copy already-chosen files into a writable SAF tree under new names.
    /// Used by "Copy media with readable names", where dart:io cannot see the
    /// destination chosen through the system folder picker.
    private fun copyFilesToFolder(call: MethodCall, result: MethodChannel.Result) {
        val uriString = call.argument<String>("uri")
        val rawJobs = call.argument<List<*>>("jobs")
        if (uriString == null || rawJobs == null) {
            result.error("invalid_args", "uri and jobs are required", null)
            return
        }
        val tree = DocumentFile.fromTreeUri(this, Uri.parse(uriString))
        if (tree == null || !tree.canWrite()) {
            result.error("bad_folder", "That folder is not writable", null)
            return
        }
        val jobs = rawJobs.mapNotNull { raw ->
            val job = raw as? List<*> ?: return@mapNotNull null
            val source = job.getOrNull(0) as? String ?: return@mapNotNull null
            val name = job.getOrNull(1) as? String ?: return@mapNotNull null
            Pair(source, name)
        }
        Thread {
            var copied = 0
            for ((sourcePath, name) in jobs) {
                try {
                    val source = File(sourcePath)
                    if (!source.exists()) continue
                    val target = tree.createFile(mimeForName(name), safeName(name))
                        ?: continue
                    contentResolver.openOutputStream(target.uri, "rwt")?.use { out ->
                        FileInputStream(source).use { input ->
                            input.copyTo(out, BUFFER_SIZE)
                        }
                    } ?: continue
                    copied++
                } catch (_: Exception) {
                    // One unreadable source must not abort the whole copy.
                }
            }
            Handler(Looper.getMainLooper()).post {
                result.success(mapOf("copied" to copied))
            }
        }.start()
    }

    private fun mimeForName(name: String): String = when (
        name.substringAfterLast('.', "").lowercase()
    ) {
        "jpg", "jpeg" -> "image/jpeg"
        "png" -> "image/png"
        "gif" -> "image/gif"
        "webp" -> "image/webp"
        "heic", "heif" -> "image/heic"
        "mp4", "m4v" -> "video/mp4"
        "mov" -> "video/quicktime"
        "webm" -> "video/webm"
        else -> "application/octet-stream"
    }

    private fun importFolder(call: MethodCall, result: MethodChannel.Result) {
        val uriString = call.argument<String>("uri")
        val destPath = call.argument<String>("destDir")
        if (uriString == null || destPath == null) {
            result.error("invalid_args", "uri and destDir are required", null)
            return
        }
        val importId = call.argument<String>("importId")
            ?: System.currentTimeMillis().toString()
        if (!beginImport(importId)) {
            result.error("already_importing", "Another folder is still importing", null)
            return
        }
        val treeUri = Uri.parse(uriString)
        val rootId = try {
            DocumentsContract.getTreeDocumentId(treeUri)
        } catch (_: Exception) {
            null
        }
        if (rootId == null) {
            clearImport(importId)
            result.error("bad_uri", "Could not open that folder", null)
            return
        }
        val dest = File(destPath)
        if (!dest.exists() && !dest.mkdirs()) {
            clearImport(importId)
            result.error("mkdir_failed", "Could not create ${dest.absolutePath}", null)
            return
        }

        // Listing/copying thousands of SAF documents is too slow for the main thread.
        // One thread lists; a small pool hides per-file provider latency.
        Thread {
            val copied = AtomicInteger(0)
            val skipped = AtomicInteger(0)
            val used = HashMap<String, MutableSet<String>>()
            val nameLock = Any()
            val emitLock = Any()
            var lastEmit = 0L

            fun emit(phase: String, current: Int, total: Int, name: String?) {
                synchronized(emitLock) {
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
                                "copied" to copied.get(),
                                "skipped" to skipped.get(),
                                "name" to name,
                            ),
                        )
                    } catch (_: Exception) {
                        // A progress frame is never worth failing the import.
                    }
                }
            }

            try {
                val sources = mutableListOf<Source>()
                queryChildren(treeUri, rootId, "", sources, importId, jsonOnly = false)
                val total = sources.size
                emit("listing", 0, total, null)

                val done = AtomicInteger(0)
                val pool = Executors.newFixedThreadPool(4)
                for (source in sources) {
                    if (!isActive(importId)) break
                    pool.execute {
                        if (!isActive(importId)) return@execute
                        try {
                            copyOne(source, dest, used, nameLock, skipped, copied)
                        } catch (_: Exception) {
                            skipped.incrementAndGet()
                        } finally {
                            emit("copying", done.incrementAndGet(), total, source.name)
                        }
                    }
                }
                if (!isActive(importId)) {
                    pool.shutdownNow()
                    pool.awaitTermination(10, TimeUnit.SECONDS)
                } else {
                    pool.shutdown()
                    pool.awaitTermination(10, TimeUnit.MINUTES)
                }
                val cancelled = !isActive(importId)
                clearImport(importId)
                emit("done", total, total, null)
                val payload = mapOf(
                    "path" to dest.absolutePath,
                    "copied" to copied.get(),
                    "skipped" to skipped.get(),
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

    /// Read a SAF tree with one query per folder.
    /// DocumentFile metadata accessors were orders of magnitude slower.
    private fun queryChildren(
        treeUri: Uri,
        parentId: String,
        rel: String,
        out: MutableList<Source>,
        importId: String,
        jsonOnly: Boolean,
    ) {
        if (!isActive(importId)) return
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentId)
        val cursor = try {
            contentResolver.query(childrenUri, DOCUMENT_COLUMNS, null, null, null)
        } catch (_: Exception) {
            null
        } ?: return
        val idCol = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
        if (idCol < 0) {
            cursor.close()
            return
        }
        val nameCol = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
        val mimeCol = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_MIME_TYPE)
        val sizeCol = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_SIZE)
        val modifiedCol = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_LAST_MODIFIED)
        cursor.use { c ->
            while (c.moveToNext()) {
                if (!isActive(importId)) return
                if (c.isNull(idCol)) continue
                val docId = c.getString(idCol) ?: continue
                val raw = if (nameCol >= 0 && !c.isNull(nameCol)) c.getString(nameCol) else null
                val mime = if (mimeCol >= 0 && !c.isNull(mimeCol)) {
                    c.getString(mimeCol) ?: ""
                } else {
                    ""
                }
                if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                    val name = safeDirName(raw)
                    val childRel = if (rel.isEmpty()) name else "$rel/$name"
                    queryChildren(treeUri, docId, childRel, out, importId, jsonOnly)
                    continue
                }
                if (raw.isNullOrEmpty()) continue
                val lower = raw.lowercase()
                val dot = raw.lastIndexOf('.')
                val matches = if (jsonOnly) {
                    lower.endsWith(".json") ||
                        mime == "application/json" ||
                        mime.endsWith("+json")
                } else {
                    val hasMime = MEDIA_MIMES.any { mime.startsWith(it) }
                    (dot <= 0 && hasMime) ||
                        (dot > 0 &&
                            (lower.substring(dot + 1) in MEDIA_EXTENSIONS || hasMime))
                }
                if (!matches) continue
                val size = if (sizeCol >= 0 && !c.isNull(sizeCol)) c.getLong(sizeCol) else -1L
                val modified = if (modifiedCol >= 0 && !c.isNull(modifiedCol)) {
                    c.getLong(modifiedCol)
                } else {
                    -1L
                }
                out.add(
                    Source(
                        uri = DocumentsContract.buildDocumentUriUsingTree(treeUri, docId),
                        relDir = rel,
                        name = safeName(raw),
                        size = size,
                        modified = modified,
                    ),
                )
            }
        }
    }

    /// Refresh the app-private JSON copy; the user's originals are untouched.
    private fun importJsonFolder(call: MethodCall, result: MethodChannel.Result) {
        val uriString = call.argument<String>("uri")
        val destPath = call.argument<String>("destDir")
        if (uriString == null || destPath == null) {
            result.error("invalid_args", "uri and destDir are required", null)
            return
        }
        val importId = call.argument<String>("importId")
            ?: System.currentTimeMillis().toString()
        if (!beginImport(importId)) {
            result.error("already_importing", "Another folder is still importing", null)
            return
        }
        val treeUri = Uri.parse(uriString)
        val rootId = try {
            DocumentsContract.getTreeDocumentId(treeUri)
        } catch (_: Exception) {
            null
        }
        if (rootId == null) {
            clearImport(importId)
            result.error("bad_uri", "Could not open that folder", null)
            return
        }
        val dest = File(destPath)
        if (!dest.exists() && !dest.mkdirs()) {
            clearImport(importId)
            result.error("mkdir_failed", "Could not create ${dest.absolutePath}", null)
            return
        }

        Thread {
            val copied = AtomicInteger(0)
            val skipped = AtomicInteger(0)
            val used = HashMap<String, MutableSet<String>>()
            val nameLock = Any()
            try {
                val sources = mutableListOf<Source>()
                queryChildren(treeUri, rootId, "", sources, importId, jsonOnly = true)
                val paths = mutableListOf<String>()
                for (source in sources) {
                    if (!isActive(importId)) break
                    try {
                        val path = copyOne(
                            source,
                            dest,
                            used,
                            nameLock,
                            skipped,
                            copied,
                            overwrite = true,
                        )
                        if (path != null) paths.add(path)
                    } catch (_: Exception) {
                        skipped.incrementAndGet()
                    }
                }
                if (isActive(importId)) {
                    // A re-picked tree replaces the imported snapshot. Stale JSON
                    // copies would otherwise resurrect chats the user removed.
                    val keep = paths.map { File(it).absolutePath }.toSet()
                    dest.walkTopDown()
                        .filter {
                            it.isFile &&
                                it.extension.equals("json", ignoreCase = true) &&
                                it.absolutePath !in keep
                        }
                        .forEach { it.delete() }
                }
                val cancelled = !isActive(importId)
                clearImport(importId)
                Handler(Looper.getMainLooper()).post {
                    result.success(
                        mapOf(
                            "path" to dest.absolutePath,
                            "paths" to paths,
                            "copied" to copied.get(),
                            "skipped" to skipped.get(),
                            "cancelled" to cancelled,
                        ),
                    )
                }
            } catch (e: Exception) {
                clearImport(importId)
                Handler(Looper.getMainLooper()).post {
                    result.error("import_failed", e.toString(), null)
                }
            }
        }.start()
    }

    private fun copyOne(
        source: Source,
        dest: File,
        used: HashMap<String, MutableSet<String>>,
        nameLock: Any,
        skipped: AtomicInteger,
        copied: AtomicInteger,
        overwrite: Boolean = false,
    ): String? {
        // Name allocation is atomic across workers; stream copies run outside the lock.
        val allocated = synchronized(nameLock) {
            val parent = if (source.relDir.isEmpty()) dest else File(dest, source.relDir)
            if (!parent.exists() && !parent.mkdirs()) {
                null
            } else {
                val names = used.getOrPut(parent.path) { HashSet() }
                var name = source.name
                var suffix = 1
                while (!names.add(name)) {
                    val dot = source.name.lastIndexOf('.')
                    val base = if (dot > 0) source.name.substring(0, dot) else source.name
                    val ext = if (dot > 0) source.name.substring(dot) else ""
                    name = "$base-$suffix$ext"
                    suffix++
                }
                Pair(parent, File(parent, name))
            }
        }
        if (allocated == null) {
            skipped.incrementAndGet()
            return null
        }
        val (parent, target) = allocated
        val name = target.name

        // Size alone is not identity; unknown modified times force a copy.
        if (!overwrite &&
            source.size > 0 &&
            source.modified > 0 &&
            target.exists() &&
            target.length() == source.size &&
            target.lastModified() == source.modified
        ) {
            skipped.incrementAndGet()
            return target.absolutePath
        }

        val input = contentResolver.openInputStream(source.uri)
        if (input == null) {
            skipped.incrementAndGet()
            return null
        }
        // Copy via a temp file so interrupted imports never leave truncated files.
        val part = File(parent, "$name.part")
        try {
            input.use { sourceStream -> copyStream(sourceStream, part) }
        } catch (e: Exception) {
            part.delete()
            throw e
        }
        try {
            // Replace in one filesystem operation: a failed rename leaves the
            // previous good file untouched instead of only a .part file.
            Files.move(
                part.toPath(),
                target.toPath(),
                StandardCopyOption.REPLACE_EXISTING,
                StandardCopyOption.ATOMIC_MOVE,
            )
        } catch (_: Exception) {
            try {
                Files.move(
                    part.toPath(),
                    target.toPath(),
                    StandardCopyOption.REPLACE_EXISTING,
                )
            } catch (e: Exception) {
                part.delete()
                skipped.incrementAndGet()
                return null
            }
        }
        copied.incrementAndGet()
        return target.absolutePath
    }

    private fun copyStream(input: InputStream, target: File) {
        val buffer = ByteArray(BUFFER_SIZE)
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

    /// Hash the original directory name so sanitized collisions stay separate.
    private fun safeDirName(name: String?): String {
        val cleaned = safeName(name)
        val original = name?.trim().orEmpty()
        return if (cleaned == original) {
            cleaned
        } else {
            "$cleaned-${Integer.toHexString(original.hashCode())}"
        }
    }
}
