package app.lumiq

import android.content.Context
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeOut
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import app.lumiq.aishot.AIShotConfig
import app.lumiq.aishot.AIShotModel
import app.lumiq.camera.CameraController
import app.lumiq.camera.CameraScreen
import app.lumiq.editing.PhotoEditorScreen
import app.lumiq.explore.GoldenHourScreen
import app.lumiq.library.LibraryScreen
import app.lumiq.library.PhotoStore
import app.lumiq.library.PhotoViewerScreen
import app.lumiq.settings.AppSettings
import app.lumiq.settings.SettingsScreen
import app.lumiq.ui.Haptics
import app.lumiq.ui.LumiqSplash
import app.lumiq.ui.LumiqTheme
import app.lumiq.ui.Palette
import app.lumiq.update.AppUpdater
import app.lumiq.update.UpdateDialog
import java.io.File

/** App-wide objects (the iPhone app passes these as environment objects). */
class AppState(context: Context) {
    val settings = AppSettings(context)
    val store = PhotoStore(context)
    val aiConfig = AIShotConfig(context)
    val haptics = Haptics(context)
    val camera = CameraController(context)
    val aiShot = AIShotModel(aiConfig, haptics)
    val updater = AppUpdater(context)

    fun release() {
        updater.release()
        aiShot.dispose()
        camera.release()
    }
}

sealed class Screen {
    object Camera : Screen()
    object Library : Screen()
    data class Viewer(val file: File) : Screen()
    data class Editor(val file: File, val captureReview: Boolean) : Screen()
    object Settings : Screen()
    object GoldenHour : Screen()
}

class MainActivity : ComponentActivity() {
    private var state: AppState? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        installSplashScreen()
        super.onCreate(savedInstanceState)
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
        )
        val app = AppState(applicationContext)
        state = app
        // Optional update check on a fresh start (not when Android recreates the activity).
        if (savedInstanceState == null) app.updater.checkAutomatically()
        setContent { LumiqTheme { LumiqApp(app) } }
    }

    override fun onDestroy() {
        state?.release()
        state = null
        super.onDestroy()
    }
}

@Composable
private fun LumiqApp(app: AppState) {
    val stack = remember { mutableStateListOf<Screen>(Screen.Camera) }
    var showSplash by rememberSaveable { mutableStateOf(true) }
    val top = stack.last()

    fun push(screen: Screen) { stack.add(screen) }
    fun pop() { if (stack.size > 1) stack.removeAt(stack.lastIndex) }

    BackHandler(enabled = stack.size > 1) { pop() }

    Box(Modifier.fillMaxSize().background(Palette.ink)) {
        when (top) {
            Screen.Camera -> CameraScreen(
                app,
                onOpenLibrary = { push(Screen.Library) },
                onOpenSettings = { push(Screen.Settings) },
                onOpenGoldenHour = { push(Screen.GoldenHour) },
                onReview = { push(Screen.Editor(it, captureReview = true)) },
            )
            Screen.Library -> LibraryScreen(app, onClose = ::pop, onOpen = { push(Screen.Viewer(it)) })
            is Screen.Viewer -> PhotoViewerScreen(app, top.file, onClose = ::pop, onEdit = { push(Screen.Editor(it, captureReview = false)) })
            is Screen.Editor -> PhotoEditorScreen(app, top.file, top.captureReview, onClose = ::pop)
            Screen.Settings -> SettingsScreen(app, onClose = ::pop, onGoldenHour = { push(Screen.GoldenHour) })
            Screen.GoldenHour -> GoldenHourScreen(onClose = ::pop)
        }
        AnimatedVisibility(showSplash, exit = fadeOut(tween(350))) {
            LumiqSplash(onFinished = { showSplash = false })
        }
        if (!showSplash) UpdateDialog(app.updater)
    }
}
