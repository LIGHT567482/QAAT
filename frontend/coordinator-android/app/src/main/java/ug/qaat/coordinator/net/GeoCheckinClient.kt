package ug.qaat.coordinator.net

import android.content.Context
import io.ktor.client.request.*
import io.ktor.client.statement.*
import io.ktor.http.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import ug.qaat.coordinator.student.AttendanceQueue
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * CHECKING IN AGAINST THE GATEWAY, WITH A QUEUE BEHIND IT.
 *
 * This replaces the in-room server the coordinator's phone used to run. Presence is now proven by
 * a session code the lecturer reads out and the phone's own coordinates, checked against the
 * geofence the register was opened with.
 *
 * THE ORDER OF OPERATIONS IS THE WHOLE DESIGN, so it is worth being explicit:
 *
 *   1. The tap is written to the local queue FIRST, before any network call. A student taps once
 *      and walks away; if the queue were only written after a failure, a process death mid-request
 *      would lose the tap and mark a present student absent.
 *   2. Connectivity is probed, then the check-in attempted.
 *   3. The queued item is removed only when the server has accounted for it.
 *
 * That ordering means the worst outcome of any crash, timeout or dead zone is a check-in that
 * arrives late — never one that disappears. It also means every send is a retry of something
 * already recorded, which is safe because each item carries an id the server dedupes on.
 */
class GeoCheckinClient(context: Context) {
    private val http = Net.client()
    private val base = Net.baseUrl
    private val queue = AttendanceQueue(context)

    data class Result(
        val status: String,      // PRESENT | ALREADY_PRESENT | QUEUED | REJECTED
        val message: String,
        val distanceMeters: Int? = null,
        val queued: Boolean = false,
    )

    /** Can we reach the gateway at all? Deliberately separate from "am I signed in": a 401 means
     *  the session expired and must NOT cause the app to queue, because queueing would hide a
     *  problem the student can actually fix by signing in again. */
    suspend fun online(): Boolean = withContext(Dispatchers.IO) {
        runCatching {
            http.get("$base/api/v1/attendance/ping").status.value in 200..299
        }.getOrDefault(false)
    }

    /**
     * Record attendance. Always durable: the tap is queued before anything is attempted.
     */
    suspend fun checkIn(
        sessionCode: String, studentId: String,
        latitude: Double?, longitude: Double?, deviceId: String,
    ): Result = withContext(Dispatchers.IO) {
        val capturedAt = iso(Date())
        val qid = queue.enqueue(sessionCode, studentId, latitude, longitude, deviceId, capturedAt)

        if (!online()) {
            return@withContext Result(
                "QUEUED",
                "No connection. Your check-in is saved on this phone and will be sent automatically.",
                queued = true,
            )
        }

        val body = JSONObject().apply {
            put("session_code", sessionCode)
            put("student_id", studentId)
            if (latitude != null) put("latitude", latitude)
            if (longitude != null) put("longitude", longitude)
            put("device_id", deviceId)
        }
        val res = runCatching {
            http.post("$base/api/v1/attendance/geo-checkin") {
                contentType(ContentType.Application.Json)
                setBody(body.toString())
            }
        }.getOrNull() ?: return@withContext Result(
            "QUEUED",
            "Could not reach the server. Your check-in is saved and will be sent automatically.",
            queued = true,
        )

        val text = runCatching { res.bodyAsText() }.getOrDefault("")
        val json = runCatching { JSONObject(text) }.getOrNull()
        val dist = json?.optInt("distance_meters", -1)?.takeIf { it >= 0 }

        // Anything the server has ACCOUNTED FOR leaves the queue — including a rejection. A refused
        // check-in will be refused identically forever, and a queue that never drains blocks every
        // later check-in behind it. The refusal is not lost: the server records every attempt with
        // its reason, so the student's failed try is on the record even though the phone stops.
        if (res.status.value in 200..299) {
            queue.settle(listOf(qid))
            val status = json?.optString("status").orEmpty().ifBlank { "PRESENT" }
            return@withContext Result(status, json?.optString("message").orEmpty(), dist)
        }
        if (res.status.value in 400..499) {
            queue.settle(listOf(qid))
            return@withContext Result(
                "REJECTED",
                json?.optString("message").orEmpty().ifBlank { "That check-in was not accepted." },
                dist,
            )
        }
        // 5xx: the server is there but broken. Keep it queued — this one CAN succeed later.
        Result("QUEUED", "The server had a problem. Your check-in is saved and will be retried.", dist, queued = true)
    }

    /** Push whatever is waiting. Safe to call often; does nothing when the queue is empty. */
    suspend fun flush(): Int = withContext(Dispatchers.IO) {
        val items = queue.pending()
        if (items.isEmpty()) return@withContext 0
        if (!online()) return@withContext 0

        val arr = JSONArray()
        items.forEach { it ->
            arr.put(JSONObject().apply {
                put("queue_id", it.queueId)
                put("session_code", it.sessionCode)
                put("student_id", it.studentId)
                if (it.latitude != null) put("latitude", it.latitude)
                if (it.longitude != null) put("longitude", it.longitude)
                put("device_id", it.deviceId)
                put("captured_at", it.capturedAt)
            })
        }
        val res = runCatching {
            http.post("$base/api/v1/attendance/offline-batch") {
                contentType(ContentType.Application.Json)
                setBody(JSONObject().put("items", arr).toString())
            }
        }.getOrNull() ?: return@withContext 0
        if (res.status.value !in 200..299) return@withContext 0

        val text = runCatching { res.bodyAsText() }.getOrDefault("")
        val results = runCatching { JSONObject(text).optJSONArray("results") }.getOrNull()
            ?: return@withContext 0

        // Every item the server answered for is settled, whatever the answer — see the note above.
        val settled = ArrayList<String>(results.length())
        var stored = 0
        for (i in 0 until results.length()) {
            val o = results.optJSONObject(i) ?: continue
            settled.add(o.optString("queue_id"))
            if (o.optString("status") == "STORED") stored++
        }
        queue.settle(settled)
        stored
    }

    fun pendingCount(): Int = queue.size()

    private fun iso(d: Date): String =
        SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US)
            .apply { timeZone = TimeZone.getTimeZone("UTC") }.format(d)
}
