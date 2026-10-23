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

// Some plugins (tflite_flutter, google_mlkit_*) pin Java to 11 but leave
// Kotlin on the host JDK's default, which fails Gradle's JVM-target
// validation. Make each plugin's Kotlin target follow its own Java target.
gradle.projectsEvaluated {
    subprojects {
        val javaTarget = tasks.withType<JavaCompile>().firstOrNull()?.targetCompatibility ?: return@subprojects
        tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
            compilerOptions.jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.fromTarget(javaTarget))
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
