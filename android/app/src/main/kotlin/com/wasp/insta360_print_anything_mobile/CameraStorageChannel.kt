package com.wasp.insta360_print_anything_mobile

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.storage.StorageManager
import android.provider.DocumentsContract
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.FileNotFoundException
import java.io.IOException
import java.util.concurrent.Executors

/**
 * Access to the camera's own storage through the Storage Access Framework.
 *
 * Android mounts the Insta360 volume itself (exFAT on the tested GO Ultra), so
 * the app only needs one persisted tree grant for the drive root. All file
 * operations then go through [DocumentsContract]; no raw SCSI/exFAT driver.
 *
 * The tree grant survives reconnects via `takePersistableUriPermission` and is
 * remembered per camera model so the user picks the folder once.
 */
class CameraStorageChannel(private val activity: Activity) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "insta360_print_anything_mobile/camera_storage"

        private const val REQUEST_PICK_TREE = 0x1A35
        private const val PREFS = "camera_storage"
        private const val MAX_READ_BYTES = 64L * 1024 * 1024

        private const val EXTERNAL_STORAGE_AUTHORITY =
            "com.android.externalstorage.documents"
    }

    private val context: Context = activity.applicationContext
    private val resolver get() = context.contentResolver
    private val prefs by lazy { context.getSharedPreferences(PREFS, Context.MODE_PRIVATE) }
    private val io = Executors.newSingleThreadExecutor()

    private var pendingPick: MethodChannel.Result? = null

    fun register(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pickTree" -> pickTree(call.argument<String>("initialUri"), result)
            "rememberedTree" -> {
                val key = call.argument<String>("cameraKey")
                if (key == null) {
                    result.error("bad_args", "cameraKey is required", null)
                    return
                }
                result.success(rememberedTree(key))
            }
            "rememberTree" -> {
                val key = call.argument<String>("cameraKey")
                val uri = call.argument<String>("treeUri")
                if (key == null || uri == null) {
                    result.error("bad_args", "cameraKey and treeUri are required", null)
                    return
                }
                rememberTree(key, uri)
                result.success(true)
            }
            "forgetTree" -> {
                prefs.edit().remove(call.argument<String>("cameraKey")).apply()
                result.success(true)
            }
            "treeInfo" -> {
                val uri = call.argument<String>("treeUri")
                if (uri == null) {
                    result.error("bad_args", "treeUri is required", null)
                    return
                }
                runIo(result) { describeTree(Uri.parse(uri)) }
            }
            "list" -> {
                val uri = treeUriArgument(call, result) ?: return
                val dir = call.argument<String>("relativeDir") ?: ""
                runIo(result) { listFiles(uri, dir) }
            }
            "read" -> {
                val uri = treeUriArgument(call, result) ?: return
                val path = call.argument<String>("relativePath")
                if (path == null) {
                    result.error("bad_args", "relativePath is required", null)
                    return
                }
                runIo(result) { readFile(uri, path) }
            }
            "write" -> {
                val uri = treeUriArgument(call, result) ?: return
                val path = call.argument<String>("relativePath")
                val bytes = call.argument<ByteArray>("bytes")
                if (path == null || bytes == null) {
                    result.error("bad_args", "relativePath and bytes are required", null)
                    return
                }
                runIo(result) { writeFile(uri, path, bytes) }
            }
            "delete" -> {
                val uri = treeUriArgument(call, result) ?: return
                val path = call.argument<String>("relativePath")
                if (path == null) {
                    result.error("bad_args", "relativePath is required", null)
                    return
                }
                runIo(result) { deleteFile(uri, path) }
            }
            "exists" -> {
                val uri = treeUriArgument(call, result) ?: return
                val path = call.argument<String>("relativePath")
                if (path == null) {
                    result.error("bad_args", "relativePath is required", null)
                    return
                }
                runIo(result) { findDocument(uri, path) != null }
            }
            else -> result.notImplemented()
        }
    }

    // ------------------------------------------------------------------
    // picking + remembering the tree
    // ------------------------------------------------------------------

    private fun pickTree(initialUri: String?, result: MethodChannel.Result) {
        if (pendingPick != null) {
            result.error("busy", "a folder picker is already open", null)
            return
        }
        pendingPick = result

        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
            )
            putExtra("android.content.extra.SHOW_ADVANCED", true)
            val start = initialUri?.let(Uri::parse) ?: removableVolumeTreeUri()
            if (start != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                putExtra(DocumentsContract.EXTRA_INITIAL_URI, start)
            }
        }

        try {
            activity.startActivityForResult(intent, REQUEST_PICK_TREE)
        } catch (error: Exception) {
            pendingPick = null
            result.error("picker_failed", error.message, null)
        }
    }

    /** Opens the picker at the root of the first mounted removable volume. */
    private fun removableVolumeTreeUri(): Uri? {
        val manager = context.getSystemService(StorageManager::class.java) ?: return null
        val volume = manager.storageVolumes.firstOrNull { volume ->
            volume.isRemovable &&
                volume.state == Environment.MEDIA_MOUNTED &&
                !volume.isPrimary &&
                volume.uuid != null
        } ?: return null
        val uuid = volume.uuid ?: return null
        return DocumentsContract.buildTreeDocumentUri(
            EXTERNAL_STORAGE_AUTHORITY,
            "$uuid:",
        )
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_PICK_TREE) return false
        val result = pendingPick ?: return true
        pendingPick = null

        if (resultCode != Activity.RESULT_OK) {
            result.success(null)
            return true
        }
        val uri = data?.data
        if (uri == null) {
            result.success(null)
            return true
        }

        try {
            resolver.takePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
            )
        } catch (error: SecurityException) {
            result.error("grant_failed", error.message, null)
            return true
        }
        result.success(uri.toString())
        return true
    }

    private fun hasPersistedPermission(uri: Uri, write: Boolean): Boolean {
        return resolver.persistedUriPermissions.any { permission ->
            permission.uri == uri &&
                permission.isReadPermission &&
                (!write || permission.isWritePermission)
        }
    }

    private fun rememberedTree(cameraKey: String): String? {
        val stored = prefs.getString(cameraKey, null) ?: return null
        val uri = runCatching { Uri.parse(stored) }.getOrNull() ?: return null
        if (!hasPersistedPermission(uri, write = true)) {
            prefs.edit().remove(cameraKey).apply()
            return null
        }
        return stored
    }

    private fun rememberTree(cameraKey: String, treeUri: String) {
        prefs.edit().putString(cameraKey, treeUri).apply()
    }

    private fun describeTree(uri: Uri): Map<String, Any?> {
        val docId = runCatching { DocumentsContract.getTreeDocumentId(uri) }.getOrNull()
        val uuid = docId?.substringBefore(':')?.takeIf { it.isNotEmpty() }
        val manager = context.getSystemService(StorageManager::class.java)
        val volume = manager?.storageVolumes?.firstOrNull { volume ->
            volume.uuid != null && uuid != null && volume.uuid.equals(uuid, ignoreCase = true)
        }
        return mapOf(
            "uri" to uri.toString(),
            "uuid" to uuid,
            "label" to (volume?.getDescription(context) ?: uuid),
            "removable" to (volume?.isRemovable ?: false),
            "mounted" to (volume?.state == Environment.MEDIA_MOUNTED),
            "writable" to hasPersistedPermission(uri, write = true),
        )
    }

    // ------------------------------------------------------------------
    // document operations
    // ------------------------------------------------------------------

    private fun listFiles(treeUri: Uri, relativeDir: String): List<Map<String, Any?>> {
        val dirUri = findDocument(treeUri, relativeDir)
            ?: throw IOException("folder not found: $relativeDir")
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
            treeUri,
            DocumentsContract.getDocumentId(dirUri),
        )
        val columns = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
        )

        val out = ArrayList<Map<String, Any?>>()
        resolver.query(childrenUri, columns, null, null, null)?.use { cursor ->
            while (cursor.moveToNext()) {
                val name = cursor.getString(1) ?: continue
                val mime = cursor.getString(2)
                val size = if (cursor.isNull(3)) null else cursor.getLong(3)
                val modified = if (cursor.isNull(4)) null else cursor.getLong(4)
                val parent = relativeDir.trim('/')
                out.add(
                    mapOf(
                        "name" to name,
                        "path" to if (parent.isEmpty()) name else "$parent/$name",
                        "directory" to (mime == DocumentsContract.Document.MIME_TYPE_DIR),
                        "size" to size,
                        "lastModified" to modified,
                    )
                )
            }
        }
        out.sortBy { it["name"] as String }
        return out
    }

    private fun readFile(treeUri: Uri, relativePath: String): ByteArray {
        val uri = findDocument(treeUri, relativePath)
            ?: throw FileNotFoundException("file not found: $relativePath")

        val size = queryDocumentSize(uri)
        if (size != null && size > MAX_READ_BYTES) {
            throw IOException("file is too large to read: $size bytes")
        }

        resolver.openInputStream(uri).use { input ->
            if (input == null) throw IOException("cannot open $relativePath")
            val buffer = ByteArrayOutputStream()
            val chunk = ByteArray(64 * 1024)
            var total = 0L
            while (true) {
                val read = input.read(chunk)
                if (read < 0) break
                total += read
                if (total > MAX_READ_BYTES) {
                    throw IOException("file is too large to read: $total bytes")
                }
                buffer.write(chunk, 0, read)
            }
            return buffer.toByteArray()
        }
    }

    private fun writeFile(treeUri: Uri, relativePath: String, bytes: ByteArray): Boolean {
        val segments = relativePath.trim('/').split('/').filter { it.isNotEmpty() }
        if (segments.isEmpty()) throw IOException("relativePath is empty")

        var parent = DocumentsContract.buildDocumentUriUsingTree(
            treeUri,
            DocumentsContract.getTreeDocumentId(treeUri),
        )
        for (index in 0 until segments.size - 1) {
            val name = segments[index]
            parent = findChild(treeUri, parent, name)
                ?: DocumentsContract.createDocument(
                    resolver,
                    parent,
                    DocumentsContract.Document.MIME_TYPE_DIR,
                    name,
                )
                ?: throw IOException("cannot create folder $name")
        }

        val fileName = segments.last()
        val existing = findChild(treeUri, parent, fileName)
        val target = existing ?: DocumentsContract.createDocument(
            resolver,
            parent,
            mimeTypeFor(fileName),
            fileName,
        ) ?: throw IOException("cannot create $fileName")

        if (existing == null) {
            val actualName = queryDisplayName(target)
            if (actualName != null && actualName != fileName) {
                // Some providers append an extension for unknown MIME types.
                runCatching { DocumentsContract.deleteDocument(resolver, target) }
                throw IOException("provider created '$actualName' instead of '$fileName'")
            }
        }

        resolver.openOutputStream(target, "wt").use { output ->
            if (output == null) throw IOException("cannot write $relativePath")
            output.write(bytes)
            output.flush()
        }

        val written = queryDocumentSize(target)
        if (written != null && written != bytes.size.toLong()) {
            throw IOException("short write: $written of ${bytes.size} bytes")
        }
        return true
    }

    private fun deleteFile(treeUri: Uri, relativePath: String): Boolean {
        val uri = findDocument(treeUri, relativePath)
            ?: return false
        return DocumentsContract.deleteDocument(resolver, uri)
    }

    private fun findDocument(treeUri: Uri, relativePath: String): Uri? {
        var current = DocumentsContract.buildDocumentUriUsingTree(
            treeUri,
            DocumentsContract.getTreeDocumentId(treeUri),
        )
        val segments = relativePath.trim('/').split('/').filter { it.isNotEmpty() }
        for (segment in segments) {
            current = findChild(treeUri, current, segment) ?: return null
        }
        return current
    }

    private fun findChild(treeUri: Uri, parent: Uri, name: String): Uri? {
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
            treeUri,
            DocumentsContract.getDocumentId(parent),
        )
        val columns = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
        )
        resolver.query(childrenUri, columns, null, null, null)?.use { cursor ->
            while (cursor.moveToNext()) {
                if (cursor.getString(1) == name) {
                    return DocumentsContract.buildDocumentUriUsingTree(
                        treeUri,
                        cursor.getString(0),
                    )
                }
            }
        }
        return null
    }

    private fun queryDocumentSize(uri: Uri): Long? {
        val columns = arrayOf(DocumentsContract.Document.COLUMN_SIZE)
        resolver.query(uri, columns, null, null, null)?.use { cursor ->
            if (cursor.moveToFirst() && !cursor.isNull(0)) return cursor.getLong(0)
        }
        return null
    }

    private fun queryDisplayName(uri: Uri): String? {
        val columns = arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
        resolver.query(uri, columns, null, null, null)?.use { cursor ->
            if (cursor.moveToFirst() && !cursor.isNull(0)) return cursor.getString(0)
        }
        return null
    }

    private fun mimeTypeFor(fileName: String): String {
        return when (fileName.substringAfterLast('.', "").lowercase()) {
            "jpg", "jpeg" -> "image/jpeg"
            "png" -> "image/png"
            "mp4" -> "video/mp4"
            "list", "tmp", "txt" -> "text/plain"
            else -> "application/octet-stream"
        }
    }

    // ------------------------------------------------------------------
    // plumbing
    // ------------------------------------------------------------------

    private fun treeUriArgument(call: MethodCall, result: MethodChannel.Result): Uri? {
        val raw = call.argument<String>("treeUri")
        if (raw == null) {
            result.error("bad_args", "treeUri is required", null)
            return null
        }
        return Uri.parse(raw)
    }

    private fun runIo(result: MethodChannel.Result, block: () -> Any?) {
        io.execute {
            try {
                val value = block()
                activity.runOnUiThread { result.success(value) }
            } catch (error: Exception) {
                activity.runOnUiThread {
                    result.error(errorCode(error), error.message ?: error.toString(), null)
                }
            }
        }
    }

    private fun errorCode(error: Exception): String {
        return when (error) {
            is FileNotFoundException -> "not_found"
            is SecurityException -> "permission_denied"
            else -> "storage_error"
        }
    }
}
