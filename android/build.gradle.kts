allprojects {
    repositories {
        maven {
            url = uri("/tmp/spectrulenpor-benchmark-maven")
            content {
                includeGroup("androidx.benchmark")
                includeGroup("androidx.datastore")
                includeGroup("androidx.room")
                includeGroup("androidx.sqlite")
                includeGroup("androidx.arch.core")
                includeGroup("androidx.collection")
                includeGroup("androidx.concurrent")
                includeGroup("androidx.lifecycle")
                includeGroup("androidx.tracing")
                includeGroup("com.squareup.moshi")
                includeGroup("com.squareup.okio")
                includeGroup("com.squareup.wire")
                includeGroup("junit")
                includeGroup("org.hamcrest")
            }
        }
        google()
        mavenCentral()
    }
}

// Keep every Android module on the installed NDK. AGP 9.1 otherwise defaults
// plugin subprojects to NDK 28.2 even when the app explicitly uses 25.2.
subprojects {
    plugins.withId("com.android.application") {
        extensions.configure<com.android.build.api.dsl.ApplicationExtension>("android") {
            ndkVersion = "25.2.9519653"
        }
    }
    plugins.withId("com.android.library") {
        extensions.configure<com.android.build.api.dsl.LibraryExtension>("android") {
            ndkVersion = "25.2.9519653"
        }
    }
    plugins.withId("com.android.test") {
        extensions.configure<com.android.build.api.dsl.TestExtension>("android") {
            ndkVersion = "25.2.9519653"
        }
    }
}

val newBuildDir: Directory = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newBuildDir: Directory = rootProject.layout.buildDirectory.dir(project.name).get()
    project.layout.buildDirectory.value(newBuildDir)
}

subprojects {
    project.evaluationDependsOn(":app")
}

// CameraX 1.5.3 exposes CallbackToFutureAdapter from camera-core's public
// signatures but marks concurrent-futures as runtime-only in its metadata.
// Add it to the CameraX plugin's compile classpath as well as its runtime path.
subprojects {
    if (name == "camera_android_camerax") {
        plugins.withId("com.android.library") {
            dependencies.add("implementation", "androidx.concurrent:concurrent-futures:1.1.0")
        }
    }
}
