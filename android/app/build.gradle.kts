plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.local.indexed"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Matches the Linux app id. The Dart package and config folder stay
        // named fb_viewer for compatibility with existing data.
        applicationId = "dev.local.indexed"
        minSdk = flutter.minSdkVersion
        // Indexed is validated against the Android 14 device APIs and the AOSP
        // phone. Pin 36 so a Flutter upgrade cannot silently change behavior.
        targetSdk = 36
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // Sideload builds are currently debug-signed. Replace this with a
            // real release signingConfig before publishing a stable identity.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // Required to walk the content:// tree returned by ACTION_OPEN_DOCUMENT_TREE.
    implementation("androidx.documentfile:documentfile:1.0.1")
}

flutter {
    source = "../.."
}
