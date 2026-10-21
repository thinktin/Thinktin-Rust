# client-core 的 UniFFI 绑定经 JNA 反射调用：类名、方法、字段都不能被混淆或删掉。
-keep class cn.thinktin.core.** { *; }
-keep class com.sun.jna.** { *; }
-keepclassmembers class * extends com.sun.jna.** { public *; }
-dontwarn java.awt.**
-dontwarn com.sun.jna.**
