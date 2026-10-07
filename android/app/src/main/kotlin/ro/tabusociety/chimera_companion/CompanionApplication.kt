package ro.tabusociety.chimera_companion

import android.app.Application
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor

/** Retain the API isolate when switching from Companion to the POS browser. */
class CompanionApplication : Application() {
    val engine: FlutterEngine by lazy {
        FlutterEngine(this).also {
            it.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        }
    }
}
