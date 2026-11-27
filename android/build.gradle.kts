import java.io.File

plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.compose.compiler) apply false
    alias(libs.plugins.kotlin.serialization) apply false
}

// Keep Gradle build intermediates outside cloud-synced workspace folders (e.g. macOS iCloud Drive)
// so file sync daemons never duplicate .class/.dex/.so outputs during compilation.
val externalBuildRoot = System.getenv("CHARKLE_ANDROID_BUILD_DIR")
    ?.takeIf { it.isNotBlank() }
    ?.let(::File)
    ?: File(System.getProperty("user.home"), ".cache/charkle-android-build")

allprojects {
    layout.buildDirectory.set(File(externalBuildRoot, project.name))
}
