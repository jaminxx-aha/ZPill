import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val signingProperties = Properties()
val signingPropertiesFile = rootProject.file("key.properties")
if (signingPropertiesFile.exists()) {
    FileInputStream(signingPropertiesFile).use(signingProperties::load)
}

fun signingValue(environmentName: String, propertyName: String): String? =
    System.getenv(environmentName)?.takeIf { it.isNotEmpty() }
        ?: signingProperties.getProperty(propertyName)?.takeIf { it.isNotEmpty() }

val releaseStoreFile = signingValue("ANDROID_KEYSTORE_PATH", "storeFile")
val releaseStorePassword =
    signingValue("ANDROID_KEYSTORE_PASSWORD", "storePassword")
val releaseKeyAlias = signingValue("ANDROID_KEY_ALIAS", "keyAlias")
val releaseKeyPassword = signingValue("ANDROID_KEY_PASSWORD", "keyPassword")
val releaseSigningValues = listOf(
    releaseStoreFile,
    releaseStorePassword,
    releaseKeyAlias,
    releaseKeyPassword,
)
val configuredReleaseSigningValues = releaseSigningValues.count { it != null }
check(
    configuredReleaseSigningValues == 0 ||
        configuredReleaseSigningValues == releaseSigningValues.size,
) {
    "Android release signing is incomplete: provide all four Android signing " +
        "values through environment variables or android/key.properties."
}
val releaseSigningConfigured =
    configuredReleaseSigningValues == releaseSigningValues.size

val brandProperties = Properties()
val brandPropertiesFile = rootProject.file("brand.local.properties")
if (brandPropertiesFile.exists()) {
    brandPropertiesFile.reader(Charsets.UTF_8).use(brandProperties::load)
}

fun brandValue(
    environmentName: String,
    propertyName: String,
    defaultValue: String,
): String =
    System.getenv(environmentName)?.takeIf { it.isNotEmpty() }
        ?: brandProperties.getProperty(propertyName)?.takeIf { it.isNotEmpty() }
        ?: defaultValue

val brandApplicationId =
    brandValue("BRAND_APPLICATION_ID", "applicationId", "com.jaminxx.zpill")
val brandApplicationName =
    brandValue("BRAND_APP_NAME", "appName", "ZPill")

android {
    namespace = "com.jaminxx.zpill"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    buildFeatures {
        resValues = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = brandApplicationId
        resValue("string", "app_name", brandApplicationName)
        // minSdk 29(Android 10):相册导入走现代 MediaStore 免权限路径
        // (RELATIVE_PATH + IS_PENDING 自有贡献零弹窗);不兼容更旧机型
        // (2026-10-04 用户定)。
        minSdk = 29
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (releaseSigningConfigured) {
            create("release") {
                storeFile = rootProject.file(checkNotNull(releaseStoreFile))
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            // Never ship debug-signed artifacts. A release is signed only when
            // all four Android signing values are supplied explicitly.
            signingConfig =
                if (releaseSigningConfigured) signingConfigs.getByName("release")
                else null
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
    // 视频 LUT 导出(VideoLutExportPlugin):Transformer 硬件导出 +
    // 内置 SingleColorLut 效果。版本对齐参考实现(Camera_Bridge 实证
    // 1.9.2 全链可用);ToShortPcm 音频前置在该版本 family 内。
    implementation("androidx.media3:media3-transformer:1.9.2")
    implementation("androidx.media3:media3-effect:1.9.2")
    implementation("androidx.media3:media3-common:1.9.2")
}
