plugins {
    id("com.android.test")
    id("org.jetbrains.kotlin.android")
}

// AGP 9.1's com.android.test plugin exposes TestExtension explicitly.
extensions.configure<com.android.build.gradle.TestExtension>("android") {
    namespace = "com.spectraglass.benchmark"
    compileSdkVersion(37)
    targetProjectPath = ":app"

    defaultConfig {
        minSdkVersion(31)
        targetSdkVersion(36)
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildTypes {
        create("benchmark") {
            isDebuggable = true
        }
    }
}

dependencies {
    implementation("androidx.benchmark:benchmark-macro-junit4:1.5.0")
    implementation("androidx.test:runner:1.7.0")
    implementation("androidx.test.ext:junit:1.3.0")
    implementation("androidx.test.uiautomator:uiautomator:2.4.1")
}
