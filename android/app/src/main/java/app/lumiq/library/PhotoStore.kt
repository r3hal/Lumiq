package app.lumiq.library

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.LruCache
import androidx.compose.runtime.mutableStateListOf
import androidx.core.content.FileProvider
import androidx.exifinterface.media.ExifInterface
import java.io.File
import java.io.FileOutputStream
import kotlin.math.max

/**
 * The in-app photo library (like the iPhone PhotoLibrary): photos live in the
 * app's private storage; "Also save to Gallery" additionally copies each new
 * capture to Pictures/Lumiq.
 */
class PhotoStore(private val context: Context) {
    private val directory = File(context.filesDir, "photos").apply { mkdirs() }
    val photos = mutableStateListOf<File>()
    private val thumbnails = object : LruCache<String, Bitmap>(24 * 1024 * 1024) {
        override fun sizeOf(key: String, value: Bitmap) = value.byteCount
    }

    init { reload() }

    fun reload() {
        val files = directory.listFiles().orEmpty()
            .filter { it.isFile && it.name.endsWith(".jpg") }
            .sortedByDescending { it.name }
        photos.clear()
        photos.addAll(files)
    }

    val storageBytes: Long get() = photos.sumOf { it.length() }

    /** Moves a fresh capture into the library unchanged (full quality; EXIF orientation is honored when shown). */
    fun importCapture(source: File, alsoToGallery: Boolean): File? {
        val target = File(directory, "Lumiq-${System.currentTimeMillis()}.jpg")
        val ok = source.renameTo(target) || runCatching { source.copyTo(target, overwrite = true); true }.getOrDefault(false)
        source.delete()
        if (!ok || target.length() == 0L) { target.delete(); return null }
        photos.add(0, target)
        if (alsoToGallery) exportToGallery(target)
        return target
    }

    fun saveEdited(bitmap: Bitmap, replacing: File?): File {
        val target = replacing ?: File(directory, "Lumiq-${System.currentTimeMillis()}.jpg")
        FileOutputStream(target).use { bitmap.compress(Bitmap.CompressFormat.JPEG, 95, it) }
        thumbnails.remove(target.path)
        if (replacing == null) photos.add(0, target) else {
            val index = photos.indexOf(target)
            if (index >= 0) { photos.removeAt(index); photos.add(index, target) }
        }
        return target
    }

    fun delete(file: File) {
        file.delete()
        thumbnails.remove(file.path)
        photos.remove(file)
    }

    fun exportToGallery(file: File): Boolean = runCatching {
        val resolver = context.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, file.name)
            put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
            if (Build.VERSION.SDK_INT >= 29) {
                put(MediaStore.Images.Media.RELATIVE_PATH, Environment.DIRECTORY_PICTURES + "/Lumiq")
                put(MediaStore.Images.Media.IS_PENDING, 1)
            }
        }
        val uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values) ?: return false
        resolver.openOutputStream(uri)?.use { out -> file.inputStream().use { it.copyTo(out) } }
        if (Build.VERSION.SDK_INT >= 29) {
            values.clear()
            values.put(MediaStore.Images.Media.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
        }
        true
    }.getOrDefault(false)

    fun shareIntent(file: File): Intent {
        val uri = FileProvider.getUriForFile(context, context.packageName + ".files", file)
        return Intent.createChooser(
            Intent(Intent.ACTION_SEND).setType("image/jpeg").putExtra(Intent.EXTRA_STREAM, uri)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION),
            "Share photo",
        )
    }

    fun thumbnail(file: File, maxPixels: Int = 360): Bitmap? {
        val key = file.path + "#" + maxPixels + "#" + file.lastModified()
        thumbnails.get(key)?.let { return it }
        return decodeUpright(file, maxPixels)?.also { thumbnails.put(key, it) }
    }

    companion object {
        /** Decodes a JPEG, downsampled to roughly `maxPixels` on the long side, applying EXIF orientation. */
        fun decodeUpright(file: File, maxPixels: Int): Bitmap? {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(file.path, bounds)
            if (bounds.outWidth <= 0) return null
            var sample = 1
            val longSide = max(bounds.outWidth, bounds.outHeight)
            while (longSide / (sample * 2) >= maxPixels) sample *= 2
            val bitmap = BitmapFactory.decodeFile(file.path, BitmapFactory.Options().apply { inSampleSize = sample }) ?: return null
            val orientation = runCatching {
                ExifInterface(file.path).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
            }.getOrDefault(ExifInterface.ORIENTATION_NORMAL)
            val matrix = Matrix()
            when (orientation) {
                ExifInterface.ORIENTATION_ROTATE_90 -> matrix.postRotate(90f)
                ExifInterface.ORIENTATION_ROTATE_180 -> matrix.postRotate(180f)
                ExifInterface.ORIENTATION_ROTATE_270 -> matrix.postRotate(270f)
                ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.postScale(-1f, 1f)
                ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.postScale(1f, -1f)
                ExifInterface.ORIENTATION_TRANSPOSE -> { matrix.postRotate(90f); matrix.postScale(-1f, 1f) }
                ExifInterface.ORIENTATION_TRANSVERSE -> { matrix.postRotate(270f); matrix.postScale(-1f, 1f) }
                else -> return bitmap
            }
            val rotated = Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
            if (rotated != bitmap) bitmap.recycle()
            return rotated
        }
    }
}
