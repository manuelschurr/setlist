import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing lives outside the repo; tools/release-key.sh makes it once. Without it a release build falls back to the debug key, which Obtainium installs cannot update.
val signingProperties = (System.getenv("SETLIST_ANDROID_SIGNING") ?: "${System.getProperty("user.home")}/.config/setlist/android/signing.properties")
    .let(::File)
    .takeIf { it.exists() }
    ?.let { file -> Properties().apply { file.inputStream().use(::load) } }

android {
    namespace = "de.schurr.setlist"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "de.schurr.setlist"
        manifestPlaceholders["appLabel"] = "Setlist"
        // 26 for notification channels and VibrationEffect, so the rest alarm needs no compat branches.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (signingProperties != null) {
            create("release") {
                storeFile = file(signingProperties.getProperty("storeFile"))
                storePassword = signingProperties.getProperty("password")
                keyAlias = signingProperties.getProperty("keyAlias")
                keyPassword = signingProperties.getProperty("password")
            }
        }
    }

    buildTypes {
        debug {
            // A separate app on the phone, so a test build never replaces the installed release or its data.
            applicationIdSuffix = ".debug"
            manifestPlaceholders["appLabel"] = "Setlist debug"
        }
        release {
            signingConfig = signingConfigs.getByName(if (signingProperties != null) "release" else "debug")
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
