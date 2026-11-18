package app.lumiq.explore

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Looper
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import app.lumiq.ui.FootNote
import app.lumiq.ui.Glyph
import app.lumiq.ui.Palette
import app.lumiq.ui.SheetHeader
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale

/** Offline golden-hour calculator, the same as the iPhone GoldenHourView. */
@Composable
fun GoldenHourScreen(onClose: () -> Unit) {
    val context = LocalContext.current
    var latitude by remember { mutableStateOf("") }
    var longitude by remember { mutableStateOf("") }
    var day by remember { mutableStateOf(LocalDate.now()) }
    var status by remember { mutableStateOf<String?>(null) }

    fun locate() {
        status = "Getting location…"
        requestLocation(context) { location ->
            if (location == null) status = "Location unavailable. Enter coordinates manually."
            else {
                latitude = String.format(Locale.US, "%.4f", location.latitude)
                longitude = String.format(Locale.US, "%.4f", location.longitude)
                status = null
            }
        }
    }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { ok ->
        if (ok) locate() else status = "Location access is denied. Enter coordinates manually or allow access in Android Settings."
    }

    val lat = latitude.replace(',', '.').toDoubleOrNull()?.takeIf { it in -90.0..90.0 }
    val lon = longitude.replace(',', '.').toDoubleOrNull()?.takeIf { it in -180.0..180.0 }
    val zone = ZoneId.systemDefault()
    val timeFormat = DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT)

    Column(Modifier.fillMaxSize().background(Palette.ink)) {
        SheetHeader("Golden hour", onClose, closeGlyph = Glyph.Back)
        Column(
            Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).navigationBarsPadding().padding(bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            TextButton({
                if (ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED) locate()
                else permission.launch(Manifest.permission.ACCESS_COARSE_LOCATION)
            }) { Text("Use my location", color = Palette.yellow) }
            status?.let { Text(it, color = Palette.muted, fontSize = 13.sp) }
            CoordinateField("Latitude (−90 to 90)", latitude) { latitude = it }
            CoordinateField("Longitude (−180 to 180)", longitude) { longitude = it }

            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = 8.dp)) {
                TextButton({ day = day.minusDays(1) }) { Text("‹", color = Palette.yellow, fontSize = 22.sp) }
                Text(
                    day.format(DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM)), color = Color.White, fontSize = 16.sp,
                    fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f),
                )
                TextButton({ day = day.plusDays(1) }) { Text("›", color = Palette.yellow, fontSize = 22.sp) }
            }
            Column(
                Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(Palette.panel).padding(15.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text("ESTIMATED GOLDEN LIGHT", color = Palette.muted, fontSize = 11.sp, letterSpacing = 2.sp)
                if (lat != null && lon != null) {
                    val windows = remember(lat, lon, day) { SolarCalculator.goldenWindows(day, lat, lon, zone) }
                    if (windows.isEmpty()) Text("No golden-light window on this day at these coordinates.", color = Color.White)
                    windows.forEach { (start, end) ->
                        Text(
                            "${start.atZone(zone).toLocalTime().format(timeFormat)} – ${end.atZone(zone).toLocalTime().format(timeFormat)}",
                            color = Color.White, fontSize = 18.sp,
                        )
                    }
                    if (day == LocalDate.now()) {
                        SolarCalculator.elevation(Instant.now(), lat, lon)?.let {
                            Text(String.format(Locale.getDefault(), "Current sun elevation: %.1f°", it), color = Palette.muted, fontSize = 13.sp)
                        }
                    }
                } else {
                    Text("Choose a location or enter valid coordinates.", color = Palette.muted)
                }
            }
            FootNote(
                "Approximate sun elevation between −4° and +6°. Times use your phone's timezone. Clouds, terrain and buildings affect usable light. " +
                    "This is an offline solar calculation, not a forecast. Location is used only here and is not added to photos or uploaded.",
            )
        }
    }
}

@Composable
private fun CoordinateField(label: String, value: String, onChange: (String) -> Unit) {
    OutlinedTextField(
        value = value, onValueChange = onChange, label = { Text(label) }, singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Text),
        colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = Palette.yellow, focusedLabelColor = Palette.yellow, cursorColor = Palette.yellow),
        modifier = Modifier.fillMaxWidth(),
    )
}

@SuppressLint("MissingPermission")
private fun requestLocation(context: Context, done: (Location?) -> Unit) {
    val manager = context.getSystemService(Context.LOCATION_SERVICE) as LocationManager
    val provider = listOf(LocationManager.NETWORK_PROVIDER, LocationManager.GPS_PROVIDER, LocationManager.PASSIVE_PROVIDER)
        .firstOrNull { runCatching { manager.isProviderEnabled(it) }.getOrDefault(false) }
    if (provider == null) { done(null); return }
    val last = runCatching { manager.getLastKnownLocation(provider) }.getOrNull()
    if (last != null && System.currentTimeMillis() - last.time < 6 * 3600_000L) { done(last); return }
    val listener = object : LocationListener {
        override fun onLocationChanged(location: Location) {
            manager.removeUpdates(this)
            done(location)
        }

        // Android 8–10 have no default implementations for these.
        override fun onProviderEnabled(provider: String) = Unit
        override fun onProviderDisabled(provider: String) = Unit
        @Deprecated("Required on older Android versions")
        override fun onStatusChanged(provider: String?, status: Int, extras: android.os.Bundle?) = Unit
    }
    runCatching {
        manager.requestLocationUpdates(provider, 0L, 0f, listener, Looper.getMainLooper())
    }.onFailure { done(last) }
}
