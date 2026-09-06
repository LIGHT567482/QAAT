package ug.qaat.coordinator.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import ug.qaat.coordinator.net.AuthClient
import ug.qaat.coordinator.net.NotificationClient
import ug.qaat.coordinator.net.StudentHomeClient
import ug.qaat.coordinator.store.SessionStore
import ug.qaat.coordinator.student.OnlineCheckinClient
import android.Manifest
import android.annotation.SuppressLint
import android.content.pm.PackageManager
import android.location.LocationManager
import androidx.core.content.ContextCompat
import androidx.compose.ui.text.font.FontFamily
import ug.qaat.coordinator.net.GeoCheckinClient
import ug.qaat.coordinator.student.Fingerprint
import ug.qaat.coordinator.student.ProgressClient
import ug.qaat.coordinator.student.RegisterDeviceClient

private val REASONS = mapOf(
    "NOT_ON_ROSTER" to "You're not on this class's roster.",
    "DUPLICATE_SCAN" to "You're already marked present.",
    "DEVICE_ALREADY_USED" to "This phone already checked in another student for this lecture.",
    "DEVICE_MISMATCH" to "This isn't the device you first checked in with.",
    "DEVICE_BELONGS_TO_ANOTHER_STUDENT" to "This phone is registered to another student.",
    "SESSION_NOT_ACTIVE" to "No active session yet — wait for your coordinator to start.",
    "LECTURER_NOT_STARTED" to "Waiting for the lecturer to start the session.",
    // Only ~10 phones fit on the class Wi-Fi at once, so a turn that goes nowhere is given up
    // rather than held. Phrased as the queue it is, not as a failure the student caused.
    "EVICT_EXPIRED" to "Your turn on the class Wi-Fi ended. Reconnecting shortly…",
)

/** How long to wait before taking another turn after being moved on without attending.
 *  RANDOMISED, and that is the point: two hundred phones evicted within the same second would
 *  otherwise all come back in the same second, and the hall would thrash instead of drain. */
private val REJOIN_BACKOFF_MS: Long get() = 20_000L + (Math.random() * 20_000L).toLong()

