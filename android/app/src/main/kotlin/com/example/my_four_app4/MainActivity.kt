package com.example.my_four_app4

import android.content.ContentValues
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream

class MainActivity: FlutterActivity() {
    private val CHANNEL = "gallery_saver"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "saveToGallery") {
                val filePath = call.argument<String>("filePath")
                if (filePath != null) {
                    val saved = saveImageToGallery(filePath)
                    if (saved) {
                        result.success(true)
                    } else {
                        result.error("SAVE_FAILED", "保存到相册失败", null)
                    }
                } else {
                    result.error("INVALID_PATH", "文件路径为空", null)
                }
            } else {
                result.notImplemented()
            }
        }
    }

    private fun saveImageToGallery(filePath: String): Boolean {
        return try {
            val file = File(filePath)
            if (!file.exists()) return false

            val fileName = "schedule_${System.currentTimeMillis()}.png"
            
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                // Android 10+ 使用 MediaStore
                val values = ContentValues().apply {
                    put(MediaStore.Images.Media.DISPLAY_NAME, fileName)
                    put(MediaStore.Images.Media.MIME_TYPE, "image/png")
                    put(MediaStore.Images.Media.RELATIVE_PATH, Environment.DIRECTORY_PICTURES + "/排班表")
                    put(MediaStore.Images.Media.IS_PENDING, 1)
                }
                
                val resolver = contentResolver
                val uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
                
                if (uri != null) {
                    resolver.openOutputStream(uri)?.use { outputStream ->
                        FileInputStream(file).use { inputStream ->
                            inputStream.copyTo(outputStream)
                        }
                    }
                    values.clear()
                    values.put(MediaStore.Images.Media.IS_PENDING, 0)
                    resolver.update(uri, values, null, null)
                    true
                } else {
                    false
                }
            } else {
                // Android 9 以下
                val picturesDir = Environment.getExternalStoragePublicDirectory(
                    Environment.DIRECTORY_PICTURES
                )
                val appDir = File(picturesDir, "排班表")
                if (!appDir.exists()) appDir.mkdirs()
                
                val destFile = File(appDir, fileName)
                file.copyTo(destFile, overwrite = true)
                
                // 通知系统扫描新文件
                val intent = android.content.Intent(
                    android.content.Intent.ACTION_MEDIA_SCANNER_SCAN_FILE,
                    android.net.Uri.fromFile(destFile)
                )
                sendBroadcast(intent)
                true
            }
        } catch (e: Exception) {
            e.printStackTrace()
            false
        }
    }
}
