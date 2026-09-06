package ug.qaat.coordinator.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import ug.qaat.coordinator.db.OfficePersonEntity
import ug.qaat.coordinator.db.OfficeVisitEntity
import ug.qaat.coordinator.di.Graph
import ug.qaat.coordinator.net.PatrolClient
import ug.qaat.coordinator.student.Fingerprint
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.format.DateTimeFormatter
import java.util.UUID

/**
 * THE OFFICE ROUND — the QA monitor's second round.
 *
 * The round beside this one walks lecture rooms and records whether a lecturer taught. This one
 * walks offices and records whether an administrative employee was at theirs.
 *
 * WHY IT EXISTS. Every other record of an employee's presence in this system was made by a
 * machine: badge punches from the check-in tablet, campus presence from U-Panel, and the biometric
 * terminal's daily sheet. A badge can be tapped by a colleague, and a terminal saying somebody
 * clocked in at 08:00 says nothing about whether they were at their desk at 11:00. This is the
 * human witness, filed beside those and never merged with them.
 *
 * SEARCH FIRST, exactly as the lecture round does, and for the same reason: a screen listing every
 * employee with a pair of present/absent buttons invites recording without visiting. Nothing
 * appears until the monitor looks somebody up.
 *
 * THIS FILE CARRIES NO GATE. DeviceGate and PatrolPinGate in PatrolRoleApp wrap all four tabs, so
 * the office round inherits the handset record and the PIN with no code of its own.
 */