/** The STUDENT experience inside the unified app: one-tap Attend + online My-attendance + Profile.
 *  Identity (reg-number, institution) comes from the login token via AppState. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun StudentRoleApp() {
    val ctx = LocalContext.current
    // Bind this phone to the student (one-device-one-student) once after login; capture any cooldown.
    LaunchedEffect(AppState.studentId) {
        val reg = AppState.studentId
        if (!reg.isNullOrBlank()) {
            runCatching { RegisterDeviceClient().register(reg, Fingerprint.get(ctx)) }
                .onSuccess { AppState.attendBlockUntil = it.attendBlockUntilMs; SessionStore.saveAttendBlockUntil(it.attendBlockUntilMs) }
        }
        if (AppState.attendBlockUntil == 0L) AppState.attendBlockUntil = SessionStore.attendBlockUntil()
    }

    val navColor = navBarColor(AppState.branding)
    val onNav = navColor?.let { onNavColor(it) }
    var tab by remember { mutableStateOf(0) }
    var showPortal by remember { mutableStateOf(false) }
    // Bumped by the top-bar refresh; every page keys its fetch on it and reloads.
    var reloadKey by remember { mutableStateOf(0) }

    // The KIU student portal takes over the whole screen (with its own back button) when opened.
    if (showPortal) {
        StudentPortalScreen(regNo = AppState.studentId, onClose = { showPortal = false })
        return
    }
    var unread by remember { mutableStateOf(0) }
    // Refresh the unread badge whenever the tab changes (so it clears after reading the inbox).
    LaunchedEffect(tab, reloadKey) { runCatching { unread = NotificationClient().unread() } }

    Scaffold(
        containerColor = (if (!AppState.darkTheme) appBackgroundColor(AppState.branding) else null)
            ?: MaterialTheme.colorScheme.background,
        topBar = {
            TopAppBar(
                colors = if (navColor != null) TopAppBarDefaults.topAppBarColors(
                    containerColor = navColor, titleContentColor = onNav!!, actionIconContentColor = onNav,
                ) else TopAppBarDefaults.topAppBarColors(),
                title = { BrandHeader(AppState.branding) },
                actions = {
                    // Refresh + light/dark toggle, matching the coordinator app's top bar.
                    IconButton(onClick = { reloadKey++ }) {
                        BarIcon(NavIcons.Sync, "Refresh", onNav ?: MaterialTheme.colorScheme.primary)
                    }
                    IconButton(onClick = { AppState.darkTheme = !AppState.darkTheme; SessionStore.saveTheme(AppState.darkTheme) }) {
                        BarIcon(if (AppState.darkTheme) NavIcons.LightMode else NavIcons.DarkMode,
                            if (AppState.darkTheme) "Switch to light theme" else "Switch to dark theme",
                            onNav ?: MaterialTheme.colorScheme.primary)
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
                NavigationBarItem(tab == 0, { tab = 0 }, icon = { TabGlyph(NavIcons.Home, "Home") }, label = { Text("Home") }, colors = itemColors)
                NavigationBarItem(tab == 1, { tab = 1 }, icon = { TabGlyph(NavIcons.Attend, "Attend") }, label = { Text("Attend") }, colors = itemColors)
                NavigationBarItem(tab == 2, { tab = 2 }, icon = { TabGlyph(NavIcons.Attendance, "Attendance") }, label = { Text("Attendance") }, colors = itemColors)
                NavigationBarItem(tab == 3, { tab = 3 }, colors = itemColors, label = { Text("Alerts") },
                    icon = { if (unread > 0) BadgedBox(badge = { Badge { Text("$unread") } }) { TabGlyph(NavIcons.Alerts, "Alerts") } else TabGlyph(NavIcons.Alerts, "Alerts") })
                NavigationBarItem(tab == 4, { tab = 4 }, icon = { TabGlyph(NavIcons.Profile, "Profile") }, label = { Text("Profile") }, colors = itemColors)
            }
        },
    ) { pad ->
        Column(Modifier.padding(pad).fillMaxSize()) {
            Box(Modifier.weight(1f)) {
                when (tab) {
                    0 -> StudentHome(reloadKey)
                    1 -> StudentAttend()
                    2 -> StudentProgress(reloadKey)
                    3 -> StudentNotifications(reloadKey, onRead = { runCatching { } })
                    else -> StudentProfile(reloadKey, onOpenPortal = { showPortal = true })
                }
            }
        }
    }
}

/** The student's notification inbox — messages from their lecturers and coordinator. Tapping a
 *  message marks it read. Fully cloud-backed (fetched when the phone is online). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun StudentNotifications(reloadKey: Int, onRead: () -> Unit) {
    val scope = rememberCoroutineScope()
    var items by remember { mutableStateOf<List<NotificationClient.Notif>?>(null) }
    fun load() { scope.launch { items = NotificationClient().inbox() } }
    LaunchedEffect(reloadKey) { load() }

    Column(Modifier.fillMaxSize().padding(16.dp)) {
        Text("Notifications", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(8.dp))
        // The shared list, not a private copy of it. The copy that lived here dropped the card on
        // its own authority and never checked whether the server accepted the dismissal, so a
        // refused ✕ came back with no explanation.
        NotificationInboxList(items) { load(); onRead() }
    }
}
@Composable
private fun StudentAttend() {
    // ── STUDENT ATTENDANCE TAKING: SUSPENDED ────────────────────────────────────
    //
    // The whole check-in flow — code entry, location fix, queue write — is preserved verbatim in
    // the comment block below rather than deleted. A student who opens this tab is TOLD it is off,
    // which is the only honest option: leaving the form live would take taps that go nowhere and
    // quietly build a queue of check-ins the server now refuses, while hiding the tab would look
    // like the app was broken.
    //
    // Nothing here touches the lecturer's own attendance or the QA monitor round. Restore by
    // swapping this Column for the block below and uncommenting the matching routes in
    // backend/api-gateway/internal/router/router.go.
    Column(
        Modifier.fillMaxSize().padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text("Attendance is suspended", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(10.dp))
        Text(
            "Taking student attendance is turned off at the moment. You do not need to do anything, "
                + "and nothing already recorded has been lost — your attendance history is still on "
                + "the My attendance tab.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
    }
}

/* ── SUSPENDED: the student check-in flow, kept verbatim for restore ─────────────
   private fun StudentAttend() {
       val ctx = LocalContext.current
       val scope = rememberCoroutineScope()
       val client = remember { GeoCheckinClient(ctx) }
   
       var code by remember { mutableStateOf("") }
       var busy by remember { mutableStateOf(false) }
       var status by remember { mutableStateOf<String?>(null) }
       var success by remember { mutableStateOf(false) }
       var queuedCount by remember { mutableStateOf(client.pendingCount()) }
       var latestNotif by remember { mutableStateOf<NotificationClient.Notif?>(null) }
   
       LaunchedEffect(success) { if (success) runCatching { latestNotif = NotificationClient().inbox().firstOrNull() } }
   
       // Anything stranded from a lecture with no signal is pushed the moment this screen opens, so a
       // student who walks back into coverage does not have to know the queue exists.
       LaunchedEffect(Unit) {
           runCatching { client.flush() }
           queuedCount = client.pendingCount()
       }
   
       Column(
           Modifier.fillMaxSize().padding(20.dp),
           horizontalAlignment = Alignment.CenterHorizontally,
       ) {
           Text("Attend", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
           Spacer(Modifier.height(6.dp))
           Text(
               "Type the code your lecturer read out. Your phone must be at the lecture for it to count.",
               style = MaterialTheme.typography.bodySmall,
               color = MaterialTheme.colorScheme.onSurfaceVariant,
               textAlign = TextAlign.Center,
           )
           Spacer(Modifier.height(20.dp))
   
           OutlinedTextField(
               value = code,
               onValueChange = { v -> if (v.length <= 6) code = v.uppercase() },
               label = { Text("Lecture code") },
               singleLine = true,
               textStyle = LocalTextStyle.current.copy(
                   fontFamily = FontFamily.Monospace, fontSize = 24.sp, textAlign = TextAlign.Center,
               ),
               modifier = Modifier.fillMaxWidth(),
           )
           Spacer(Modifier.height(16.dp))
   
           Button(
               enabled = !busy && code.isNotBlank() && !success,
               modifier = Modifier.fillMaxWidth(),
               onClick = {
                   busy = true; status = null
                   scope.launch {
                       val fix = lastKnownFix(ctx)
                       val r = client.checkIn(
                           sessionCode = code,
                           studentId = AppState.studentId.orEmpty(),
                           latitude = fix?.first,
                           longitude = fix?.second,
                           deviceId = ug.qaat.coordinator.student.Fingerprint.get(ctx),
                       )
                       busy = false
                       status = r.message
                       // QUEUED counts as done from the student's side. They tapped, it is saved, and
                       // nothing more is asked of them — telling them to try again would invite a
                       // second tap that can only ever become a duplicate.
                       success = r.status == "PRESENT" || r.status == "ALREADY_PRESENT" || r.queued
                       queuedCount = client.pendingCount()
                   }
               },
           ) { Text(if (busy) "Checking in…" else "Mark me present") }
   
           status?.let {
               Spacer(Modifier.height(14.dp))
               Text(
                   it,
                   color = if (success) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.error,
                   textAlign = TextAlign.Center,
               )
           }
   
           if (queuedCount > 0) {
               Spacer(Modifier.height(14.dp))
               Text(
                   "$queuedCount check-in(s) saved on this phone, waiting for a connection. "
                       + "They will be sent automatically — you do not need to do anything.",
                   style = MaterialTheme.typography.bodySmall,
                   color = MaterialTheme.colorScheme.onSurfaceVariant,
                   textAlign = TextAlign.Center,
               )
           }
   
           latestNotif?.let { n ->
               Spacer(Modifier.height(20.dp))
               Card(Modifier.fillMaxWidth()) {
                   Column(Modifier.padding(14.dp)) {
                       Text(n.subject, fontWeight = FontWeight.Bold)
                       Spacer(Modifier.height(4.dp))
                       Text(n.body, style = MaterialTheme.typography.bodySmall)
                   }
               }
           }
       }
   }
*/


