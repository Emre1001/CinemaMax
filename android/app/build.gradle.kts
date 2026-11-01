plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.cinemamax.cinemamax"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.cinemamax.cinemamax"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // CI (GitHub Actions): mit dem Schlüssel aus den Repository-Secrets signieren, damit die APK sich über
    // vorhandene Installationen aktualisieren lässt. Lokal ohne CM_KEYSTORE: wie bisher der eigene Debug-Schlüssel.
    val ciKeystore = System.getenv("CM_KEYSTORE")?.let { file(it) }?.takeIf { it.exists() }
    signingConfigs {
        if (ciKeystore != null) {
            create("ci") {
                storeFile = ciKeystore
                // Standardwerte des Android-Debug-Schlüssels, falls keine eigenen gesetzt sind
                storePassword = System.getenv("CM_KEYSTORE_PASSWORD")?.ifEmpty { null } ?: "android"
                keyAlias = System.getenv("CM_KEY_ALIAS")?.ifEmpty { null } ?: "androiddebugkey"
                keyPassword = System.getenv("CM_KEY_PASSWORD")?.ifEmpty { null } ?: "android"
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (ciKeystore != null) signingConfigs.getByName("ci") else signingConfigs.getByName("debug")
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
    // FileProvider für das Selbst-Update (APK an den Installer übergeben)
    implementation("androidx.core:core:1.13.1")
}
