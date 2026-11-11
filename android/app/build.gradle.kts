plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.uzv"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "app.novaplay.player"
        minSdk = 24 // observed minSdk of the original
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk { abiFilters += listOf("armeabi-v7a", "arm64-v8a") }
        manifestPlaceholders["enableImpeller"] = System.getenv("UZV_ENABLE_IMPELLER")?.takeIf { it.isNotBlank() } ?: "true"
    }

    sourceSets {
        // Native libraries that must not live in the repository (libnode.so, libmpv.so and its ffmpeg libraries): point
        // UZV_EXTRA_JNILIBS at a directory laid out like jniLibs (<dir>/<abi>/lib*.so) when building.
        System.getenv("UZV_EXTRA_JNILIBS")?.takeIf { it.isNotBlank() }?.let { dir ->
            getByName("main").jniLibs.srcDir(dir)
        }
    }

    externalNativeBuild {
        // JNI glue for libmpv (dlopen-based, see src/main/cpp/uzv_mpv.c).
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    buildTypes {
        release {
            proguardFiles(getDefaultProguardFile("proguard-android.txt"), "proguard-rules.pro")
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // ExoPlayer is the default kernel (changelog mentions an "Exo" kernel and Exo subtitles).
    implementation("androidx.media3:media3-exoplayer:1.4.1")
    implementation("androidx.media3:media3-exoplayer-hls:1.4.1")
    implementation("androidx.media3:media3-exoplayer-dash:1.4.1")
    implementation("androidx.media3:media3-ui:1.4.1")
    implementation("androidx.media3:media3-session:1.4.1")
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")
    testImplementation("junit:junit:4.13.2")
    // Node.js runtime and libmpv/libavcodec are native libraries that must be dropped into
    // android/app/src/main/jniLibs/<abi>/ (libnode.so, libflutter_nodejs_mobile.so, libmpv.so, ...).
}
