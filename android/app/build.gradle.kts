import java.util.Properties

plugins {
 id("com.android.application")
 id("org.jetbrains.kotlin.android")
 id("org.jetbrains.kotlin.plugin.compose")
 id("org.jetbrains.kotlin.plugin.serialization")
}
val releaseProperties = Properties().apply {
 val source = rootProject.file("signing.properties")
 if (source.isFile) source.inputStream().use { load(it) }
}
fun signingValue(property: String, environment: String): String? =
 providers.environmentVariable(environment).orNull?.takeIf { it.isNotBlank() }
  ?: releaseProperties.getProperty(property)?.takeIf { it.isNotBlank() }
val releaseStoreFile = signingValue("storeFile", "STOCKED_ANDROID_KEYSTORE")
val releaseStorePassword = signingValue("storePassword", "STOCKED_ANDROID_STORE_PASSWORD")
val releaseKeyAlias = signingValue("keyAlias", "STOCKED_ANDROID_KEY_ALIAS")
val releaseKeyPassword = signingValue("keyPassword", "STOCKED_ANDROID_KEY_PASSWORD")
val signingValues = listOf(releaseStoreFile, releaseStorePassword, releaseKeyAlias, releaseKeyPassword)
val hasReleaseSigning = signingValues.all { it != null }
require(signingValues.none { it != null } || hasReleaseSigning) {
 "Release signing requires all four settings: storeFile, storePassword, keyAlias and keyPassword."
}

android {
 namespace = "com.sowens.stocked"
 compileSdk = 36
 defaultConfig { applicationId = "com.sowens.stocked"; minSdk = 26; targetSdk = 36; versionCode = 1; versionName = "0.1.0" }
 buildFeatures { compose = true }
 compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
 kotlinOptions { jvmTarget = "17" }
 signingConfigs {
  if (hasReleaseSigning) create("localRelease") {
   storeFile = rootProject.file(releaseStoreFile!!)
   storePassword = releaseStorePassword
   keyAlias = releaseKeyAlias
   keyPassword = releaseKeyPassword
  }
 }
 buildTypes { release {
  isMinifyEnabled = false
  if (hasReleaseSigning) signingConfig = signingConfigs.getByName("localRelease")
 } }
 testOptions { unitTests.isReturnDefaultValues = true }
}
dependencies {
 implementation("androidx.work:work-runtime-ktx:2.10.0")
 implementation("com.google.mlkit:text-recognition:16.0.1")
 implementation("com.google.mlkit:barcode-scanning:17.3.0")
 implementation("androidx.exifinterface:exifinterface:1.3.7")
 testImplementation("org.json:json:20240303")
 implementation("com.squareup.okhttp3:okhttp:4.12.0")
 implementation("androidx.core:core-ktx:1.15.0")
 implementation(platform("androidx.compose:compose-bom:2024.12.01"))
 implementation("androidx.activity:activity-compose:1.9.3")
 implementation("androidx.compose.material3:material3")
 implementation("androidx.compose.material:material-icons-extended")
 implementation("androidx.compose.ui:ui-tooling-preview")
 implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
 implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
 implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")
 implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
 debugImplementation("androidx.compose.ui:ui-tooling")
 testImplementation("junit:junit:4.13.2")
 testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.9.0")
}
