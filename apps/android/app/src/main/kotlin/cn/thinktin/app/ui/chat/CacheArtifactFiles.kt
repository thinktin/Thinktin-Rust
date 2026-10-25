package cn.thinktin.app.ui.chat

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

/**
 * 产出物存在缓存目录 `artifacts/<产出物 id>/<文件名>`（FileProvider 的 cache-path 只开放这个子目录）。
 * 文件名和 id 里的路径分隔符等换成下划线，不会写到目录外面。
 */
class CacheArtifactFiles(
    private val root: File,
    private val io: CoroutineDispatcher = Dispatchers.IO,
) : ArtifactFiles {
    override suspend fun save(artifactId: String, name: String, bytes: ByteArray): File = withContext(io) {
        val dir = File(File(root, DIR), safe(artifactId, "artifact"))
        if (!dir.isDirectory && !dir.mkdirs()) throw java.io.IOException("mkdirs failed: $dir")
        val file = File(dir, safe(name, "file"))
        file.writeBytes(bytes)
        file
    }

    companion object {
        const val DIR = "artifacts"

        /** 只留文件名里安全的字符；不能是 . / ..（空的用 [fallback]）。 */
        fun safe(name: String, fallback: String): String {
            val cleaned = name.replace(Regex("[\\\\/:*?\"<>|\\x00-\\x1f]"), "_").trim().take(120)
            return if (cleaned.isEmpty() || cleaned == "." || cleaned == "..") fallback else cleaned
        }
    }
}
