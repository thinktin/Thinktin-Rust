package cn.thinktin.data.model

/**
 * 保险箱的规则（13.14）：和服务端 gateway `routes/vault.rs` 一样。App 在本地先拦（省一次来回），Mock 照着校验。
 * 长度按码点数（Rust 的 `chars().count()`），控制字符是 Unicode 的 Cc 类（Rust 的 `char::is_control`）。
 */
object VaultRules {
    /** 每个用户最多存几条。 */
    const val MAX_ITEMS = 200
    const val MAX_NAME = 64
    const val MAX_PURPOSE = 200
    const val MAX_USERNAME = 256

    /** 比这短的密码没法可靠地从对话和日志里抹掉（服务端的 `MIN_PASSWORD_LEN`）。 */
    const val MIN_PASSWORD = 4
    const val MAX_PASSWORD_BYTES = 4096

    /** 一条最多限定给几个实例。 */
    const val MAX_INSTANCES = 50

    private val NAME = Regex("^[a-z0-9][a-z0-9_-]{0,63}$")

    enum class PasswordProblem { TooShort, TooLong, ControlCharacters }

    /** 条目名：1–64 个小写字母、数字、`_`、`-`，字母或数字开头（服务端的 `valid_vault_name`）。 */
    fun isValidName(name: String): Boolean = NAME.matches(name)

    fun length(text: String): Int = text.codePointCount(0, text.length)

    fun hasControlCharacters(text: String): Boolean =
        text.codePoints().anyMatch { Character.getType(it) == Character.CONTROL.toInt() }

    fun passwordProblem(password: String): PasswordProblem? = when {
        length(password) < MIN_PASSWORD -> PasswordProblem.TooShort
        password.toByteArray(Charsets.UTF_8).size > MAX_PASSWORD_BYTES -> PasswordProblem.TooLong
        hasControlCharacters(password) -> PasswordProblem.ControlCharacters
        else -> null
    }

    /** 名字输入时的清理：大写转小写、空格换成 `-`，只留规则内的字符，最多 64 个。 */
    fun cleanName(raw: String): String =
        raw.lowercase().replace(' ', '-').filter { it in 'a'..'z' || it in '0'..'9' || it == '_' || it == '-' }.take(MAX_NAME)
}
