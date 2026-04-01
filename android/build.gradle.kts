plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    id("com.vanniktech.maven.publish")
}

group = "io.polyfence"
version = "1.0.3"

android {
    namespace = "io.polyfence.core"
    compileSdk = 35

    defaultConfig {
        minSdk = 24
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        consumerProguardFiles("consumer-rules.pro")
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }

    kotlinOptions {
        jvmTarget = "1.8"
    }

    lint {
        baseline = file("lint-baseline.xml")
    }

    testOptions {
        unitTests {
            // Stubs unmocked android.jar APIs (e.g. Log); pair with mocked Location in unit tests
            isReturnDefaultValues = true
        }
    }
}

dependencies {
    // Google Play Services
    implementation("com.google.android.gms:play-services-location:21.3.0")

    // AndroidX
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.work:work-runtime-ktx:2.10.0")

    // Testing
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.mockito:mockito-core:5.5.0")
    testImplementation("org.mockito.kotlin:mockito-kotlin:5.1.0")
    androidTestImplementation("androidx.test.ext:junit:1.1.5")
    androidTestImplementation("androidx.test:core-ktx:1.5.0")
    androidTestImplementation("androidx.test:runner:1.5.2")
    androidTestImplementation("androidx.test.espresso:espresso-core:3.5.1")
}

mavenPublishing {
    publishToMavenCentral(com.vanniktech.maven.publish.SonatypeHost.CENTRAL_PORTAL)
    signAllPublications()

    coordinates(
        groupId = "io.polyfence",
        artifactId = "polyfence-core",
        version = project.version.toString()
    )

    pom {
        name.set("Polyfence Core")
        description.set("Privacy-first polygon and circle geofencing engine for Android")
        url.set("https://github.com/polyfence/polyfence-core")
        licenses {
            license {
                name.set("MIT License")
                url.set("https://opensource.org/licenses/MIT")
            }
        }
        developers {
            developer {
                id.set("polyfence")
                name.set("Polyfence")
                email.set("hello@polyfence.io")
            }
        }
        scm {
            connection.set("scm:git:git://github.com/polyfence/polyfence-core.git")
            developerConnection.set("scm:git:ssh://github.com/polyfence/polyfence-core.git")
            url.set("https://github.com/polyfence/polyfence-core")
        }
    }
}