/**
 * The position the OS already has, not a fresh fix.
 *
 * Waiting for a new fix indoors can take tens of seconds, and a student standing in a lecture with
 * a spinner will tap again — producing exactly the duplicate the queue then has to reconcile. The
 * last known position is well inside the tolerance of a geofence measured in hundreds of metres.
 * Null when there is no permission or no fix at all, which the server reads as "no location" and
 * answers honestly rather than guessing.
 */
@SuppressLint("MissingPermission")
private fun lastKnownFix(ctx: android.content.Context): Pair<Double, Double>? {
    val granted = ContextCompat.checkSelfPermission(ctx, Manifest.permission.ACCESS_FINE_LOCATION) ==
        PackageManager.PERMISSION_GRANTED ||
        ContextCompat.checkSelfPermission(ctx, Manifest.permission.ACCESS_COARSE_LOCATION) ==
        PackageManager.PERMISSION_GRANTED
    if (!granted) return null
    val lm = ctx.getSystemService(android.content.Context.LOCATION_SERVICE) as? LocationManager ?: return null
    for (prov in listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)) {
        val l = runCatching { lm.getLastKnownLocation(prov) }.getOrNull()
        if (l != null) return l.latitude to l.longitude
    }
    return null
}

@Composable
private fun StudentProgress(reloadKey: Int) {
    val scope = rememberCoroutineScope()
    var data by remember { mutableStateOf<ProgressClient.Progress?>(null) }
    var loading by remember { mutableStateOf(true) }
    var error by remember { mutableStateOf<String?>(null) }

    fun load() {
        loading = true; error = null
        scope.launch {
            val reg = AppState.studentId
            if (reg.isNullOrBlank()) { error = "Sign in again to view your progress."; loading = false; return@launch }
            runCatching { ProgressClient().fetch(reg) }
                .onSuccess { data = it; loading = false }
                .onFailure { error = it.message ?: "Couldn't load progress"; loading = false }
        }
    }
    LaunchedEffect(reloadKey) { load() }

    Column(Modifier.fillMaxSize().padding(20.dp)) {
        Text("My attendance", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
        data?.let { Text(it.fullName, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant) }
        data?.let { p ->
            val org = listOf(p.school, p.department).filter { it.isNotBlank() }.joinToString(" · ")
            if (org.isNotBlank()) Text(org, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Spacer(Modifier.height(12.dp))
        // Same reason as the monitor round: the LazyColumn body is invoked after this
        // composition returns, so it must close over a value, not over the state holder.
        val units = data?.units
        when {
            loading -> Box(Modifier.fillMaxWidth().padding(top = 40.dp), Alignment.Center) { CircularProgressIndicator() }
            error != null -> Text(error.orEmpty(), color = MaterialTheme.colorScheme.error)
            units.isNullOrEmpty() -> Text("No attendance recorded yet.", color = MaterialTheme.colorScheme.onSurfaceVariant)
            else -> LazyColumn(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                items(units) { u ->
                    val eligible = u.status == "ELIGIBLE"
                    Surface(color = MaterialTheme.colorScheme.surfaceVariant, shape = MaterialTheme.shapes.medium) {
                        Column(Modifier.fillMaxWidth().padding(12.dp)) {
                            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                                Text(u.unitName.ifBlank { u.unitId }, Modifier.weight(1f), fontWeight = FontWeight.SemiBold)
                                Text("${"%.0f".format(u.pct)}%", fontWeight = FontWeight.Bold,
                                    color = if (eligible) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.error)
                            }
                            LinearProgressIndicator(progress = { (u.pct / 100.0).toFloat().coerceIn(0f, 1f) },
                                modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp))
                            Text("${u.attended}/${u.held} attended · pass mark ${u.threshold}%",
                                style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            if (!eligible) Text("Exam-ineligible" + (u.deficit?.let { " — attend $it more to recover" } ?: ""),
                                style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.error)
                        }
                    }
                }
            }
        }
        Spacer(Modifier.weight(1f))
        OutlinedButton(onClick = { load() }, enabled = !loading, modifier = Modifier.fillMaxWidth()) { Text("Refresh") }
    }
}

/** Home — greets the student, then their cohort's weekly timetable and the units they take.
 *  Deliberately just those two things, as the coordinator's Home is. */
@Composable
private fun StudentHome(reloadKey: Int) {
    var home by remember { mutableStateOf<StudentHomeClient.Home?>(null) }
    var loading by remember { mutableStateOf(true) }
    // The student's own attendance, summarised here rather than only on the Progress tab. The
    // number that decides whether they sit the exam is the reason they open the app; making them
    // find a second tab for it is what made this screen feel like a noticeboard.
    var progress by remember { mutableStateOf<ProgressClient.Progress?>(null) }
    LaunchedEffect(reloadKey) {
        loading = true
        home = runCatching { StudentHomeClient().fetch() }.getOrNull()
        home?.let { AppState.cohortLabel = it.cohort }
        loading = false
    }
    LaunchedEffect(reloadKey, AppState.studentId) {
        AppState.studentId?.takeIf { it.isNotBlank() }?.let { reg ->
            progress = runCatching { ProgressClient().fetch(reg) }.getOrNull()
        }
    }

    val name = home?.fullName?.takeIf { it.isNotBlank() }
        ?: AppState.coordinatorName?.takeIf { it.isNotBlank() } ?: "there"

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp)) {
        Text("Welcome, $name 👋", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.ExtraBold)
        (home?.cohort ?: AppState.cohortLabel)?.takeIf { it.isNotBlank() }?.let {
            Text(it, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Spacer(Modifier.height(18.dp))

        if (loading && home == null) {
            Box(Modifier.fillMaxWidth().padding(top = 40.dp), Alignment.Center) { CircularProgressIndicator() }
            return@Column
        }

        // ── Today, and what's next ───────────────────────────────────────────
        // The whole week was here and today was not called out, so a student had to find the right
        // weekday heading to answer the only question they open the app with.
        val allSlots = home?.timetable.orEmpty()
        TodayStrip(allSlots)

        // ── Where their attendance stands ────────────────────────────────────
        progress?.let { EligibilityStrip(it) }

        Text("Timetable", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(6.dp))
        val slots = allSlots
        if (slots.isEmpty()) {
            Text("No timetable published for your cohort yet.",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        } else {
            // The SAME Time × Day grid the coordinator sees, so a student comparing their phone
            // with the one at the front of the room is looking at one timetable, not two layouts
            // of it. This used to be a list of weekday headings, which made the week read as a
            // different thing depending on the role.
            TimetableGrid(
                entries = slots.map { sl ->
                    TtEntry(
                        name = sl.unitName.ifBlank { sl.unitId },
                        dayOfWeek = sl.dayOfWeek,
                        start = sl.startTime,
                        durationMin = sl.durationMinutes,
                        detail = listOfNotNull(
                            sl.room.takeIf { it.isNotBlank() },
                            sl.lecturerName.takeIf { it.isNotBlank() },
                        ).joinToString(" · "),
                    )
                },
                sessionType = home?.sessionType.orEmpty(),
            )
        }

        Spacer(Modifier.height(20.dp))
        val units = home?.units.orEmpty()
        val current = units.filter { it.current }
        val rest = units.filterNot { it.current }

        Text("Units", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(6.dp))
        when {
            units.isEmpty() -> Text("No units registered on your programme yet.",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            current.isEmpty() -> Text("Nothing is tagged for Year ${home?.year} Semester ${home?.semester} yet — your programme's full unit list is below.",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            else -> current.forEach { UnitRow(it) }
        }

        // The rest of the roadmap, so a student can always see where the semester sits in the
        // whole programme — and so an untagged year/semester never renders as "you have no units".
        if (rest.isNotEmpty()) {
            Spacer(Modifier.height(14.dp))
            Text("Other units on your programme", style = MaterialTheme.typography.labelLarge,
                fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.height(6.dp))
            rest.forEach { UnitRow(it, dimmed = true) }
        }
        Spacer(Modifier.height(24.dp))
    }
}

/**
 * Today's classes, with the next one still to come picked out.
 *
 * Built from the SAME weekly timetable already on this screen — no extra call — by filtering to
 * today's weekday and comparing start times against the clock. A day with nothing on it says so,
 * because "no classes today" is a genuinely useful answer and a blank space is not.
 */
@Composable
private fun TodayStrip(slots: List<StudentHomeClient.Slot>) {
    val today = java.time.LocalDate.now().dayOfWeek.value        // Mon=1 … Sun=7, as the API uses
    val now = java.time.LocalTime.now()
    val mine = slots.filter { it.dayOfWeek == today }.sortedBy { it.startTime }
    // The first class that has not started yet. Times are "HH:MM"; an unparseable one is treated
    // as still to come rather than silently dropped.
    val next = mine.firstOrNull { sl ->
        runCatching { java.time.LocalTime.parse(sl.startTime) }.getOrNull()?.isAfter(now) ?: true
    }

    Surface(
        color = MaterialTheme.colorScheme.primary.copy(alpha = .09f),
        shape = MaterialTheme.shapes.medium,
        modifier = Modifier.fillMaxWidth().padding(bottom = 14.dp),
    ) {
        Column(Modifier.padding(14.dp)) {
            Text(
                "Today · ${java.time.LocalDate.now().format(java.time.format.DateTimeFormatter.ofPattern("EEEE d MMM"))}",
                style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.primary,
            )
            Spacer(Modifier.height(6.dp))
            when {
                mine.isEmpty() -> Text(
                    "No classes timetabled today.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                else -> {
                    mine.forEach { sl ->
                        val isNext = sl === next
                        Row(
                            Modifier.fillMaxWidth().padding(vertical = 3.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(
                                sl.startTime,
                                style = MaterialTheme.typography.labelMedium,
                                fontWeight = if (isNext) FontWeight.ExtraBold else FontWeight.Normal,
                                color = if (isNext) MaterialTheme.colorScheme.primary
                                else MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.width(52.dp),
                            )
                            Column(Modifier.weight(1f)) {
                                Text(
                                    sl.unitName.ifBlank { sl.unitId },
                                    fontWeight = if (isNext) FontWeight.Bold else FontWeight.Normal,
                                    style = MaterialTheme.typography.bodyMedium,
                                )
                                sl.room.takeIf { it.isNotBlank() }?.let {
                                    Text(it, style = MaterialTheme.typography.labelSmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                                }
                            }
                            if (isNext) {
                                Text("NEXT", fontSize = 9.sp, fontWeight = FontWeight.ExtraBold,
                                    color = MaterialTheme.colorScheme.primary)
                            }
                        }
                    }
                }
            }
        }
    }
}

/**
 * Attendance against the exam-eligibility bar, in one line per state.
 *
 * A student cares about exactly one thing here: am I going to be allowed to sit the exam. So the
 * units below the threshold lead, with the number of sessions each still needs — the actionable
 * figure — rather than a percentage they have to interpret.
 */
@Composable
private fun EligibilityStrip(p: ProgressClient.Progress) {
    if (p.units.isEmpty()) return
    val below = p.units.filter { it.status.equals("INELIGIBLE", ignoreCase = true) }
    val overall = p.units.sumOf { it.held }.takeIf { it > 0 }
        ?.let { held -> p.units.sumOf { it.attended } * 100.0 / held }
    val ok = below.isEmpty()

    Surface(
        color = (if (ok) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.error).copy(alpha = .09f),
        shape = MaterialTheme.shapes.medium,
        modifier = Modifier.fillMaxWidth().padding(bottom = 16.dp),
    ) {
        Column(Modifier.padding(14.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Exam eligibility", style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.Bold)
                    Text(
                        if (ok) "All ${p.units.size} of your units are above the attendance bar."
                        else "${below.size} of your ${p.units.size} units ${if (below.size == 1) "is" else "are"} below the bar.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                overall?.let {
                    Text(
                        "${it.toInt()}%", fontWeight = FontWeight.ExtraBold,
                        style = MaterialTheme.typography.titleMedium,
                        color = if (ok) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.error,
                    )
                }
            }
            // Name the units at risk and what it takes to fix each. Capped so a student failing
            // everything gets a readable list rather than the whole roadmap again.
            below.take(4).forEach { u ->
                Spacer(Modifier.height(6.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(u.unitName.ifBlank { u.unitId }, Modifier.weight(1f),
                        style = MaterialTheme.typography.bodySmall)
                    Text(
                        u.deficit?.takeIf { it > 0 }?.let { "attend $it more" } ?: "${u.pct.toInt()}%",
                        style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.Bold,
                        color = MaterialTheme.colorScheme.error,
                    )
                }
            }
            if (below.size > 4) {
                Text("…and ${below.size - 4} more — see My attendance.",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = 6.dp))
            }
        }
    }
}

/** One unit on the student's roadmap. `dimmed` marks a unit outside the current year/semester. */
@Composable
private fun UnitRow(u: StudentHomeClient.Unit, dimmed: Boolean = false) {
    val alpha = if (dimmed) 0.55f else 1f
    Surface(
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = if (dimmed) 0.45f else 1f),
        shape = MaterialTheme.shapes.medium,
        modifier = Modifier.fillMaxWidth().padding(bottom = 6.dp),
    ) {
        Row(Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(u.unitName.ifBlank { u.unitId }, fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = alpha))
                Text(
                    listOfNotNull(u.unitId.takeIf { it.isNotBlank() },
                        u.lecturerName.takeIf { it.isNotBlank() }).joinToString(" · "),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = alpha),
                )
            }
            if (u.year > 0) Text("Y${u.year}/S${u.semester}",
                style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = alpha))
        }
    }
}

/** Profile — a whole page, so it shows the student's whole record rather than three lines. */
@Composable
private fun StudentProfile(reloadKey: Int, onOpenPortal: () -> Unit) {
    var showChangePw by remember { mutableStateOf(false) }
    if (showChangePw) ChangePasswordDialog(onClose = { showChangePw = false })

    var home by remember { mutableStateOf<StudentHomeClient.Home?>(null) }
    LaunchedEffect(reloadKey) { home = runCatching { StudentHomeClient().fetch() }.getOrNull() }

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp)) {
        Text("Profile", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(14.dp))

        // Identity card.
        Surface(color = MaterialTheme.colorScheme.surfaceVariant, shape = MaterialTheme.shapes.large,
            modifier = Modifier.fillMaxWidth()) {
            Column(Modifier.padding(16.dp)) {
                Text(home?.fullName?.takeIf { it.isNotBlank() } ?: AppState.coordinatorName.orEmpty(),
                    style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
                AppState.role?.let {
                    Text(it, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
        Spacer(Modifier.height(16.dp))

        ProfileField("Registration number", home?.studentId ?: AppState.studentId.orEmpty())
        ProfileField("Email", home?.email.orEmpty())
        ProfileField("Course", home?.course.orEmpty())
        ProfileField("Level of study", home?.level.orEmpty())
        ProfileField("Study session", home?.sessionType.orEmpty())
        ProfileField("Intake", home?.intake.orEmpty())
        ProfileField("Year of study", home?.year?.takeIf { it > 0 }?.let { "Year $it" }.orEmpty())
        ProfileField("Semester", home?.semester?.takeIf { it > 0 }?.let { "Semester $it" }.orEmpty())
        ProfileField("Academic year", home?.academicYear.orEmpty())
        ProfileField("Cohort", home?.cohort ?: AppState.cohortLabel.orEmpty())
        // This semester's units, not the whole programme roadmap that Home also lists.
        ProfileField("Units this semester", home?.units?.count { it.current }?.takeIf { it > 0 }?.toString().orEmpty())

        Spacer(Modifier.height(22.dp))
        Button(onClick = onOpenPortal, Modifier.fillMaxWidth()) { Text("🎓  Student portal") }
        Spacer(Modifier.height(8.dp))
        OutlinedButton(onClick = { showChangePw = true }, Modifier.fillMaxWidth()) { Text("🔑  Change password") }
        Spacer(Modifier.height(8.dp))
        SignOutButton()
        Spacer(Modifier.height(24.dp))
    }
}

/** One label/value row. Blank values are skipped rather than shown as an empty line. */
@Composable
private fun ProfileField(label: String, value: String) {
    if (value.isBlank()) return
    Column(Modifier.fillMaxWidth().padding(vertical = 6.dp)) {
        Text(label, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(value, style = MaterialTheme.typography.bodyMedium)
    }
    HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = .4f))
}
