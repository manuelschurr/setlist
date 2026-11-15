package de.schurr.setlist

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileNotFoundException
import java.io.OutputStream
import java.util.concurrent.Executors

/** A folder the lifter picked through the system picker, such as one in Google Drive, which the app keeps creating and writing documents in after restarts through a persisted tree permission. Also the single file Setlist 0.2 linked, and one-off copies of a file the lifter picks to restore. */
class Documents(private val activity: Activity) : MethodChannel.MethodCallHandler {
    // A getter, because the activity has no context yet when it constructs this.
    private val resolver get() = activity.contentResolver
    // A provider may block on its own work, such as Drive's, so copies run off the main thread, one at a time.
    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var picking: Picking? = null

    private sealed class Picking(val request: Int, val result: MethodChannel.Result) {
        class Folder(result: MethodChannel.Result) : Picking(REQUEST_FOLDER, result)
        class Copy(result: MethodChannel.Result, val to: File) : Picking(REQUEST_COPY, result)

        fun cancel() = result.success(if (this is Copy) false else null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val uri = call.argument<String>("uri")?.let(Uri::parse)
        val near = call.argument<String>("near")?.let(Uri::parse)
        when (call.method) {
            "openFolder" -> pick(Picking.Folder(result), Intent(Intent.ACTION_OPEN_DOCUMENT_TREE), near)
            "pickCopy" -> pick(Picking.Copy(result, File(call.argument<String>("path")!!)), Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("*/*"), near)
            "copyInto" -> {
                val folder = Uri.parse(call.argument<String>("folder")!!)
                offMain(result, folder) { copyInto(folder, call.argument<String>("name")!!, File(call.argument<String>("path")!!)) }
            }
            "write" -> offMain(result, uri!!) {
                if (DocumentsContract.isTreeUri(uri)) refuseBinned(uri)
                write(uri, File(call.argument<String>("path")!!))
                null
            }
            "read" -> offMain(result, uri!!) {
                read(uri, File(call.argument<String>("path")!!))
                null
            }
            "release" -> {
                release(uri!!)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun pick(next: Picking, intent: Intent, near: Uri?) {
        picking?.cancel()
        picking = next
        // A guess that the picker honours it for Drive. A picker that ignores it opens where it last was.
        if (near != null) intent.putExtra(DocumentsContract.EXTRA_INITIAL_URI, if (DocumentsContract.isTreeUri(near)) folderDocument(near) else near)
        activity.startActivityForResult(intent, next.request)
    }

    /** Returns whether the result was one of this class's pickers. */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_FOLDER && requestCode != REQUEST_COPY) return false
        val pending = picking?.takeIf { it.request == requestCode } ?: return true
        picking = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            pending.cancel()
            return true
        }
        when (pending) {
            is Picking.Folder -> try {
                resolver.takePersistableUriPermission(uri, READ_WRITE)
                Log.i(TAG, "linked a folder from ${uri.authority} with a persisted read and write permission")
                pending.result.success(mapOf("uri" to uri.toString(), "name" to (displayName(folderDocument(uri)) ?: "Backup folder")))
            } catch (e: Exception) {
                Log.w(TAG, "no lasting permission on a folder from ${uri.authority}: $e")
                pending.result.error("denied", e.toString(), null)
            }
            // The picker's grant lasts while the activity does, which covers this one read, so nothing is persisted.
            is Picking.Copy -> offMain(pending.result, null) {
                read(uri, pending.to)
                true
            }
        }
        return true
    }

    /** Makes a new document named [name] in the folder and fills it from [from], so no empty file ever carries the name. It never looks for an existing document by name: on Drive a second create makes a duplicate with the same name, and a listing can come back empty while it is still loading (measured 2026-11-15). */
    private fun copyInto(tree: Uri, name: String, from: File): Map<String, String> {
        refuseBinned(tree)
        val doc = DocumentsContract.createDocument(resolver, folderDocument(tree), MIME, name) ?: throw FileNotFoundException("no document created in the folder")
        try {
            write(doc, from)
        } catch (e: Exception) {
            try {
                DocumentsContract.deleteDocument(resolver, doc)
            } catch (left: Exception) {
                Log.w(TAG, "could not delete an unfilled document: $left")
            }
            throw e
        }
        return mapOf("uri" to doc.toString(), "name" to (displayName(doc) ?: name))
    }

