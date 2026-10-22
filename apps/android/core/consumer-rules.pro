# client-core 的 UniFFI 绑定经 JNA 反射调用：类名、方法、字段都不能被混淆或删掉。
-keep class cn.thinktin.core.** { *; }
-keep class com.sun.jna.** { *; }
-keepclassmembers class * extends com.sun.jna.** { public *; }
-dontwarn java.awt.**
-dontwarn com.sun.jna.**
# 系统证书校验的 Java 部分（org.rustls:rustls-platform-verifier）只经 JNI 从 Rust 调用，R8 看不到：必须保留。
-keep, includedescriptorclasses class org.rustls.platformverifier.** { *; }
