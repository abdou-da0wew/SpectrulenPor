plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.spectraglass.app"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.spectraglass.app"
        minSdk = 31
        targetSdk = 36
        versionCode = 9
        versionName = "5.2.0"
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
    // ONNX Runtime for YOLO26-Nano on-device inference. Direct Maven dep
    // (NOT via flutter_onnxruntime plugin — that had a gradle subproject
    // build conflict on AGP 9.x). The native .so files are bundled in the AAR.
    implementation("com.microsoft.onnxruntime:onnxruntime-android:1.22.0")
}
