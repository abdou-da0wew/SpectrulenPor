plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.spectraglass.app"
    compileSdk = 36  // latest stable = Android 16 (API 36); supports Android 12-17
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.spectraglass.app"
        // Android 12 (API 31) is the minimum target — required for BLUETOOTH_SCAN/CONNECT
        // (pre-12 BLE runtime permission flow is no longer used by ESP32-CAM firmware)
        minSdk = 31
        targetSdk = 36
        versionCode = 4
        versionName = "3.2.0"
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
            isMinifyEnabled = false
            isShrinkResources = false
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
    implementation("androidx.core:core-ktx:1.13.1")
}
