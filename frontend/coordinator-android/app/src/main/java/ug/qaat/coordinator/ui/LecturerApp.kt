package ug.qaat.coordinator.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import kotlinx.coroutines.launch
import ug.qaat.coordinator.net.LecturerClient
import ug.qaat.coordinator.net.LecturerRecipientsClient
import ug.qaat.coordinator.net.LecturerTimetableClient
import ug.qaat.coordinator.net.OpenRegisterClient
import ug.qaat.coordinator.net.NotificationClient
import ug.qaat.coordinator.student.Fingerprint
import ug.qaat.coordinator.student.GateClient

/**
 * The LECTURER experience: join the coordinator's hotspot and START / END the session over the
 * LAN (no QR), see his roster & attendance across sessions/cohorts, read + send notifications.
 * Green KIU chrome + dark/light theme, like the coordinator app.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LecturerApp() {
    val navColor = navBarColor(AppState.branding)
    val onNav = navColor?.let { onNavColor(it) }
    var tab by remember { mutableStateOf(0) }
    var unread by remember { mutableStateOf(0) }
    var reloadKey by remember { mutableStateOf(0) }
    LaunchedEffect(tab, reloadKey) { runCatching { unread = NotificationClient().unread() } }
    var showChangePw by remember { mutableStateOf(false) }
    if (showChangePw) ChangePasswordDialog(onClose = { showChangePw = false })

    // Flush any presence claims filed offline, then re-cache the week they are matched against.
    //
    // Keyed on the REFRESH button and the session, not on `tab`: the claim a lecturer filed in a
    // basement lecture theatre has to go up the moment the phone finds signal again, whichever tab
    // they happen to be looking at. And the timetable has to already be on the phone BEFORE the
    // room with no signal — a cache fetched on demand is a cache that is empty exactly when it
    // matters. See PresenceSync.
    LaunchedEffect(AppState.loggedIn, reloadKey) {
        if (AppState.loggedIn) runCatching { ug.qaat.coordinator.sync.PresenceSync.refresh() }
    }

    Scaffold(
        containerColor = appBackgroundColor(AppState.branding) ?: MaterialTheme.colorScheme.background,
        topBar = {
            TopAppBar(
                colors = if (navColor != null) TopAppBarDefaults.topAppBarColors(
                    containerColor = navColor, titleContentColor = onNav!!, actionIconContentColor = onNav,
                ) else TopAppBarDefaults.topAppBarColors(),
                title = {
                    BrandHeader(AppState.branding)
                },
                actions = {
                    IconButton(onClick = { reloadKey++ }) {
                        BarIcon(NavIcons.Sync, "Refresh", onNav ?: MaterialTheme.colorScheme.primary)
                    }
                },
            )
        },
        bottomBar = {
            NavigationBar(containerColor = navColor ?: MaterialTheme.colorScheme.surface) {
                val itemColors = if (onNav != null) NavigationBarItemDefaults.colors(
                    selectedIconColor = onNav, selectedTextColor = onNav,
                    unselectedIconColor = onNav.copy(alpha = .65f), unselectedTextColor = onNav.copy(alpha = .65f),
                    indicatorColor = onNav.copy(alpha = .18f),
                ) else NavigationBarItemDefaults.colors()
                NavigationBarItem(tab == 0, { tab = 0 }, icon = { TabGlyph(NavIcons.Session, "Session") }, label = { Text("Session") }, colors = itemColors)
                NavigationBarItem(tab == 1, { tab = 1 }, icon = { TabGlyph(NavIcons.Calendar, "Timetable") }, label = { Text("Timetable") }, colors = itemColors)
                NavigationBarItem(tab == 2, { tab = 2 }, icon = { TabGlyph(NavIcons.Roster, "Roster") }, label = { Text("Roster") }, colors = itemColors)
                NavigationBarItem(tab == 3, { tab = 3 }, colors = itemColors, label = { Text("Alerts") },
                    icon = { if (unread > 0) BadgedBox(badge = { Badge { Text("$unread") } }) { TabGlyph(NavIcons.Alerts, "Alerts") } else TabGlyph(NavIcons.Alerts, "Alerts") })
                NavigationBarItem(tab == 4, { tab = 4 }, icon = { TabGlyph(NavIcons.Profile, "Profile") }, label = { Text("Profile") }, colors = itemColors)
            }
        },
    ) { pad ->
        Column(Modifier.padding(pad).fillMaxSize()) {
            Box(Modifier.weight(1f)) {
                when (tab) {
                    0 -> LecturerSessionTab()
                    1 -> LecturerScheduleTab()
                    2 -> LecturerRosterTab()
                    3 -> LecturerAlertsTab()
                    else -> LecturerProfileTab(onChangePw = { showChangePw = true })
                }
            }
        }
    }
}

@Composable
private fun LecturerHeader() {
    Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 10.dp)) {
        // Show the lecturer's academic title(s) with their name, e.g. "Dr. Jane Yuma".
        val name = AppState.coordinatorName?.takeIf { it.isNotBlank() }
        val title = AppState.coordinatorTitle?.takeIf { it.isNotBlank() }
        if (name != null) Text(listOfNotNull(title, name).joinToString(" "), fontWeight = FontWeight.Bold, fontSize = 17.sp)
        AppState.staffId?.let { Text("Staff ID: $it", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant) }
    }
}

/**
 * OPENING THE REGISTER, AND HANDING OUT THE CODE.
 *
 * The lecturer used to join the coordinator's hotspot and gate in against a server running on their
 * phone. There is no hotspot and no in-room server now: the lecturer opens the register through the
 * gateway, which pins where the lecture is and returns a short code to read across the room.
 *
 * The code and the geofence come back together because they are one act. A code without a location
 * would let anyone who overheard it mark themselves present from anywhere; a location without a
 * code would make every phone that wandered past eligible. Neither alone is a register.
 */