    private fun write(uri: Uri, from: File) {
        val (out, mode) = openForWrite(uri)
        val bytes = out.use { stream -> from.inputStream().use { it.copyTo(stream) } }
        Log.i(TAG, "wrote $bytes bytes to ${uri.authority} in mode $mode")
    }

    /** Truncate mode first, so a smaller backup leaves no tail of the old one. A provider that refuses it gets plain "w", which every provider that writes must accept. */
    private fun openForWrite(uri: Uri): Pair<OutputStream, String> {
        try {
            return (resolver.openOutputStream(uri, "wt") ?: throw FileNotFoundException("no stream for $uri")) to "wt"
        } catch (e: SecurityException) {
            throw e
        } catch (e: Exception) {
            Log.w(TAG, "${uri.authority} refused mode wt, trying w: $e")
        }
        return (resolver.openOutputStream(uri, "w") ?: throw FileNotFoundException("no stream for $uri")) to "w"
    }

    private fun read(uri: Uri, to: File) {
        val input = resolver.openInputStream(uri) ?: throw FileNotFoundException("no stream for $uri")
        val bytes = input.use { stream -> to.outputStream().use { stream.copyTo(it) } }
        Log.i(TAG, "read $bytes bytes from ${uri.authority}")
    }

    private fun release(uri: Uri) {
        try {
            resolver.releasePersistableUriPermission(uri, READ_WRITE)
        } catch (e: SecurityException) {
            // Already gone, which is the state the caller asked for.
        }
    }

    /**
     * Whether a persisted read and write permission still covers [uri]: its tree for a folder or a document in it, the document itself for the 0.2 file.
     *
     * This, not the exception, decides `denied` for a call on a linked document: under a tree grant, a document the lifter deleted or moved out of the folder may surface as a SecurityException while the grant is still held.
     */
    private fun holdsGrant(uri: Uri): Boolean = resolver.persistedUriPermissions.any { grant ->
        grant.isReadPermission && grant.isWritePermission && if (DocumentsContract.isTreeUri(uri)) {
            DocumentsContract.isTreeUri(grant.uri) && grant.uri.authority == uri.authority && DocumentsContract.getTreeDocumentId(grant.uri) == DocumentsContract.getTreeDocumentId(uri)
        } else {
            grant.uri == uri
        }
    }

    /**
     * Throws [Binned] when the folder behind a tree URI, or behind a document in it, is in the Drive bin. Drive keeps creating and writing documents in a binned folder without complaint and empties the bin after 30 days, and a binned folder loses its move flag (measured 2026-11-15: flags 332 live, 12 binned, 332 restored). Drive only, because another provider may never offer move on a folder.
     *
     * Only that evidence refuses. A flags query that fails lets the write go ahead and decide.
     */
    private fun refuseBinned(tree: Uri) {
        if (tree.authority != DRIVE) return
        val flags = try {
            resolver.query(folderDocument(tree), arrayOf(DocumentsContract.Document.COLUMN_FLAGS), null, null, null)?.use { if (it.moveToFirst()) it.getInt(0) else null }
        } catch (e: Exception) {
            null
        } ?: return
        if (flags and DocumentsContract.Document.FLAG_SUPPORTS_MOVE == 0) throw Binned()
    }

    private class Binned : Exception("the backup folder is in the Drive bin")

    /** The folder a tree URI points at, as a document. */
    private fun folderDocument(tree: Uri): Uri = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))

    private fun displayName(uri: Uri): String? = try {
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { if (it.moveToFirst()) it.getString(0) else null }
    } catch (e: Exception) {
        null
    }

    /** Runs [work] off the main thread and answers with what it returns. A failure answers `binned` for a folder in the Drive bin, `denied` when the persisted grant behind [granted] is gone, and `failed` for everything else. */
    private fun offMain(result: MethodChannel.Result, granted: Uri?, work: () -> Any?) {
        io.execute {
            try {
                val value = work()
                main.post { result.success(value) }
            } catch (e: Exception) {
                val code = when {
                    e is Binned -> "binned"
                    granted != null && !holdsGrant(granted) -> "denied"
                    else -> "failed"
                }
                Log.w(TAG, "document call failed as $code for ${granted?.authority}: $e")
                main.post { result.error(code, e.toString(), null) }
            }
        }
    }

    companion object {
        private const val TAG = "SetlistDocuments"
        private const val MIME = "application/octet-stream"
        private const val DRIVE = "com.google.android.apps.docs.storage"
        private const val READ_WRITE = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        private const val REQUEST_FOLDER = 7301
        private const val REQUEST_COPY = 7302
    }
}
