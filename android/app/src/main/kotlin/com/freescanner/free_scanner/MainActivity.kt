package com.freescanner.free_scanner

import android.text.Html
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.ByteArrayInputStream
import java.util.zip.ZipFile
import javax.xml.parsers.DocumentBuilderFactory

private const val DEVICE_DOCS_CHANNEL = "free_scanner/device_documents"
private const val FILE_PERMISSION_REQUEST = 7402

class MainActivity : FlutterActivity() {
    private var pendingFilePermission: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DEVICE_DOCS_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "viewPdf" -> {
                        val path = call.argument<String>("path")
                        if (path == null) result.error("missing_path", "PDF path is required", null)
                        else {
                            startActivity(Intent(this, PdfViewerActivity::class.java).apply {
                                putExtra("path", path)
                                putExtra("title", call.argument<String>("title") ?: "Document")
                            })
                            result.success(null)
                        }
                    }
                    "hasFileAccess" -> result.success(hasPhoneFileAccess())
                    "requestFileAccess" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                            startActivity(Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                                Uri.parse("package:$packageName")))
                            result.success(null)
                        } else {
                            pendingFilePermission = result
                            requestPermissions(arrayOf(android.Manifest.permission.READ_EXTERNAL_STORAGE,
                                android.Manifest.permission.WRITE_EXTERNAL_STORAGE), FILE_PERMISSION_REQUEST)
                        }
                    }
                    "listDocuments" -> {
                        if (!hasPhoneFileAccess()) result.error("no_file_access", "Allow file access to scan phone documents", null)
                        else Thread {
                            try {
                                val found = scanPhoneStorage()
                                runOnUiThread { result.success(found.first) }
                            } catch (error: Exception) {
                                runOnUiThread { result.error("scan_failed", "Could not scan phone storage", error.message) }
                            }
                        }.start()
                    }
                    "listDirectories" -> {
                        if (!hasPhoneFileAccess()) result.error("no_file_access", "Allow file access to browse folders", null)
                        else Thread {
                            try {
                                val found = scanPhoneStorage(includeFiles = false)
                                runOnUiThread { result.success(found.second) }
                            } catch (error: Exception) {
                                runOnUiThread { result.error("scan_failed", "Could not scan phone folders", error.message) }
                            }
                        }.start()
                    }
                    "extractDocumentText" -> {
                        val path = call.argument<String>("path")
                        if (path == null) result.error("missing_path", "Document path is required", null)
                        else Thread {
                            try {
                                val text = extractOfficeText(File(path))
                                runOnUiThread { result.success(text) }
                            } catch (error: Exception) {
                                runOnUiThread { result.error("preview_failed", "Could not preview this document", error.message) }
                            }
                        }.start()
                    }
                    "renameDocument", "deleteDocument", "copyDocument", "moveDocument" -> {
                        Thread {
                            try {
                                val source = File(call.argument<String>("path") ?: error("Missing source path"))
                                require(source.isFile && isInsideSharedStorage(source, allowRoot = false)) { "Invalid source path" }
                                val value: Any = when (call.method) {
                                    "renameDocument" -> {
                                        var desired = safeDocumentName(call.argument<String>("name") ?: error("Missing name"))
                                        if (!desired.contains('.') && source.extension.isNotBlank()) {
                                            desired = "$desired.${source.extension}"
                                        }
                                        val target = uniqueFile(source.parentFile!!, desired, source)
                                        if (!source.renameTo(target)) error("Rename failed")
                                        target.absolutePath
                                    }
                                    "deleteDocument" -> {
                                        if (!source.delete()) error("Delete failed")
                                        true
                                    }
                                    else -> {
                                        val destination = File(call.argument<String>("destination") ?: error("Missing destination folder")).canonicalFile
                                        require(destination.isDirectory && isInsideSharedStorage(destination, allowRoot = true)) { "Invalid destination folder" }
                                        require(destination.canonicalPath != source.parentFile?.canonicalPath) { "Choose a different folder" }
                                        val target = uniqueFile(destination, source.name)
                                        source.inputStream().use { input -> target.outputStream().use { output -> input.copyTo(output) } }
                                        if (call.method == "moveDocument" && !source.delete()) {
                                            target.delete()
                                            error("Move failed")
                                        }
                                        target.absolutePath
                                    }
                                }
                                runOnUiThread { result.success(value) }
                            } catch (error: Exception) {
                                runOnUiThread { result.error("file_operation_failed", error.message ?: "File operation failed", null) }
                            }
                        }.start()
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger,
            "com.freescanner.free_scanner/app_updates").setMethodCallHandler { call, result ->
            when (call.method) {
                "getAppVersion" -> result.success(
                    packageManager.getPackageInfo(packageName, 0).versionName ?: "0.0.0")
                "downloadUpdate" -> {
                    val uri = call.argument<String>("url")?.let(Uri::parse)
                    if (uri?.scheme != "https" || uri.host != "github.com" ||
                        !uri.path.orEmpty().contains("/releases/download/")) {
                        result.error("INVALID_UPDATE_URL", "The update URL is invalid.", null)
                    } else try {
                        startActivity(Intent(Intent.ACTION_VIEW, uri))
                        result.success(null)
                    } catch (error: Exception) {
                        result.error("UPDATE_DOWNLOAD_FAILED", "Could not open the update download.", error.message)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun hasPhoneFileAccess(): Boolean = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
        Environment.isExternalStorageManager()
    } else {
        checkSelfPermission(android.Manifest.permission.READ_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
    }

    private val documentExtensions = setOf("pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "rtf", "csv", "odt", "ods", "odp", "epub", "html", "htm", "xml", "md")

    private fun storageRoots(): List<File> {
        val roots = mutableListOf(Environment.getExternalStorageDirectory())
        getExternalFilesDirs(null).filterNotNull().forEach { appFolder ->
            val path = appFolder.absolutePath
            val marker = "/Android/data/"
            val index = path.indexOf(marker)
            if (index > 0) roots.add(File(path.substring(0, index)))
        }
        return roots.mapNotNull { runCatching { it.canonicalFile }.getOrNull() }
            .distinctBy { it.path }
            .filter { it.exists() && it.isDirectory }
    }

    private fun isInsideSharedStorage(file: File, allowRoot: Boolean): Boolean {
        val path = file.canonicalPath
        return storageRoots().any { root ->
            path == root.path && allowRoot || path.startsWith(root.path + File.separator)
        }
    }

    private fun scanPhoneStorage(includeFiles: Boolean = true): Pair<List<Map<String, Any>>, List<Map<String, String>>> {
        val files = mutableListOf<Map<String, Any>>()
        val directories = mutableListOf<Map<String, String>>()
        fun walk(folder: File) {
            val children = runCatching { folder.listFiles() }.getOrNull() ?: return
            for (child in children) {
                if (child.isDirectory) {
                    if (child.name.startsWith(".")) continue
                    if (child.parentFile?.name == "Android" && child.name in setOf("data", "obb")) continue
                    directories.add(mapOf("path" to child.absolutePath, "name" to child.name))
                    walk(child)
                } else if (includeFiles && child.isFile && child.extension.lowercase() in documentExtensions) {
                    files.add(mapOf(
                        "path" to child.absolutePath,
                        "name" to child.name,
                        "extension" to child.extension.lowercase(),
                        "size" to child.length(),
                        "modified" to child.lastModified(),
                    ))
                }
            }
        }
        storageRoots().forEachIndexed { index, root ->
            directories.add(mapOf("path" to root.absolutePath, "name" to if (index == 0) "Internal storage" else "External storage"))
            walk(root)
        }
        return files.sortedByDescending { it["modified"] as Long } to directories.sortedBy { it["path"] }
    }

    private fun safeDocumentName(name: String): String = name.trim()
        .replace(Regex("[\\\\/:*?\"<>|]"), "_")
        .ifBlank { "Document" }

    private fun uniqueFile(folder: File, name: String, original: File? = null): File {
        val safeName = safeDocumentName(name)
        val hasExtension = safeName.contains('.')
        val base = if (hasExtension) safeName.substringBeforeLast('.') else safeName
        val extension = if (hasExtension) ".${safeName.substringAfterLast('.')}" else ""
        var candidate = File(folder, safeName)
        var number = 2
        while (candidate.exists() && candidate.canonicalPath != original?.canonicalPath) {
            candidate = File(folder, "$base ($number)$extension")
            number++
        }
        return candidate
    }

    private fun extractOfficeText(file: File): String {
        when (file.extension.lowercase()) {
            "html", "htm" -> return Html.fromHtml(file.readText(), Html.FROM_HTML_MODE_COMPACT).toString()
            "rtf" -> return file.readText()
                .replace(Regex("\\\\'[0-9a-fA-F]{2}"), " ")
                .replace(Regex("\\\\[a-zA-Z]+-?\\d* ?|[{}]"), "")
                .replace(Regex("\\s+"), " ").trim()
        }
        ZipFile(file).use { archive ->
            val extension = file.extension.lowercase()
            val entries = when (extension) {
                "docx" -> listOf("word/document.xml")
                "pptx" -> archive.entries().asSequence().map { it.name }
                    .filter { it.matches(Regex("ppt/slides/slide\\d+\\.xml")) }.sorted().toList()
                "xlsx" -> archive.entries().asSequence().map { it.name }
                    .filter { it.matches(Regex("xl/worksheets/sheet\\d+\\.xml")) }.sorted().toList()
                "odt", "odp", "ods" -> listOf("content.xml")
                "epub" -> archive.entries().asSequence().map { it.name }
                    .filter { it.endsWith(".xhtml", ignoreCase = true) || it.endsWith(".html", ignoreCase = true) }
                    .sorted().toList()
                else -> throw IllegalArgumentException("In-app preview is not available for this file format")
            }
            val sharedStrings = if (extension == "xlsx") {
                archive.getEntry("xl/sharedStrings.xml")?.let { entry ->
                    val document = parseXml(archive.getInputStream(entry).use { it.readBytes() })
                    (0 until document.getElementsByTagNameNS("*", "si").length).map { index ->
                        document.getElementsByTagNameNS("*", "si").item(index).textContent
                    }
                }.orEmpty()
            } else emptyList()

            val sections = entries.mapNotNull { entryName ->
                val entry = archive.getEntry(entryName) ?: return@mapNotNull null
                val document = parseXml(archive.getInputStream(entry).use { it.readBytes() })
                when (extension) {
                    "xlsx" -> (0 until document.getElementsByTagNameNS("*", "row").length).map { rowIndex ->
                        val row = document.getElementsByTagNameNS("*", "row").item(rowIndex) as org.w3c.dom.Element
                        val cells = row.getElementsByTagNameNS("*", "c")
                        (0 until cells.length).map { cellIndex ->
                            val cell = cells.item(cellIndex) as org.w3c.dom.Element
                            val value = cell.getElementsByTagNameNS("*", "v").item(0)?.textContent.orEmpty()
                            if (cell.getAttribute("t") == "s") sharedStrings.getOrNull(value.toIntOrNull() ?: -1).orEmpty() else value
                        }.joinToString("\t")
                    }
                    "pptx" -> (0 until document.getElementsByTagNameNS("*", "sp").length).mapNotNull { index ->
                        document.getElementsByTagNameNS("*", "sp").item(index).textContent.trim().takeIf { it.isNotEmpty() }
                    }
                    "odt", "odp", "ods", "epub" -> (0 until document.getElementsByTagNameNS("*", "p").length).mapNotNull { index ->
                        document.getElementsByTagNameNS("*", "p").item(index).textContent.trim().takeIf { it.isNotEmpty() }
                    }
                    else -> (0 until document.getElementsByTagNameNS("*", "p").length).mapNotNull { index ->
                        document.getElementsByTagNameNS("*", "p").item(index).textContent.trim().takeIf { it.isNotEmpty() }
                    }
                }
            }.flatten()
            return sections.joinToString("\n").ifBlank { "No readable text was found in this document." }
        }
    }

    private fun parseXml(bytes: ByteArray): org.w3c.dom.Document {
        val factory = DocumentBuilderFactory.newInstance().apply {
            isNamespaceAware = true
            setFeature("http://apache.org/xml/features/disallow-doctype-decl", true)
            setFeature("http://xml.org/sax/features/external-general-entities", false)
            setFeature("http://xml.org/sax/features/external-parameter-entities", false)
        }
        return factory.newDocumentBuilder().parse(ByteArrayInputStream(bytes))
    }

    @Deprecated("Deprecated in Android")
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == FILE_PERMISSION_REQUEST) {
            pendingFilePermission?.success(grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED)
            pendingFilePermission = null
        }
    }

}
