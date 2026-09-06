package ug.qaat.coordinator.ui

import android.content.Intent
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import kotlinx.coroutines.launch
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import ug.qaat.coordinator.store.SessionStore

/**
 * Pick today's unit and open the register. The LECTURER is
 * identified AUTOMATICALLY from the chosen unit (the assignment carried in the manifest) —
 * the coordinator never types a staff ID. A manual field only appears as a fallback when a
 * unit has no assigned lecturer on file.
 */
@Composable
fun OpenSessionScreen(onOpened: () -> Unit) {
    val ctx = LocalContext.current
    // The manifest carries the FULL cohort unit list (so the Timetable stays populated). For the
    // ATTENDANCE picker, a coordinator may only start a unit that is actually TIMETABLED for today
    // (has a day + start time). Un-timetabled units are never startable here. No fall-back to
    // "all units". The unit is startable for the WHOLE day — it is no longer held back until
    // 10 minutes before its slot.
    val allUnits = AppState.manifest?.units.orEmpty()
    val todayDow = java.time.LocalDate.now().dayOfWeek.value   // 1=Mon … 7=Sun
    // val nowMin = java.time.LocalTime.now().let { it.hour * 60 + it.minute }
    fun startMinutes(hhmm: String): Int? {
        val p = hhmm.split(":"); val h = p.getOrNull(0)?.toIntOrNull(); val m = p.getOrNull(1)?.toIntOrNull()
        return if (h != null && m != null) h * 60 + m else null
    }
    // OFF-TIMETABLE LECTURES: a make-up class, a unit added after the schedule was locked, a
    // visiting lecturer covering a week. These used to be unstartable, and the cost fell on the
    // STUDENTS — no session means no room code, no check-in, and no attendance for a lecture they
    // sat through, in a system where attendance decides exam eligibility. They can be started now,
    // but only after a deliberate second step, so today's timetable stays the default answer.
    var offTimetable by remember { mutableStateOf(false) }
    val scheduledUnits = allUnits.filter { u ->
        val start = u.startTime.takeIf { it.isNotBlank() }?.let(::startMinutes)
        // The "slot is due" gate is COMMENTED OUT: a unit used to appear only from 10 minutes
        // before its timetabled start (`&& nowMin >= start - 10`). A coordinator may now open
        // any unit timetabled for today at any point in the day. Restore the clause — and the
        // `nowMin` line above — to bring the 10-minute rule back.
        u.dayOfWeek == todayDow && start != null
    }
    val units = if (offTimetable) allUnits else scheduledUnits
    // Kept on AppState so it travels with the session that is actually created, the same way the
    // provision room does — the choice and the creation are separated by the hotspot coming up.
    LaunchedEffect(offTimetable) { AppState.sessionUnscheduled = offTimetable }
    var selectedUnit by remember(units.size) { mutableStateOf(units.firstOrNull()?.unitId) }
    // THE ROOM, when the timetabled one cannot be used. Held here so it travels with the session
    // being opened rather than being a note somebody makes afterwards.
    var roomPicker by remember { mutableStateOf(false) }
    var provisionRoom by remember { mutableStateOf<ug.qaat.coordinator.net.FreeRoom?>(null) }
    var provisionReason by remember { mutableStateOf("") }

    if (roomPicker) {
        FreeRoomPicker(
            onDismiss = { roomPicker = false },
            onChosen = { r, why ->
                provisionRoom = r; provisionReason = why
                AppState.provisionVenueId = r.venueId
                AppState.provisionNote = why
            },
        )
    }
    var manualStaffId by remember { mutableStateOf("") }

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp)) {
        Text("Take attendance", style = MaterialTheme.typography.titleLarge)

        if (AppState.manifest == null) {
            Text("Today's schedule hasn't loaded yet. Tap the ⟳ at the top-right to refresh " +
                "(needs internet once — your session may have expired and is being renewed).",
                color = MaterialTheme.colorScheme.error)
            AppState.manifestError?.let { reason ->
                Spacer(Modifier.height(8.dp))
                Surface(color = MaterialTheme.colorScheme.errorContainer, shape = MaterialTheme.shapes.small,
                    modifier = Modifier.fillMaxWidth()) {
                    Text("Last refresh failed: $reason",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onErrorContainer,
                        modifier = Modifier.padding(10.dp))
                }
            }
            return
        }
        if (units.isEmpty() && !offTimetable) {
            Text("No unit is timetabled for today.",
                color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.height(8.dp))
            // The lecture is still happening, and refusing to start it does not stop it — it only
            // stops the STUDENTS being recorded, in a system where attendance decides who sits the
            // exam. So it can be started, deliberately, and it is marked as off-timetable.
            Text(
                "If a lecture is happening anyway — a make-up class, a unit added after the " +
                    "schedule was set — you can still take attendance for it. Students check in " +
                    "exactly as they always do; the record simply notes it was off-timetable.",
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.height(8.dp))
            OutlinedButton(onClick = { offTimetable = true }) {
                Text("Take attendance for an off-timetable lecture")
            }
            return
        }
        if (offTimetable) {
            Surface(
                color = MaterialTheme.colorScheme.secondaryContainer, shape = MaterialTheme.shapes.small,
                modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
            ) {
                Column(Modifier.padding(10.dp)) {
                    Text("Off-timetable lecture", fontWeight = FontWeight.SemiBold,
                        style = MaterialTheme.typography.bodyMedium)
                    Text("Every unit of your cohort is listed. Students check in normally; the " +
                        "attendance record will say this lecture was not on the timetable.",
                        style = MaterialTheme.typography.labelSmall)
                    TextButton(onClick = { offTimetable = false }) { Text("Back to today's timetable") }
                }
            }
        }

        Spacer(Modifier.height(12.dp))
        // Offered BEFORE the hotspot step, because deciding where the class is happening comes
        // before setting anything up in it.
        provisionRoom?.let { r ->
            Surface(
                color = MaterialTheme.colorScheme.secondaryContainer, shape = MaterialTheme.shapes.small,
                modifier = Modifier.fillMaxWidth().padding(bottom = 8.dp),
            ) {
                Column(Modifier.padding(10.dp)) {
                    Text("Running in ${r.name} (provision)", fontWeight = FontWeight.SemiBold,
                        style = MaterialTheme.typography.bodyMedium)
                    Text(
                        (if (provisionReason.isNotBlank()) "$provisionReason · " else "") +
                            "QA monitors have been told where to find this lecture.",
                        style = MaterialTheme.typography.labelSmall,
                    )
                    TextButton(onClick = {
                        provisionRoom = null; provisionReason = ""
                        AppState.provisionVenueId = ""; AppState.provisionNote = ""
                    }) { Text("Use the timetabled room instead") }
                }
            }
        }
        if (provisionRoom == null) {
            TextButton(onClick = { roomPicker = true }, modifier = Modifier.padding(bottom = 4.dp)) {
                Text("Timetabled room unavailable? Find a free one")
            }
        }

        Text("1. Start the room Wi-Fi + server", style = MaterialTheme.typography.titleSmall)

        // Two ways to bring up the room's Wi-Fi. Automatic (app-owned) needs no setup but gets an
        // OS-assigned random name; cohort-named uses the coordinator's OWN phone hotspot, which
        // they name after the cohort with a password they choose (essential in a shared room with
        // several coordinators). Persisted so the choice sticks.
        // THE HOTSPOT SETUP THAT USED TO BE HERE IS GONE.
        //
        // It asked the coordinator to name a Wi-Fi network, set a password, turn the radio on and
        // wait for a server to come up on their phone. None of that exists now: presence is proven
        // by the geofence and the spoken code, so the only thing left to do is open the register.
        Spacer(Modifier.height(8.dp))
        Text(
            "Opening pins the lecture to where you are standing and gives you a code to read to the "
                + "class. Students type the code; their phones must be nearby to be accepted.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(12.dp))
        val openScope = rememberCoroutineScope()
        var opening by remember { mutableStateOf(false) }
        Button(
            enabled = !opening && selectedUnit != null,
            modifier = Modifier.fillMaxWidth(),
            onClick = {
                opening = true
                openScope.launch {
                    val r = runCatching {
                        ug.qaat.coordinator.net.OpenRegisterClient(ctx).open()
                    }.getOrNull()
                    opening = false
                    if (r != null) {
                        AppState.activeSessionCode = r.code
                        onOpened()
                    }
                }
            },
        ) { Text(if (opening) "Opening…" else "Open register") }
    }
}
