pluginManagement {
    plugins {
        id("com.android.library") version "8.1.4"
        id("org.jetbrains.kotlin.android") version "1.9.10"
    }
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "polyfence-core"
