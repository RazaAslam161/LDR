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
}

// :vibration (and other older plugins) ship with compileSdkVersion 33,
// but their AndroidX deps (core-ktx, lifecycle, etc.) require SDK 34+.
// We patch them here during their own afterEvaluate, but skip :app because
// evaluationDependsOn causes it to be evaluated before this block runs,
// and calling afterEvaluate on an already-evaluated project throws an error.
subprojects {
    if (project.name != "app") {
        afterEvaluate {
            extensions.findByType<com.android.build.gradle.BaseExtension>()?.apply {
                compileSdkVersion(36)
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
