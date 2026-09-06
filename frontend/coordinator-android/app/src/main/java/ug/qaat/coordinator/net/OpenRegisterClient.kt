package ug.qaat.coordinator.net

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.location.LocationManager
import androidx.core.content.ContextCompat
import io.ktor.client.request.*
import io.ktor.client.statement.*
import io.ktor.http.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject

/**
 * OPENING A REGISTER: pin where the lecture is, get the code to read out.
 *
 * One call, because the location and the code are one act. A code with no location would let anyone
 * who overheard it mark themselves present from anywhere; a location with no code would admit every
 * phone that wandered past. The register is the pair.
 *
 * If no fix is available the register still opens, WITHOUT a location. That is deliberate: the
 * server then accepts on the code and the time window alone, which is weaker but recoverable —
 * whereas refusing to open would leave a full hall with no way to be recorded at all because the
 * lecturer's phone could not see a satellite. The weaker case is visible in the session row rather
 * than silent.
 */
class OpenRegisterClient(private val context: Context) {
    private val http = Net.client()
    private val base = Net.baseUrl

    data class Opened(val code: String, val closesAt: String?, val hasLocation: Boolean)

    suspend fun open(sessionId: String? = null, minutes: Int = 15): Opened? = withContext(Dispatchers.IO) {
        val sid = sessionId ?: ug.qaat.coordinator.ui.AppState.activeSessionId ?: return@withContext null
        val fix = lastKnown()
        val body = JSONObject().apply {
            if (fix != null) {
                put("latitude", fix.first)
                put("longitude", fix.second)
            }
            put("open_minutes", minutes)
        }
        val res = runCatching {
            http.post("$base/api/v1/sessions/$sid/open-geo") {
                header(HttpHeaders.Authorization, "Bearer ${ug.qaat.coordinator.ui.AppState.token.orEmpty()}")
                contentType(ContentType.Application.Json)
                setBody(body.toString())
            }
        }.getOrNull() ?: return@withContext null
        if (res.status.value !in 200..299) return@withContext null
        val j = runCatching { JSONObject(res.bodyAsText()) }.getOrNull() ?: return@withContext null
        Opened(
            code = j.optString("session_code"),
            closesAt = j.optString("closes_at").takeIf { it.isNotBlank() },
            hasLocation = j.optBoolean("has_location", false),
        )
    }

    /**
     * The last fix the OS already has, rather than requesting a fresh one.
     *
     * A fresh fix can take tens of seconds indoors and would leave the lecturer holding a spinner in
     * front of a waiting class. The last known position is accurate enough for a geofence measured
     * in hundreds of metres, and the accuracy the server records makes a stale one visible rather
     * than pretending it is exact.
     */
    @SuppressLint("MissingPermission")
    private fun lastKnown(): Pair<Double, Double>? {
        val granted = ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_COARSE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED
        if (!granted) return null
        val lm = context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager ?: return null
        for (p in listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)) {
            val l = runCatching { lm.getLastKnownLocation(p) }.getOrNull()
            if (l != null) return l.latitude to l.longitude
        }
        return null
    }
}
