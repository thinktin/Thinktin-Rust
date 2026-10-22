package cn.thinktin.data.model

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.longOrNull

/** 空 JSON 对象（payload 解析失败时的回退值）。 */
val EmptyJsonObject: JsonObject = JsonObject(emptyMap())

internal val ThinktinJson: Json = Json {
    ignoreUnknownKeys = true
    isLenient = true
}

/** 把 JSON 字符串解析成对象；不是合法 JSON 或不是对象时返回空对象，不抛异常。 */
fun parseJsonObject(text: String): JsonObject =
    try {
        ThinktinJson.parseToJsonElement(text) as? JsonObject ?: EmptyJsonObject
    } catch (_: IllegalArgumentException) {
        // kotlinx.serialization 的解析错误（SerializationException）是 IllegalArgumentException 的子类。
        EmptyJsonObject
    }

/** 取字符串字段；不存在或不是字符串时为 null。 */
fun JsonObject.string(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull

/** 取整数字段；不存在或不是数字时为 null。 */
fun JsonObject.long(key: String): Long? = (this[key] as? JsonPrimitive)?.longOrNull

fun JsonObject.obj(key: String): JsonObject? = this[key] as? JsonObject

fun JsonObject.array(key: String): List<JsonElement> = (this[key] as? JsonArray).orEmpty()
