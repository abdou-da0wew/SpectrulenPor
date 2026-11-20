allprojects {
    repositories {
        google()
        mavenCentral()
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
