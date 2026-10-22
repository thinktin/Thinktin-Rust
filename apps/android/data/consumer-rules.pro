# androidx.security:security-crypto 依赖的 Tink 引用了只在编译期用的注解（errorprone、JSR 305），运行时不需要。
-dontwarn com.google.errorprone.annotations.**
-dontwarn javax.annotation.**