@Composable
private fun LecturerSessionTab() {
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    var sessionCode by remember { mutableStateOf<String?>(null) }
    var closesAt by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    var msg by remember { mutableStateOf<String?>(null) }
    var slots by remember { mutableStateOf<List<LecturerTimetableClient.Slot>>(emptyList()) }

    LaunchedEffect(Unit) {
        slots = runCatching { LecturerTimetableClient().week() }.getOrNull().orEmpty()
    }

    Column(Modifier.fillMaxSize().padding(16.dp)) {
        Text("Open the register", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(6.dp))
        Text(
            "Opening pins the lecture to where you are standing and gives you a code to read out. "
                + "Students type the code; their phones must be nearby to be accepted.",
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(16.dp))

        if (sessionCode == null) {
            Button(
                enabled = !busy,
                onClick = {
                    busy = true; msg = null
                    scope.launch {
                        val r = runCatching { OpenRegisterClient(ctx).open() }.getOrNull()
                        if (r == null) {
                            // Said plainly: opening needs the network, and the lecturer needs to know
                            // that is what failed rather than guessing at the room or the app.
                            msg = "Could not reach the server to open the register. Check your connection and try again."
                        } else {
                            sessionCode = r.code; closesAt = r.closesAt
                        }
                        busy = false
                    }
                },
                modifier = Modifier.fillMaxWidth(),
            ) { Text(if (busy) "Opening…" else "Open register") }
        } else {
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(20.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("Read this to the class", style = MaterialTheme.typography.labelMedium)
                    Spacer(Modifier.height(8.dp))
                    // Large and spaced: this number is read aloud across a lecture hall.
                    Text(
                        sessionCode!!.toCharArray().joinToString("  "),
                        style = MaterialTheme.typography.displaySmall, fontWeight = FontWeight.Bold,
                    )
                    closesAt?.let {
                        Spacer(Modifier.height(8.dp))
                        Text("Closes at $it", style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        }

        msg?.let {
            Spacer(Modifier.height(12.dp))
            Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
        }

        if (slots.isNotEmpty()) {
            Spacer(Modifier.height(20.dp))
            Text("Your week", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(6.dp))
            slots.take(6).forEach { s ->
                Text("• ${s.unitName} — ${s.room}", style = MaterialTheme.typography.bodySmall)
            }
        }
    }
}

/** Roster & attendance analytics: filter by unit, toggle enrolled vs attended-only, sort, and
 *  drill into any session to see who was present or absent. Consumes the lecturer endpoints. */
@Composable
private fun LecturerRosterTab() {
    val scope = rememberCoroutineScope()
    var units by remember { mutableStateOf<List<LecturerClient.Unit>>(emptyList()) }
    var unitFilter by remember { mutableStateOf<String?>(null) }
    var attendedOnly by remember { mutableStateOf(false) }
    var sortBy by remember { mutableStateOf("name") }   // name | cohort | unit | attended
    var rows by remember { mutableStateOf<List<LecturerClient.RosterRow>?>(null) }
    var sessions by remember { mutableStateOf<List<LecturerClient.Session>>(emptyList()) }
    var openSession by remember { mutableStateOf<LecturerClient.Session?>(null) }
    // Daily shift: default to TODAY's sessions only (the whole day's records are kept server-side,
    // but the roster shows today's shift and rolls over each day). Toggle off to see history.
    var todayOnly by remember { mutableStateOf(true) }

    fun reload() {
        rows = null
        scope.launch {
            val c = LecturerClient()
            if (units.isEmpty()) units = c.units()
            rows = c.roster(if (attendedOnly) "attended" else "enrolled", unitFilter)
            sessions = c.sessions(unitFilter)
        }
    }
    LaunchedEffect(unitFilter, attendedOnly) { reload() }

    if (openSession != null) SessionAttendanceDialog(openSession!!) { openSession = null }

    Column(Modifier.fillMaxSize().padding(horizontal = 16.dp)) {
        // Unit filter (if he handles more than one).
        if (units.size > 1) {
            LazyRowChips(
                labelFor = { it?.name ?: "All units" },
                options = listOf<LecturerClient.Unit?>(null) + units,
                selected = unitFilter,
                idOf = { it?.unitId },
                onSelect = { unitFilter = it?.unitId },
            )
        }
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(vertical = 4.dp)) {
            FilterChip(selected = !attendedOnly, onClick = { attendedOnly = false }, label = { Text("All who study") })
            Spacer(Modifier.width(8.dp))
            FilterChip(selected = attendedOnly, onClick = { attendedOnly = true }, label = { Text("Attended only") })
        }
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(bottom = 4.dp)) {
            Text("Sort:", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            listOf("name" to "Name", "cohort" to "Cohort", "unit" to "Unit", "attended" to "Attended").forEach { (k, lbl) ->
                TextButton(onClick = { sortBy = k }, contentPadding = PaddingValues(horizontal = 8.dp)) {
                    Text(lbl, fontWeight = if (sortBy == k) FontWeight.Bold else FontWeight.Normal,
                        color = if (sortBy == k) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }

        val sorted = (rows ?: emptyList()).sortedWith(compareBy {
            when (sortBy) { "cohort" -> it.cohort; "unit" -> it.unitName; "attended" -> "%05d".format(9999 - it.attendedCount); else -> it.fullName }
        })
        when {
            rows == null -> Box(Modifier.fillMaxWidth().padding(top = 40.dp), Alignment.Center) { CircularProgressIndicator() }
            sorted.isEmpty() -> Text("No students to show.", color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(top = 12.dp))
            else -> LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                item { Text("${sorted.size} student rows", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                items(sorted) { r ->
                    Surface(color = MaterialTheme.colorScheme.surfaceVariant, shape = MaterialTheme.shapes.small) {
                        Column(Modifier.fillMaxWidth().padding(10.dp)) {
                            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                                Text(r.fullName, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                                Text("${r.attendedCount}×", fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.primary)
                            }
                            Text("${r.studentId} · ${r.unitName}", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            if (r.cohort.isNotBlank()) Text(r.cohort, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                }
                val today = java.time.LocalDate.now().toString()
                val shownSessions = sessions
                    .filter { !todayOnly || it.date == today }
                    .sortedWith(compareBy({ it.unitName }, { it.date }))   // grouped by unit, never mixed
                item {
                    Spacer(Modifier.height(10.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("Sessions", fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
                        FilterChip(todayOnly, { todayOnly = true }, { Text("Today") }, modifier = Modifier.padding(end = 6.dp))
                        FilterChip(!todayOnly, { todayOnly = false }, { Text("All days") })
                    }
                    if (unitFilter == null && units.size > 1)
                        Text("Tip: pick a unit above to see just that unit's sessions.",
                            style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                if (shownSessions.isEmpty()) item { Text(if (todayOnly) "No sessions today yet." else "No sessions.", color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(top = 6.dp)) }
                if (shownSessions.isNotEmpty()) {
                    items(shownSessions) { s ->
                        Surface(color = MaterialTheme.colorScheme.surfaceVariant, shape = MaterialTheme.shapes.small, onClick = { openSession = s }) {
                            Row(Modifier.fillMaxWidth().padding(10.dp), verticalAlignment = Alignment.CenterVertically) {
                                Column(Modifier.weight(1f)) {
                                    Text("${s.unitName} · ${s.date}", fontWeight = FontWeight.SemiBold)
                                    if (s.cohort.isNotBlank()) Text(s.cohort, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                }
                                Text("${s.present}/${s.enrolled}", fontWeight = FontWeight.Bold)
                            }
                        }
                    }
                }
            }
        }
    }
}

/** Full-screen, Excel-style roster for ONE session: three columns (Reg no · Student name · Status),
 *  a green ✓ for present and a red ✗ for absent, present/absent/all filtering, and PDF/CSV export.
 *  It always loads the FULL list (so present + absent are both shown and exportable); the chips only
 *  change what's displayed. */
@Composable
private fun SessionAttendanceDialog(session: LecturerClient.Session, onClose: () -> Unit) {
    var view by remember { mutableStateOf("all") }   // present | absent | all (display filter)
    var all by remember { mutableStateOf<List<LecturerClient.SessStudent>?>(null) }
    LaunchedEffect(session.sessionId) { all = LecturerClient().sessionStudents(session.sessionId, "all") }

    Dialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxSize()) {
            Column(Modifier.fillMaxSize().padding(16.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(session.unitName.ifBlank { session.unitId }, fontWeight = FontWeight.Bold)
                        Text(listOf(session.cohort, session.date).filter { it.isNotBlank() }.joinToString(" · "),
                            style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    ExportRosterButton(
                        baseName = "roster_${session.unitName.ifBlank { session.unitId }}_${session.date}".replace(Regex("[^A-Za-z0-9_-]"), "_"),
                        title = "${session.unitName.ifBlank { session.unitId }} — ${session.date}",
                    ) { (all ?: emptyList()).map { RosterLine(it.studentId, it.fullName, it.present) } }
                    TextButton(onClick = onClose) { Text("Close") }
                }
                Spacer(Modifier.height(4.dp))
                Row {
                    listOf("all" to "All", "present" to "Present", "absent" to "Absent").forEach { (k, lbl) ->
                        FilterChip(view == k, { view = k }, { Text(lbl) }, modifier = Modifier.padding(end = 6.dp))
                    }
                }
                val rows = (all ?: emptyList()).filter { when (view) { "present" -> it.present; "absent" -> !it.present; else -> true } }
                    .sortedWith(compareBy({ !it.present }, { it.fullName }))
                Text("${(all ?: emptyList()).count { it.present }} present · ${(all ?: emptyList()).count { !it.present }} absent",
                    style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(vertical = 6.dp))
                // Header row (the three Excel columns).
                Row(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
                    Text("Reg no", Modifier.weight(1.1f), fontSize = 11.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text("Student name", Modifier.weight(1.5f), fontSize = 11.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text("Status", Modifier.weight(0.5f), fontSize = 11.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
                }
                HorizontalDivider()
                when {
                    all == null -> Box(Modifier.fillMaxWidth().padding(top = 40.dp), Alignment.Center) { CircularProgressIndicator() }
                    rows.isEmpty() -> Text("No students.", color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(top = 12.dp))
                    else -> LazyColumn(Modifier.weight(1f)) {
                        items(rows) { s ->
                            Row(Modifier.fillMaxWidth().padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                                Text(s.studentId, Modifier.weight(1.1f), fontSize = 12.sp, fontFamily = FontFamily.Monospace)
                                Text(s.fullName, Modifier.weight(1.5f), fontSize = 13.sp)
                                Box(Modifier.weight(0.5f), contentAlignment = Alignment.Center) {
                                    if (s.present) Text("✓", color = MaterialTheme.colorScheme.primary, fontWeight = FontWeight.Bold, fontSize = 18.sp)
                                    else Text("✗", color = MaterialTheme.colorScheme.error, fontWeight = FontWeight.Bold, fontSize = 18.sp)
                                }
                            }
                            HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.4f))
                        }
                    }
                }
            }
        }
    }
}

/** Inbox from the coordinator, and a composer to notify his students or the coordinator. */
@Composable
private fun LecturerAlertsTab() {
    val scope = rememberCoroutineScope()
    var inbox by remember { mutableStateOf<List<NotificationClient.Notif>?>(null) }
    var composing by remember { mutableStateOf(false) }
    // Held across opens of the composer so a lecturer who closes and reopens it does not pay for
    // the fetch twice on a connection that may barely have managed it once.
    var recipients by remember { mutableStateOf<LecturerRecipientsClient.Recipients?>(null) }
    fun load() { scope.launch { inbox = NotificationClient().inbox() } }
    LaunchedEffect(Unit) { load() }

    Column(Modifier.fillMaxSize().padding(16.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text("Notifications", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
            Button(onClick = { composing = !composing }) { Text(if (composing) "Close" else "✎ New") }
        }
        LaunchedEffect(composing) {
            if (composing && recipients == null) {
                recipients = runCatching { LecturerRecipientsClient().load() }.getOrNull()
            }
        }
        if (composing) NotificationComposer(
            // STUDENT MODULE: DEFERRED TO V2 — "STUDENTS" to "My students" was the first entry.
            audiences = listOf("COORDINATOR" to "Coordinators"),

            onSent = { composing = false; load() },
            // The named people behind those two audiences. Fetched when the composer opens rather
            // than on tab load: a lecturer opens this tab to READ their alerts far more often than
            // to write one, and their whole roster is not a small list.
            recipients = recipients,
        )
        Spacer(Modifier.height(8.dp))
        // ABOVE the inbox, deliberately. A lecturer opens this tab because they were told they
        // were recorded as NOT TAUGHT; the way to answer that has to be the thing they see, not
        // something they scroll past a week of alerts to find.
        PresenceClaimCard()
        Spacer(Modifier.height(12.dp))
        NotificationInboxList(inbox) { load() }
    }
}

@Composable
private fun LecturerProfileTab(onChangePw: () -> Unit) {
    Column(Modifier.fillMaxSize().padding(24.dp)) {
        Text("Profile", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(12.dp))
        val titled = listOfNotNull(
            AppState.coordinatorTitle?.takeIf { it.isNotBlank() },
            AppState.coordinatorName?.takeIf { it.isNotBlank() },
        ).joinToString(" ")
        if (titled.isNotBlank()) Text(titled, fontWeight = FontWeight.SemiBold)
        AppState.staffId?.let { Text("Staff ID: $it", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant) }
        AppState.role?.let { Text(it, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
        Spacer(Modifier.height(24.dp))
        OutlinedButton(onClick = onChangePw, Modifier.fillMaxWidth()) { Text("🔑  Change password") }
        Spacer(Modifier.height(8.dp))
        SignOutButton()
    }
}
