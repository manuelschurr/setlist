package de.schurr.setlist

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileNotFoundException
import java.io.OutputStream
import java.util.concurrent.Executors

/** A document the lifter created through the system picker, such as a file in Google Drive, which the app keeps writing after restarts through a persisted permission. */
class Documents(private val activity: Activity) : MethodChannel.MethodCallHandler {
    // A getter, because the activity has no context yet when it constructs this.
    private val resolver get() = activity.contentResolver
    // A provider may block on its own work, such as Drive's, so copies run off the main thread, one at a time.
    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var creating: MethodChannel.Result? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val uri = call.argument<String>("uri")?.let(Uri::parse)
        when (call.method) {
            "create" -> create(call.argument<String>("name")!!, result)
            "write" -> offMain(result, uri!!) { write(uri, File(call.argument<String>("path")!!)) }
            "read" -> offMain(result, uri!!) { read(uri, File(call.argument<String>("path")!!)) }
            "release" -> {
                release(uri!!)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun create(name: String, result: MethodChannel.Result) {
        creating?.success(null)
        creating = result
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("application/octet-stream").putExtra(Intent.EXTRA_TITLE, name)
        activity.startActivityForResult(intent, REQUEST_CREATE)
    }

    /** Returns whether the result was the picker's. */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CREATE) return false
        val result = creating ?: return true
        creating = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return true
        }
        try {
            resolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            Log.i(TAG, "linked a document from ${uri.authority} with a persisted read and write permission")
            result.success(mapOf("uri" to uri.toString(), "name" to (displayName(uri) ?: "Backup file")))
        } catch (e: Exception) {
            fail(result, uri, e)
        }
        return true
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
            resolver.releasePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        } catch (e: SecurityException) {
            // Already gone, which is the state the caller asked for.
        }
    }

    private fun displayName(uri: Uri): String? = try {
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { if (it.moveToFirst()) it.getString(0) else null }
    } catch (e: Exception) {
        null
    }

    private fun offMain(result: MethodChannel.Result, uri: Uri, work: () -> Unit) {
        io.execute {
            try {
                work()
                main.post { result.success(null) }
            } catch (e: Exception) {
                main.post { fail(result, uri, e) }
            }
        }
    }

    private fun fail(result: MethodChannel.Result, uri: Uri?, e: Exception) {
        Log.w(TAG, "document call failed for ${uri?.authority}: $e")
        result.error(if (e is SecurityException) "denied" else "failed", e.toString(), null)
    }

    companion object {
        private const val TAG = "SetlistDocuments"
        private const val REQUEST_CREATE = 7301
    }
}
