import java.io.File
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val signingDirectory = System.getenv("DESKBAR_SIGNING_DIR")
    ?.takeIf { it.isNotBlank() }
    ?.let(::file)
    ?: File(System.getProperty("user.home"), ".config/deskbar/signing")
val signingPropertiesFile = System.getenv("DESKBAR_SIGNING_PROPERTIES")
    ?.takeIf { it.isNotBlank() }
    ?.let(::file)
    ?: File(signingDirectory, "deskbar-release.properties")
val signingProperties = Properties()
if (signingPropertiesFile.isFile) {
    signingPropertiesFile.inputStream().use(signingProperties::load)
}

fun signingValue(environment: String, property: String): String? =
    System.getenv(environment)?.takeIf { it.isNotBlank() }
        ?: signingProperties.getProperty(property)?.takeIf { it.isNotBlank() }

val releaseKeystorePath = signingValue("DESKBAR_ANDROID_KEYSTORE_FILE", "keystoreFile")
    ?: File(signingDirectory, "deskbar-release.keystore").path
val releaseKeystore = file(releaseKeystorePath)
val releaseStorePassword = signingValue(
    "DESKBAR_ANDROID_KEYSTORE_PASSWORD",
    "keystorePassword",
)
val releaseKeyAlias = signingValue("DESKBAR_ANDROID_KEY_ALIAS", "keyAlias")
val releaseKeyPassword = signingValue("DESKBAR_ANDROID_KEY_PASSWORD", "keyPassword")
val releaseSigningConfigured = releaseKeystore.isFile &&
    !releaseStorePassword.isNullOrBlank() &&
    !releaseKeyAlias.isNullOrBlank() &&
    !releaseKeyPassword.isNullOrBlank()
val releaseRequested = gradle.startParameter.taskNames.any {
    it.contains("Release", ignoreCase = true)
}
if (releaseRequested && !releaseSigningConfigured) {
    throw GradleException(
        "DeskBar release signing is not configured. Set DESKBAR_ANDROID_* variables " +
            "or create ~/.config/deskbar/signing/deskbar-release.properties.",
    )
}

android {
    namespace = "app.deskbar.workbench"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "app.deskbar.workbench"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 28
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    if (releaseSigningConfigured) {
        signingConfigs {
            create("deskbarRelease") {
                storeFile = releaseKeystore
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
                // The keystore is generated once and shared by local and CI release builds.
                storeType = "JKS"
            }
        }
    }

    buildTypes {
        release {
            if (releaseSigningConfigured) {
                signingConfig = signingConfigs.getByName("deskbarRelease")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("androidx.core:core:1.16.0")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
}
