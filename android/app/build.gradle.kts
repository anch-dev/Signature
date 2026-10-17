plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

// GPU backend: on by default; CI falls back to CPU-only if the Vulkan
// toolchain isn't available (-Psignature.vulkan=false).
val vulkan = (project.findProperty("signature.vulkan") as String?)?.toBoolean() ?: true
val versionCodeProp = (project.findProperty("signature.versionCode") as String?)?.toIntOrNull() ?: 1

android {
    namespace = "com.anchdev.signature"
    compileSdk = 35
    ndkVersion = "27.2.12479018"

    defaultConfig {
        applicationId = "com.anchdev.signature"
        minSdk = 28
        targetSdk = 35
        versionCode = versionCodeProp
        versionName = "1.0"
        ndk { abiFilters += "arm64-v8a" }
        buildConfigField("boolean", "VULKAN", vulkan.toString())
        externalNativeBuild {
            cmake {
                arguments += listOf(
                    "-DANDROID_STL=c++_static",
                    "-DSIGNATURE_VULKAN=${if (vulkan) "ON" else "OFF"}",
                )
                // Vulkan headers / glslc / SPIRV-Headers for ggml-vulkan (set by CI).
                System.getenv("SIGNATURE_VULKAN_ARGS")?.split(" ")?.filter { it.isNotBlank() }?.let { arguments += it }
            }
        }
    }

    signingConfigs {
        // Fixed key so installs update in place. It's in the repo on purpose:
        // this is a sideloaded personal app, not a store listing.
        create("signature") {
            storeFile = file("../signing/signature.keystore")
            storePassword = "signature"
            keyAlias = "signature"
            keyPassword = "signature"
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName("signature")
            externalNativeBuild { cmake { arguments += "-DCMAKE_BUILD_TYPE=Release" } }
        }
        debug {
            signingConfig = signingConfigs.getByName("signature")
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures {
        compose = true
        buildConfig = true
    }
    packaging {
        jniLibs { useLegacyPackaging = false }
    }
}

dependencies {
    val bom = platform("androidx.compose:compose-bom:2024.12.01")
    implementation(bom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    implementation("androidx.lifecycle:lifecycle-process:2.8.7")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
}
