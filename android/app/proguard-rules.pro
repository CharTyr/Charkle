# Preserve JNA and UniFFI generated bindings
-keep class com.sun.jna.** { *; }
-keep class * implements com.sun.jna.** { *; }
-keep class uniffi.** { *; }
-dontwarn java.awt.**
-dontwarn javax.swing.**

# Preserve kotlinx.serialization DTOs & generated serializers
-keepattributes *Annotation*, InnerClasses
-dontnote kotlinx.serialization.AnnotationsKt
-keepclassmembers class kotlinx.serialization.json.** {
    *** Companion;
}
-keepclasseswithmembers class kotlinx.serialization.json.** {
    kotlinx.serialization.KSerializer serializer(...);
}
-keep,includedescriptorclasses class com.charkle.android.core.**$$serializer { *; }
-keepclassmembers class com.charkle.android.core.** {
    *** Companion;
}
-keepclasseswithmembers class com.charkle.android.core.** {
    kotlinx.serialization.KSerializer serializer(...);
}

# Preserve WorkManager workers, Glance widgets, and Quick Settings Tile
-keep class com.charkle.android.system.** { *; }
