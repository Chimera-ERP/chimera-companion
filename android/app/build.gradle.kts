import com.android.build.api.instrumentation.AsmClassVisitorFactory
import com.android.build.api.instrumentation.ClassContext
import com.android.build.api.instrumentation.ClassData
import com.android.build.api.instrumentation.InstrumentationParameters
import com.android.build.api.instrumentation.InstrumentationScope
import org.objectweb.asm.ClassVisitor
import org.objectweb.asm.MethodVisitor
import org.objectweb.asm.Opcodes

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}


// SDK 1.0.8 has no logging switch. It prints raw command frames (including
// the operator password) and register replies. Strip only its println(String)
// calls from packaged Android variants. The vendored dependency stays intact.
abstract class DatecsWireLogging : AsmClassVisitorFactory<InstrumentationParameters.None> {
    override fun isInstrumentable(classData: ClassData) = classData.className == "com.datecs.fiscalprinter.FPBase"
    override fun createClassVisitor(classContext: ClassContext, nextClassVisitor: ClassVisitor) =
        object : ClassVisitor(Opcodes.ASM9, nextClassVisitor) {
            override fun visitMethod(access: Int, name: String, descriptor: String, signature: String?,
                                     exceptions: Array<out String>?): MethodVisitor {
                val next = super.visitMethod(access, name, descriptor, signature, exceptions)
                return object : MethodVisitor(Opcodes.ASM9, next) {
                    override fun visitMethodInsn(opcode: Int, owner: String, name: String, descriptor: String, isInterface: Boolean) {
                        if (opcode == Opcodes.INVOKEVIRTUAL && owner == "java/io/PrintStream" &&
                            name == "println" && descriptor == "(Ljava/lang/String;)V")
                            super.visitInsn(Opcodes.POP2)
                        else super.visitMethodInsn(opcode, owner, name, descriptor, isInterface)
                    }
                }
            }
        }
}

androidComponents.onVariants { variant ->
    variant.instrumentation.transformClassesWith(DatecsWireLogging::class.java, InstrumentationScope.ALL) {}
}

val releaseStore = System.getenv("COMPANION_KEYSTORE_PATH")
val releaseCredentials = listOf("COMPANION_KEYSTORE_PASSWORD", "COMPANION_KEY_ALIAS", "COMPANION_KEY_PASSWORD")
if (releaseStore != null) {
    require(releaseCredentials.all { !System.getenv(it).isNullOrBlank() }) {
        "Incomplete Companion signing configuration"
    }
}
if (System.getenv("CI") == "true") {
    require(!releaseStore.isNullOrBlank()) { "CI requires the existing Companion signing identity" }
}

android {
    namespace = "ro.chimeraerp.companion"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Canonical identity. Legacy ro.tabusociety installs require re-enrollment.
        applicationId = "ro.chimeraerp.companion"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        testInstrumentationRunner = "ro.chimeraerp.companion.CustomerDisplayTestRunner"
    }

    signingConfigs {
        if (releaseStore != null) {
            create("companionRelease") {
                storeFile = file(releaseStore)
                storePassword = System.getenv("COMPANION_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("COMPANION_KEY_ALIAS")
                keyPassword = System.getenv("COMPANION_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            // Retain the signing certificate. The new application ID still requires
            // a separate install from the legacy package. CI imports the key
            // explicitly; generating a new key would prevent in-place updates.
            signingConfig = signingConfigs.getByName(
                if (releaseStore != null) "companionRelease" else "debug"
            )
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
    implementation(files("libs/datecs-rou-1.0.8.jar"))
    testImplementation("junit:junit:4.13.2")
}
