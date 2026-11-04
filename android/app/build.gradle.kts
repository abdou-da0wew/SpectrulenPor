import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

// Release keystore is resolved from android/key.properties (gitignored).
// Generate it with:
//   keytool -genkey -v -keystore ~/spectrulenpor-release.keystore \
//           -alias spectrulenpor -keyalg RSA -keysize 2048 -validity 10000
// and a key.properties containing storeFile/storePassword/keyAlias/keyPassword.
// When the file is absent (CI/dev), release falls back to the debug keystore
// so `flutter build apk` never hard-fails — do NOT ship that build publicly.
val keystoreProperties = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
val hasReleaseKeystore = keystoreProperties["storeFile"] != null

android {
    namespace = "com.spectraglass.app"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    defaultConfig {
        applicationId = "com.spectraglass.app"
        minSdk = 31
        targetSdk = 36
        versionCode = 15
        versionName = "5.5.0"
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            // R8/minify stays OFF: ONNX Runtime + Flutter jni bindings need a
            // curated keep-rule set; enable together with a proguard-rules.pro
            // covering com.microsoft.onnxruntime once validated on-device.
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
