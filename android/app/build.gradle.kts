plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseStore = System.getenv("COMPANION_KEYSTORE_PATH")
val releaseCredentials = listOf("COMPANION_KEYSTORE_PASSWORD", "COMPANION_KEY_ALIAS", "COMPANION_KEY_PASSWORD")
if (releaseStore != null) {
    require(releaseCredentials.all { !System.getenv(it).isNullOrBlank() }) {
        "Incomplete Companion signing configuration"
    }
}
if (System.getenv("CI") == "true") {
    require(!releaseStore.isNullOrBlank()) { "CI requires the existing Companion signing identity" }
}

android {
    namespace = "ro.tabusociety.chimera_companion"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "ro.tabusociety.chimera_companion"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        testInstrumentationRunner = "ro.tabusociety.chimera_companion.CustomerDisplayTestRunner"
    }

    signingConfigs {
        if (releaseStore != null) {
            create("companionRelease") {
                storeFile = file(releaseStore)
                storePassword = System.getenv("COMPANION_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("COMPANION_KEY_ALIAS")
                keyPassword = System.getenv("COMPANION_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            // Existing installations use this historical identity. CI imports it
            // explicitly; generating a new key would prevent in-place updates.
            signingConfig = signingConfigs.getByName(
                if (releaseStore != null) "companionRelease" else "debug"
            )
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
    implementation(files("libs/datecs-rou-1.0.8.jar"))
}
