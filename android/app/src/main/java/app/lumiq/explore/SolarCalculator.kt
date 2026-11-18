package app.lumiq.explore

import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZoneOffset
import kotlin.math.PI
import kotlin.math.acos
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

/** Direct port of the iPhone SolarCalculator (approximate NOAA solar geometry). */
object SolarCalculator {
    fun elevation(at: Instant, latitude: Double, longitude: Double): Double? {
        if (!latitude.isFinite() || !longitude.isFinite() || latitude !in -90.0..90.0 || longitude !in -180.0..180.0) return null
        val utc = at.atZone(ZoneOffset.UTC)
        val day = utc.dayOfYear
        val hours = utc.hour + utc.minute / 60.0 + utc.second / 3600.0
        val yearLength = utc.toLocalDate().lengthOfYear().toDouble()
        val gamma = 2 * PI / yearLength * (day - 1 + (hours - 12) / 24)
        val annualEquation = 0.001868 * cos(gamma) - 0.032077 * sin(gamma)
        val semiannualEquation = -0.014615 * cos(2 * gamma) - 0.040849 * sin(2 * gamma)
        val equation = 229.18 * (0.000075 + annualEquation + semiannualEquation)
        val annualDeclination = -0.399912 * cos(gamma) + 0.070257 * sin(gamma)
        val semiannualDeclination = -0.006758 * cos(2 * gamma) + 0.000907 * sin(2 * gamma)
        val thirdDeclination = -0.002697 * cos(3 * gamma) + 0.00148 * sin(3 * gamma)
        val declination = 0.006918 + annualDeclination + semiannualDeclination + thirdDeclination
        var minutes = (hours * 60 + equation + 4 * longitude) % 1440
        if (minutes < 0) minutes += 1440
        val hourAngle = (minutes / 4 - 180) * PI / 180
        val lat = latitude * PI / 180
        val cosZenith = max(-1.0, min(1.0, sin(lat) * sin(declination) + cos(lat) * cos(declination) * cos(hourAngle)))
        return 90 - acos(cosZenith) * 180 / PI
    }

    /** Golden light: sun elevation between −4° and +6°, scanned minute by minute in local time. */
    fun goldenWindows(day: LocalDate, latitude: Double, longitude: Double, zone: ZoneId = ZoneId.systemDefault()): List<Pair<Instant, Instant>> {
        val start = day.atStartOfDay(zone).toInstant()
        val end = day.plusDays(1).atStartOfDay(zone).toInstant()
        val intervals = ArrayList<Pair<Instant, Instant>>()
        var beginning: Instant? = null
        var time = start
        while (time.isBefore(end)) {
            val golden = elevation(time, latitude, longitude)?.let { it in -4.0..6.0 } ?: false
            if (golden && beginning == null) beginning = time
            val b = beginning
            if (!golden && b != null) { intervals.add(b to time); beginning = null }
            time = time.plusSeconds(60)
        }
        beginning?.let { intervals.add(it to end) }
        return intervals
    }
}
