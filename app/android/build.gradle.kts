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
    // flutter_webrtc 0.12.x épingle compileSdkVersion 31, mais son
    // webrtc-sdk transitive embarque désormais des androidx (fragment,
    // window, activity…) exigeant >= 34 — le build APK échouait sur
    // checkReleaseAarMetadata. On compile ce module contre 36 comme le
    // reste du projet (à retirer quand le plugin mettra son SDK à jour).
    if (name == "flutter_webrtc") {
        afterEvaluate {
            extensions.configure<com.android.build.gradle.LibraryExtension>("android") {
                compileSdk = 36
            }
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
