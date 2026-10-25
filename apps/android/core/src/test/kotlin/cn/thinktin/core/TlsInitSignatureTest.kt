package cn.thinktin.core

import android.content.Context
import org.junit.Assert.assertTrue
import org.junit.Test
import java.lang.reflect.Modifier

/**
 * Rust 导出的 JNI 函数是 `Java_cn_thinktin_core_TlsInit_initialize`（静态方法，参数是 Context）：
 * 包名、类名、方法名、`@JvmStatic` 和 `external` 任何一个变了，只有在真机上才会报 UnsatisfiedLinkError。
 * 这里用反射钉住签名；不初始化类（不跑 System.loadLibrary——本机的 .so 是 Linux 版，没有这个 JNI 函数）。
 */
class TlsInitSignatureTest {
    @Test
    fun initializeIsStaticNativeTakingContext() {
        val type = Class.forName("cn.thinktin.core.TlsInit", false, javaClass.classLoader)
        val method = type.getDeclaredMethod("initialize", Context::class.java)
        assertTrue("必须是静态方法（@JvmStatic）", Modifier.isStatic(method.modifiers))
        assertTrue("必须是 native 方法（external）", Modifier.isNative(method.modifiers))
        assertTrue("返回 void", method.returnType == Void.TYPE)
    }
}