@Composable
fun OfficeRoundTab(reloadKey: Int) {
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    val dao = remember { Graph.db.dao() }

    var query by remember { mutableStateOf("") }
    var results by remember { mutableStateOf<List<OfficePersonEntity>?>(null) }   // null = nothing searched yet
    var searching by remember { mutableStateOf(false) }
    var chosen by remember { mutableStateOf<OfficePersonEntity?>(null) }
    var note by remember { mutableStateOf<String?>(null) }
    var pending by remember { mutableStateOf(0) }
    val visits by dao.officeVisitsForDay(LocalDate.now().toString()).collectAsStateWithLifecycle(emptyList())

    // The cached registry refreshes in the background: it is what makes the search work with no
    // signal, which is most of a round in a concrete building.
    suspend fun refreshCache() {
        val token = AppState.token
        if (token != null) {
            runCatching { PatrolClient().officeManifest(token, Fingerprint.get(ctx)) }
                .onSuccess { fresh -> withContext(Dispatchers.IO) { dao.replaceOfficePeople(fresh) } }
                .onFailure { if (it is PatrolClient.DeviceRejected) note = it.message }
        }
        // BOTH queues, from this tab too — the lecture round's ticks must not be stranded behind
        // the Rooms tab any more than these are behind this one.
        syncPendingOffice(ctx)?.let { note = it }
        syncPending(ctx)?.let { note = it }
        pending = withContext(Dispatchers.IO) { dao.pendingOfficeCount() + dao.pendingPatrolCount() }
    }
    LaunchedEffect(reloadKey) { refreshCache() }

    fun runSearch() = scope.launch {
        val q = query.trim()
        if (q.isEmpty()) { results = null; return@launch }
        searching = true; note = null
        val token = AppState.token
        val online = if (token != null) {
            runCatching { PatrolClient().officeSearch(token, Fingerprint.get(ctx), q) }
                .onFailure { if (it is PatrolClient.DeviceRejected) note = it.message }
                .getOrNull()
        } else null

        results = if (online != null) online else {
            // Offline: search the cached registry with the SAME rule as the server, so the monitor
            // does not get a different answer depending on whether the signal happened to be up.
            note = "Offline — searching the cached employee list."
            OfficeSearchMatch.filter(withContext(Dispatchers.IO) { dao.officePeople() }, q)
        }
        searching = false
    }

    /**
     * File a visit.
     *
     * visitId decides what this IS. Re-using the id of an earlier visit today is a CORRECTION —
     * the server rewrites that row. A fresh id is a SECOND VISIT, because calling again at 15:30
     * is a new observation and not a revision of the 09:00 one, and collapsing the two would lose
     * the most useful thing this round produces: empty in the morning, there in the afternoon.
     */
    fun record(
        p: OfficePersonEntity,
        visitId: String,
        office: String,
        officeSource: String,
        status: String,
        foundAt: String,
        remarks: String,
    ) = scope.launch {
        val now = LocalTime.now()
        withContext(Dispatchers.IO) {
            dao.putOfficeVisit(OfficeVisitEntity(
                id = visitId,
                staffId = p.staffId,
                employeeName = p.fullName,
                department = p.department,
                jobTitle = p.jobTitle,
                office = office,
                officeSource = officeSource,
                status = status,
                foundAt = foundAt,
                remarks = remarks,
                visitDate = LocalDate.now().toString(),
                visitTime = now.format(DateTimeFormatter.ofPattern("HH:mm")),
                capturedAt = Instant.now().toString(),
            ))
        }
        chosen = null
        syncPendingOffice(ctx)?.let { note = it }
        pending = withContext(Dispatchers.IO) { dao.pendingOfficeCount() + dao.pendingPatrolCount() }
    }

    // Today's last visit per person, so a card can say what is already on file and the sheet can
    // offer to correct it rather than silently filing a second one.
    val lastToday = visits.associateBy { it.staffId }

    chosen?.let { person ->
        OfficeConfirmSheet(
            person = person,
            existing = lastToday[person.staffId],
            onDismiss = { chosen = null },
            onRecord = { visitId, office, source, status, foundAt, remarks ->
                record(person, visitId, office, source, status, foundAt, remarks)
            },
        )
    }

    Column(Modifier.fillMaxSize().padding(16.dp)) {
        Text("Office round — ${AppState.coordinatorName.orEmpty().ifBlank { "QA" }}",
            fontWeight = FontWeight.Bold, fontSize = 18.sp)
        Text(
            "Staff ID: ${AppState.staffId.orEmpty().ifBlank { "—" }}" +
                if (pending > 0) "  ·  $pending pending sync" else "  ·  all synced",
            style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Text("Search the person whose office you are at, then record what you found. Works offline.",
            style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(vertical = 6.dp))

        // ONE BOX, not the lecture round's pair of chips. There is one object here — a person —
        // and several ways to name them, so asking the monitor to first classify what they are
        // about to type is a question with no useful answer.
        OutlinedTextField(
            value = query,
            onValueChange = { query = it },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
            label = { Text("Name, staff ID, department or office") },
            placeholder = { Text("e.g. NAKATO, KIU/044, Finance") },
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
            keyboardActions = KeyboardActions(onSearch = { runSearch() }),
            trailingIcon = {
                TextButton(onClick = { runSearch() }, enabled = query.isNotBlank() && !searching) {
                    Text(if (searching) "…" else "Search")
                }
            },
        )

        note?.let {
            Spacer(Modifier.height(8.dp))
            Surface(color = MaterialTheme.colorScheme.errorContainer, shape = MaterialTheme.shapes.small,
                modifier = Modifier.fillMaxWidth()) {
                Text(it, Modifier.padding(10.dp), style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onErrorContainer)
            }
        }
        Spacer(Modifier.height(12.dp))

        // Read the hits into a local before branching — the LazyColumn's content lambda runs
        // outside this composition, by which time an emptied query can have cleared the state.
        val hits = results
        when {
            searching -> Box(Modifier.fillMaxWidth().padding(top = 40.dp), Alignment.Center) { CircularProgressIndicator() }
            // Nothing searched yet is NOT nothing found, and must not read as it.
            hits == null -> Text(
                "Nobody is shown until you search. Enter the name or staff ID on the door you are at.",
                color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(top = 20.dp))
            hits.isEmpty() -> Column(Modifier.padding(top = 20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("Nobody in the employee list matches “${query.trim()}”.",
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                // NO MANUAL FALLBACK HERE, deliberately — unlike the lecture round. A person the
                // registry does not know has no contact details, so a visit filed against them
                // would be an observation about somebody the institution cannot tell, and no
                // report could group it. The gap is named instead of worked around.
                Text(
                    "The office round can only record people on the employee list — that is how the " +
                        "record reaches them afterwards. If somebody is missing, ask an administrator " +
                        "to add them.",
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            else -> LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                items(hits) { p -> OfficeResultCard(p, lastToday[p.staffId]) { chosen = p } }
            }
        }
    }
}

/** One search hit. Tapping opens the sheet — the card itself cannot record, so a verdict is always
 *  two deliberate actions rather than one thumb on a scrolling list. */
@Composable
private fun OfficeResultCard(
    p: OfficePersonEntity,
    recorded: OfficeVisitEntity?,
    onOpen: () -> Unit,
) {
    Surface(
        color = MaterialTheme.colorScheme.surfaceVariant,
        shape = MaterialTheme.shapes.medium,
        onClick = onOpen,
    ) {
        Column(Modifier.fillMaxWidth().padding(12.dp)) {
            Text(p.fullName.ifBlank { p.staffId }, fontWeight = FontWeight.SemiBold)
            Text(p.staffId, style = MaterialTheme.typography.labelSmall,
                fontFamily = FontFamily.Monospace, color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (p.jobTitle.isNotBlank() || p.department.isNotBlank()) {
                Text(listOf(p.jobTitle, p.department).filter { it.isNotBlank() }.joinToString(" · "),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Text("Office: ${p.office.ifBlank { "not on file — you will type it" }}",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (recorded != null) {
                Spacer(Modifier.height(6.dp))
                Text(
                    "Already today: ${officeVerdictLabel(recorded.status)} at ${recorded.visitTime}" +
                        if (!recorded.synced) " · queued" else "",
                    color = if (recorded.status == "ABSENT") MaterialTheme.colorScheme.error
                    else MaterialTheme.colorScheme.primary,
                    style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.Bold,
                )
            }
        }
    }
}

/** What a stored verdict is called on screen. "Office empty", never "Absent" — one knock
 *  establishes that a door had nobody behind it, which is the smaller and the only true claim. */
internal fun officeVerdictLabel(status: String): String = when (status) {
    "AT_OFFICE" -> "At their office"
    "ELSEWHERE_ON_DUTY" -> "Elsewhere, on duty"
    "ABSENT" -> "Office empty"
    else -> status
}

/**
 * The verdict sheet: three answers, not two.
 *
 * "Elsewhere, on duty" is the whole reason this is not a pair of buttons. A monitor who knocks,
 * finds nobody, and then learns the person is at a meeting has established something quite
 * different from a monitor who finds an empty room nobody can account for — and a boolean would
 * force them to record the first as the second. That is a false accusation against somebody who
 * was working, and since only "Office empty" is reported to the person, the distinction decides
 * whether they get a message at all.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun OfficeConfirmSheet(
    person: OfficePersonEntity,
    existing: OfficeVisitEntity?,
    onDismiss: () -> Unit,
    onRecord: (visitId: String, office: String, officeSource: String,
               status: String, foundAt: String, remarks: String) -> Unit,
) {
    // Prefilled from the registry. officeSource is DERIVED by comparing what is in the box with
    // what the registry said, rather than tracked as its own flag — two sources of truth for one
    // fact is how they end up disagreeing.
    var office by remember(person.staffId) { mutableStateOf(person.office) }
    var foundAt by remember(person.staffId) { mutableStateOf("") }
    var remarks by remember(person.staffId) { mutableStateOf("") }
    // Correcting today's record, or filing a fresh visit. Defaults to CORRECT when one exists —
    // the commoner case is fixing a tap, and the monitor has to choose the other deliberately.
    var correcting by remember(person.staffId) { mutableStateOf(existing != null) }

    val officeSource = if (office.trim() == person.office.trim() && person.office.isNotBlank())
        "REGISTRY" else "TYPED"

    fun submit(status: String) {
        val id = if (correcting && existing != null) existing.id else UUID.randomUUID().toString()
        onRecord(id, office.trim(), officeSource, status,
            if (status == "ELSEWHERE_ON_DUTY") foundAt.trim() else "", remarks.trim())
    }

    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(bottom = 28.dp)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text(person.fullName.ifBlank { person.staffId },
                fontWeight = FontWeight.Bold, fontSize = 18.sp)
            Text(listOf(person.staffId, person.jobTitle, person.department)
                .filter { it.isNotBlank() }.joinToString(" · "),
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)

            OutlinedTextField(
                value = office,
                onValueChange = { office = it },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
                label = { Text("Office you went to") },
                placeholder = { Text("e.g. Block C, Room 14") },
                supportingText = {
                    Text(
                        if (officeSource == "REGISTRY") "From the employee record"
                        else if (office.isBlank()) "Not on file — type where you looked"
                        else "Typed — the record will show the employee list has this wrong",
                    )
                },
            )

            if (existing != null) {
                // A second call at the same office is a real thing and must not be mistaken for a
                // correction — nor the other way round. Said in words, because the difference is
                // invisible afterwards and only the monitor knows which they mean.
                Surface(color = MaterialTheme.colorScheme.surfaceVariant,
                    shape = MaterialTheme.shapes.small, modifier = Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(10.dp)) {
                        Text("Already recorded today: ${officeVerdictLabel(existing.status)} at ${existing.visitTime}",
                            style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.Bold)
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            RadioButton(selected = correcting, onClick = { correcting = true })
                            Text("Correct that record", style = MaterialTheme.typography.labelMedium)
                        }
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            RadioButton(selected = !correcting, onClick = { correcting = false })
                            Text("Record another visit", style = MaterialTheme.typography.labelMedium)
                        }
                    }
                }
            }

            OutlinedTextField(
                value = foundAt,
                onValueChange = { foundAt = it },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
                label = { Text("If they were elsewhere, where?") },
                placeholder = { Text("e.g. Bursar's meeting, Block A") },
            )
            OutlinedTextField(
                value = remarks,
                onValueChange = { remarks = it },
                modifier = Modifier.fillMaxWidth(),
                label = { Text("Remarks (optional)") },
            )

            Spacer(Modifier.height(2.dp))
            Button(onClick = { submit("AT_OFFICE") }, modifier = Modifier.fillMaxWidth()) {
                Text("✓  At their office")
            }
            OutlinedButton(
                onClick = { submit("ELSEWHERE_ON_DUTY") },
                enabled = foundAt.isNotBlank(),
                modifier = Modifier.fillMaxWidth(),
            ) { Text("↗  Elsewhere, on duty") }
            Text(
                if (foundAt.isBlank())
                    "Say where they were to use this — an unexplained \"elsewhere\" tells a reader nothing."
                else "Recorded as working, not as absent. Nothing is sent to them.",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            OutlinedButton(
                onClick = { submit("ABSENT") },
                modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.outlinedButtonColors(contentColor = MaterialTheme.colorScheme.error),
            ) { Text("✗  Office empty") }
            // The warning goes under the button it is about, and names the consequence rather than
            // the rule. A monitor choosing between two options needs to know that one of them
            // sends a message to the person and the other does not.
            Text(
                "Only if nobody could say where they are. If you found them, or learned where they " +
                    "were, use “Elsewhere” — an empty office is reported to the person, and it " +
                    "should be reported for the right reason.",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}
