plugins {
    id("com.android.library")
    id("kotlin-android")
    id("maven-publish")
    id("signing")
}

group = "com.polyfence"
version = "1.0.0"

android {
    namespace = "com.polyfence.core"
    compileSdk = 34

    defaultConfig {
        minSdk = 21
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
}

dependencies {
    // Google Play Services
    implementation("com.google.android.gms:play-services-location:21.0.1")

    // AndroidX
    implementation("androidx.core:core-ktx:1.10.1")
    implementation("androidx.work:work-runtime-ktx:2.8.1")

    // Testing
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.mockito:mockito-core:5.5.0")
    testImplementation("org.mockito.kotlin:mockito-kotlin:5.1.0")
    androidTestImplementation("androidx.test.ext:junit:1.1.5")
    androidTestImplementation("androidx.test.espresso:espresso-core:3.5.1")
}

publishing {
    publications {
        create<MavenPublication>("release") {
            groupId = "com.polyfence"
            artifactId = "polyfence-core"
            version = project.version.toString()

            afterEvaluate {
                from(components["release"])
            }

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
            }
        }
    }
}
