package cn.thinktin.app.ui.settings.licenses

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull

/**
 * 客户端核心的第三方组件清单（13.13、16.5；docs/licenses.md 第 1 节）：`tools/licenses/licenses.py` 生成的 `inventory.json`
 * （schema 2），和 `NOTICES.md`、`texts/` 一起由 `sync-core.sh` 放进 `:core` 的 assets（`thinktin-licenses/`）。
 * 和 iOS 的 `LicenseInventory` 同一套解析：宽松，认不出的字段跳过，没有名字的组件不要，原文路径不在清单目录里的不列。
 */
data class LicenseInventory(
    val schema: Int,
    val subject: String,
    val components: List<LicenseComponent>,
) {
    /** 有几种许可证（分组后的组数）。 */
    val licenseCount: Int get() = components.map { it.groupKey }.toSet().size

    /**
     * 按许可证分组：组件多的组在前（一样多的按名字），没声明许可证的放最后；组里按名字、版本排。
     * [query] 不为空时只留匹配的组件，空的组不要。
     */
    fun groups(query: String = ""): List<LicenseGroup> {
        val tokens = searchTokens(query)
        val matching = if (tokens.isEmpty()) components else components.filter { it.matches(tokens) }
        return matching.groupBy { it.groupKey }
            .map { (license, list) -> LicenseGroup(license, list.sortedWith(LicenseComponent.displayOrder)) }
            .sortedWith(
                compareBy<LicenseGroup> { it.license.isEmpty() }
                    .thenByDescending { it.components.size }
                    .thenBy { it.license.lowercase() },
            )
    }

    companion object {
        const val SUPPORTED_SCHEMA = 2
        const val FILE_NAME = "inventory.json"
        const val NOTICES_FILE_NAME = "NOTICES.md"

        private val json = Json { ignoreUnknownKeys = true }

        /** 解析 `inventory.json`。不是 JSON 对象、没有 `components` 时抛 [LicenseInventoryException]。 */
        fun parse(text: String): LicenseInventory {
            val root = try {
                json.parseToJsonElement(text)
            } catch (e: Exception) {
                throw LicenseInventoryException(LicenseInventoryProblem.Malformed, e)
            }
            val obj = root as? JsonObject ?: throw LicenseInventoryException(LicenseInventoryProblem.Malformed)
            val list = obj["components"] as? JsonArray ?: throw LicenseInventoryException(LicenseInventoryProblem.Malformed)
            val seen = mutableMapOf<String, Int>()
            val components = list.mapNotNull { (it as? JsonObject)?.let(::component) }.map { component ->
                // 同一个包同一个版本出现两次（不该有）：id 后面加序号，列表里不打架。
                val count = seen.getOrDefault(component.id, 0)
                seen[component.id] = count + 1
                if (count > 0) component.copy(id = component.id + "#${count + 1}") else component
            }
            return LicenseInventory(
                schema = (obj["schema"] as? JsonPrimitive)?.intOrNull ?: 0,
                subject = obj.string("subject").orEmpty(),
                components = components,
            )
        }

        /**
         * 分组用的许可证写法：只用 `OR` 连起来的几个简单标识排个序、去掉重复的（“MIT OR Apache-2.0”和“Apache-2.0 OR MIT”
         * 是同一组）；别的原样（多余的空白合并）。空的是空串。
         */
        fun normalizedLicense(expression: String?): String {
            val collapsed = expression.orEmpty().trim().split(Regex("\\s+")).filter { it.isNotEmpty() }.joinToString(" ")
            if (collapsed.isEmpty()) return ""
            val parts = collapsed.split(" OR ")
            val simple = parts.all { it.isNotEmpty() && ' ' !in it && '(' !in it && ')' !in it }
            if (parts.size < 2 || !simple) return collapsed
            return parts.distinct().sortedBy { it.lowercase() }.joinToString(" OR ")
        }

        private fun component(obj: JsonObject): LicenseComponent? {
            val name = obj.string("name") ?: return null
            val detections = (obj["file_licenses"] as? JsonArray).orEmpty().mapNotNull { it as? JsonObject }
            return LicenseComponent(
                ecosystem = obj.string("ecosystem").orEmpty(),
                name = name,
                version = obj.string("version").orEmpty(),
                license = obj.string("license"),
                authors = obj.string("authors"),
                sourceUrl = obj.string("source_url")?.takeIf(::isWebUrl),
                restrictedTerms = obj.strings("restricted_terms"),
                texts = texts(obj.strings("files"), obj.strings("bundled_files"), obj.strings("generic_files"), detections),
            )
        }

        /** 原文列表：包里的、包内子目录的、标准文本；同一个文件只列一次，路径不在清单目录里的不列。 */
        private fun texts(
            files: List<String>,
            bundled: List<String>,
            generic: List<String>,
            detections: List<JsonObject>,
        ): List<LicenseText> {
            val seen = mutableSetOf<String>()
            val result = mutableListOf<LicenseText>()
            fun add(path: String, kind: LicenseTextKind) {
                if (!LicenseFiles.isSafePath(path) || !seen.add(path)) return
                val fileName = path.substringAfterLast('/')
                when (kind) {
                    LicenseTextKind.Standard -> {
                        val id = fileName.removeSuffix(".txt")
                        result += LicenseText(path, id, id, kind)
                    }
                    else -> {
                        val wantBundled = kind == LicenseTextKind.Bundled
                        val detection = detections.firstOrNull {
                            it.string("file") == path && ((it["bundled"] as? JsonPrimitive)?.booleanOrNull ?: false) == wantBundled
                        } ?: detections.firstOrNull { it.string("file") == path }
                        val name = detection?.string("path") ?: fileName
                        result += LicenseText(path, name, detection?.string("proposed"), kind)
                    }
                }
            }
            files.forEach { add(it, LicenseTextKind.Original) }
            bundled.forEach { add(it, LicenseTextKind.Bundled) }
            generic.forEach { add(it, LicenseTextKind.Standard) }
            return result
        }

        private fun isWebUrl(raw: String): Boolean {
            val lower = raw.lowercase()
            val rest = when {
                lower.startsWith("https://") -> raw.substring(8)
                lower.startsWith("http://") -> raw.substring(7)
                else -> return false
            }
            return rest.isNotEmpty() && !rest.startsWith("/") && ' ' !in raw
        }

        private fun JsonObject.string(key: String): String? =
            (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull?.trim()?.takeIf { it.isNotEmpty() }

        private fun JsonObject.strings(key: String): List<String> =
            (this[key] as? JsonArray).orEmpty().mapNotNull { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content }

        private fun JsonArray?.orEmpty(): List<JsonElement> = this ?: emptyList()
    }
}

/** 一个第三方组件。 */
data class LicenseComponent(
    val ecosystem: String,
    val name: String,
    val version: String,
    /** SPDX 表达式；没认出来时为 null。 */
    val license: String?,
    val authors: String? = null,
    /** 源码在哪（只认 http(s)）。 */
    val sourceUrl: String? = null,
    /** 原文里有限制性的说法（登记过的例外）。 */
    val restrictedTerms: List<String> = emptyList(),
    val texts: List<LicenseText> = emptyList(),
    val id: String = "$ecosystem:$name@$version",
) {
    val groupKey: String get() = LicenseInventory.normalizedLicense(license)

    /** 每个词都要出现在名字、版本、许可证、作者里的某一处（不分大小写）。 */
    fun matches(tokens: List<String>): Boolean {
        val fields = listOf(name, version, license.orEmpty(), groupKey, authors.orEmpty())
        return tokens.all { token -> fields.any { it.contains(token, ignoreCase = true) } }
    }

    companion object {
        /** 列表里的顺序：名字（不分大小写），同名的按版本号（数字按大小）。 */
        val displayOrder: Comparator<LicenseComponent> =
            compareBy<LicenseComponent> { it.name.lowercase() }.thenComparator { a, b -> compareVersions(a.version, b.version) }

        private fun compareVersions(a: String, b: String): Int {
            val pa = a.split('.', '-', '+')
            val pb = b.split('.', '-', '+')
            for (i in 0 until maxOf(pa.size, pb.size)) {
                val x = pa.getOrNull(i).orEmpty()
                val y = pb.getOrNull(i).orEmpty()
                val nx = x.toLongOrNull()
                val ny = y.toLongOrNull()
                val c = if (nx != null && ny != null) nx.compareTo(ny) else x.compareTo(y)
                if (c != 0) return c
            }
            return 0
        }
    }
}

enum class LicenseTextKind {
    /** 包里带的 LICENSE、NOTICE、COPYING。 */
    Original,

    /** 包里子目录下的原文（打包进来的第三方代码）。 */
    Bundled,

    /** 包里没带原文，用的 SPDX 标准文本。 */
    Standard,
}

/** 一份原文：[path] 相对清单目录；[name] 在包里叫什么（标准文本是 SPDX 标识）。 */
data class LicenseText(val path: String, val name: String, val spdx: String?, val kind: LicenseTextKind)

/** 许可证一样的一组组件（[license] 空串是没声明的）。 */
data class LicenseGroup(val license: String, val components: List<LicenseComponent>)

enum class LicenseInventoryProblem {
    /** 这个包没带清单（CI 的 debug 包、没跑 sync-core.sh）。 */
    NotBundled,

    /** 文件读不出来。 */
    Unreadable,

    /** 不是清单的格式。 */
    Malformed,

    /** 路径不在清单目录里。 */
    InvalidPath,

    /** 文件太大，App 里不显示。 */
    TooLarge,
}

class LicenseInventoryException(val problem: LicenseInventoryProblem, cause: Throwable? = null) :
    Exception(problem.name, cause)

/** 搜索词：按空白分开，不分大小写。 */
fun searchTokens(query: String): List<String> = query.trim().split(Regex("\\s+")).filter { it.isNotEmpty() }

/** 清单目录里的文件。 */
object LicenseFiles {
    /** 原文最大多少字节（清单工具不复制超过 1 MiB 的，这里留点余量）。 */
    const val MAX_TEXT_BYTES = 2 * 1024 * 1024

    /** 相对路径在目录里面：不能是绝对路径，不能有 `..`、`.`、空的路径段、反斜杠。 */
    fun isSafePath(path: String): Boolean {
        if (path.isEmpty() || path.startsWith("/") || path.startsWith("~") || '\\' in path || '\u0000' in path) return false
        return path.split('/').all { it.isNotEmpty() && it != "." && it != ".." }
    }

    /** 换行统一成 `\n`，按空行分段（段落里的换行和缩进保留，行尾空白去掉）。 */
    fun paragraphs(text: String): List<String> {
        val result = mutableListOf<String>()
        val current = mutableListOf<String>()
        for (raw in text.replace("\r\n", "\n").replace('\r', '\n').split('\n')) {
            val line = raw.trimEnd(' ', '\t')
            if (line.isEmpty()) {
                if (current.isNotEmpty()) result += current.joinToString("\n")
                current.clear()
            } else {
                current += line
            }
        }
        if (current.isNotEmpty()) result += current.joinToString("\n")
        return result
    }
}
