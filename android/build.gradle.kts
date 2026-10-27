allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
    if (name == "reactive_ble_mobile") {
        // BLE 5.4 pins SDK33 upstream; Flutter's AndroidX graph needs SDK34+.
        // Align compilation with the app, without changing target/min SDK or
        // editing the global pub cache. Remove when upgrading the BLE family.
        afterEvaluate {
            extensions.configure<com.android.build.api.dsl.LibraryExtension> {
                compileSdk = 36
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
