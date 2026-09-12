import 'dart:math';

import 'package:flutter/material.dart';

import '../../net/portal_client.dart';
import '../../patrol/fingerprint.dart';
import '../../patrol/office_search_match.dart';
import '../../patrol/patrol_client.dart';
import '../../patrol/patrol_models.dart';
import '../../patrol/patrol_store.dart';
import 'manual_attendance_sheet.dart' show PickOrType;
import 'patrol_round_tab.dart' show todayDate;
import 'sync_pending.dart';

/// What a stored verdict is called on screen. "Office empty", never "Absent" — one
/// knock establishes that a door had nobody behind it, which is the smaller and the
/// only true claim.
String officeVerdictLabel(String status) => switch (status) {
  'AT_OFFICE' => 'At their office',
  'ELSEWHERE_ON_DUTY' => 'Elsewhere, on duty',
  'ABSENT' => 'Office empty',
  _ => status,
};

/// THE OFFICE ROUND — the QA monitor's second round.
///
/// The round beside this one walks lecture rooms and records whether a lecturer
/// taught. This one walks offices and records whether an administrative employee
/// was at theirs. Why it exists: every other record of an employee's presence is a
/// machine's — badge punches, campus presence, a biometric sheet. A badge can be
/// tapped by a colleague; this is the human witness, filed beside those and never
/// merged with them.
///
/// SEARCH FIRST, exactly as the room round does: a screen listing every employee
/// with a pair of present/absent buttons invites recording without visiting.
///
/// This tab carries NO gate — DeviceGate and PatrolPinGate wrap all four tabs in the
/// round app, so the office round inherits handset binding and the PIN with no code
/// of its own.
class OfficeRoundTab extends StatefulWidget {
  const OfficeRoundTab({
    super.key,
    required this.token,
    required this.reloadKey,
    this.name = '',
    this.staffId = '',
  });

  final String token;
  final int reloadKey;
  final String name;
  final String staffId;

  @override
  State<OfficeRoundTab> createState() => _OfficeRoundTabState();
}

class _OfficeRoundTabState extends State<OfficeRoundTab> {
  final PatrolClient _client = PatrolClient();

  String _query = '';
  List<OfficePerson>? _results; // null = nothing searched yet
  bool _searching = false;
  String? _note;
  int _pending = 0;
  List<OfficeVisit> _todayVisits = const [];
  // null = switch status unknown (tenant gate); false/true once known. Drives the
  // "add administrator" affordance in the empty state.
  bool? _canAddAdmins;

  @override
  void initState() {
    super.initState();
    _refreshCache();
    _loadAddAdminGate();
  }

  Future<void> _loadAddAdminGate() async {
    final token = widget.token;
    if (token.isEmpty) return;
    final s = await const PortalClient().canMonitorAddAdmins(token);
    if (!mounted) return;
    setState(() => _canAddAdmins = s?.enabled ?? false);
  }

  @override
  void didUpdateWidget(OfficeRoundTab old) {
    super.didUpdateWidget(old);
    if (old.reloadKey != widget.reloadKey) _refreshCache();
  }

  /// The cached registry refreshes in the background: it is what makes the search
  /// work with no signal, which is most of a round in a concrete building.
  Future<void> _refreshCache() async {
    final token = widget.token;
    if (token.isNotEmpty) {
      try {
        final fresh = await _client.officeManifest(
          token,
          await DeviceFingerprint.get(),
        );
        await patrolStore.replaceOfficePeople(fresh);
      } on PatrolDeviceRejected catch (e) {
        setState(() => _note = e.message);
      } on Object {
        // Offline — the cached registry stays.
      }
    }
    // BOTH queues, from this tab too — the room round's ticks must not be stranded
    // behind the Rooms tab any more than these are behind this one.
    final n1 = await syncPendingOffice(token);
    final n2 = await syncPending(token);
    await _reloadPending();
    if (!mounted) return;
    setState(() {
      if (n1 != null) _note ??= n1;
      if (n2 != null) _note ??= n2;
    });
  }

  Future<void> _reloadPending() async {
    final today = todayDate();
    final visits = await patrolStore.officeVisitsForDay(today);
    final p = await pendingTotal();
    if (!mounted) return;
    setState(() {
      _todayVisits = visits;
      _pending = p;
    });
  }

  Future<void> _runSearch() async {
    final q = _query.trim();
    if (q.isEmpty) {
      setState(() => _results = null);
      return;
    }
    setState(() {
      _searching = true;
      _note = null;
    });
    final token = widget.token;
    List<OfficePerson>? online;
    if (token.isNotEmpty) {
      try {
        online = await _client.officeSearch(
          token,
          await DeviceFingerprint.get(),
          q,
        );
      } on PatrolDeviceRejected catch (e) {
        if (mounted) setState(() => _note = e.message);
      } on Object {
        online = null;
      }
    }

    final results = online ?? await _offlineSearch(q);
    if (!mounted) return;
    setState(() {
      _results = results;
      _searching = false;
      if (online == null) {
        _note ??= 'Offline — searching the cached employee list.';
      }
    });
  }

  Future<List<OfficePerson>> _offlineSearch(String q) async =>
      OfficeSearchMatch.filter(await patrolStore.officePeople(), q);

  /// File a visit. `visitId` decides what this IS: re-using the id of an earlier
  /// visit today is a CORRECTION (the server rewrites that row); a fresh id is a
  /// SECOND VISIT, because calling again at 15:30 is a new observation and not a
  /// revision of the 09:00 one.
  Future<void> _record(
    OfficePerson p,
    String visitId,
    String office,
    String officeSource,
    String status,
    String foundAt,
    String remarks,
  ) async {
    final now = DateTime.now();
    final hhmm =
        '${now.hour.toString().padLeft(2, '0')}'
        ':${now.minute.toString().padLeft(2, '0')}';
    await patrolStore.putOfficeVisit(
      OfficeVisit(
        id: visitId,
        staffId: p.staffId,
        employeeName: p.fullName,
        department: p.department,
        jobTitle: p.jobTitle,
        office: office,
        officeSource: officeSource,
        status: status,
        foundAt: foundAt,
        remarks: remarks,
        visitDate: todayDate(),
        visitTime: hhmm,
        capturedAt: now.toUtc().toIso8601String(),
      ),
    );
    await _reloadPending();
    final n = await syncPendingOffice(widget.token);
    await _reloadPending();
    if (!mounted) return;
    setState(() {
      if (n != null) _note = n;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurfaceVariant;
    // Today's last visit per person, so a card can say what is already on file and
    // the sheet can offer to correct it rather than silently filing a second one.
    final lastToday = {for (final v in _todayVisits) v.staffId: v};

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Office round — ${widget.name.isNotEmpty ? widget.name : 'QA'}',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        Text(
          'Staff ID: ${widget.staffId.isNotEmpty ? widget.staffId : '—'}'
          '${_pending > 0 ? '   ·   $_pending pending sync' : '   ·   all synced'}',
          style: theme.textTheme.bodySmall?.copyWith(color: onSurface),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text(
            'Search the person whose office you are at, then record what you '
            'found. Works offline.',
            style: theme.textTheme.bodySmall?.copyWith(color: onSurface),
          ),
        ),
        // ONE BOX, not the room round's pair of chips. There is one object here —
        // a person — and several ways to name them, so asking the monitor to first
        // classify what they are about to type is a question with no useful answer.
        TextField(
          onChanged: (v) => setState(() => _query = v),
          onSubmitted: (_) => _runSearch(),
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            labelText: 'Name, staff ID, department or office',
            hintText: 'e.g. NAKATO, KIU/044, Finance',
            border: const OutlineInputBorder(),
            suffixIcon: TextButton(
              onPressed: _query.trim().isNotEmpty && !_searching
                  ? _runSearch
                  : null,
              child: Text(_searching ? '…' : 'Search'),
            ),
          ),
        ),
        if (_note != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: theme.colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                _note!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onErrorContainer,
                ),
              ),
            ),
          ),
        const SizedBox(height: 12),
        Expanded(child: _buildResults(theme, lastToday)),
      ],
    );
  }

  Widget _buildResults(ThemeData theme, Map<String, OfficeVisit> lastToday) {
    final hits = _results;
    final Widget body;
    if (_searching) {
      body = const Center(
        child: Padding(
          padding: EdgeInsets.only(top: 40),
          child: CircularProgressIndicator(),
        ),
      );
    } else if (hits == null) {
      body = Padding(
        padding: const EdgeInsets.only(top: 20),
        child: Text(
          'Nobody is shown until you search. Enter the name or staff ID on the '
          'door you are at.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    } else if (hits.isEmpty) {
      // NO MANUAL FALLBACK HERE for visits, deliberately — unlike the room round.
      // A person the registry does not know has no contact details, so a visit
      // filed against them would be an observation about somebody the institution
      // cannot tell, and no report could group it. The gap is named instead of
      // worked around — and, when the institution has opened the ADD-ONLY gate, a
      // monitor can close part of it now: provision an ADMINISTRATOR for the person
      // (the one account the office round itself cannot create, and the only kind
      // the monitor-add flow is allowed to make — it can never edit or delete).
      body = Padding(
        padding: const EdgeInsets.only(top: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Nobody in the employee list matches "${_query.trim()}".',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'The office round can only record people on the employee list — that '
              'is how the record reaches them afterwards.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (_canAddAdmins == true) ...[
              const SizedBox(height: 12),
              FilledButton.icon(
                icon: const Icon(Icons.person_add_alt),
                label: const Text('Add this person as an administrator'),
                onPressed: _openAddAdmin,
              ),
              Text(
                'Creates an administrator account they can sign in with. '
                'Add-only: nothing here can edit or remove an existing one.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ] else ...[
              const SizedBox(height: 12),
              Text(
                'If somebody is missing, ask an administrator to add them.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      );
    } else {
      body = ListView.separated(
        itemCount: hits.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (_, i) => OfficeResultCard(
          person: hits[i],
          recorded: lastToday[hits[i].staffId],
          onOpen: () => _openConfirm(hits[i], lastToday[hits[i].staffId]),
        ),
      );
    }
    return body;
  }

  Future<void> _openConfirm(OfficePerson p, OfficeVisit? existing) async {
    final result =
        await showModalBottomSheet<
          ({
            String visitId,
            String office,
            String source,
            String status,
            String foundAt,
            String remarks,
          })
        >(
          context: context,
          isScrollControlled: true,
          builder: (_) => OfficeConfirmSheet(person: p, existing: existing),
        );
    if (result == null) return;
    await _record(
      p,
      result.visitId,
      result.office,
      result.source,
      result.status,
      result.foundAt,
      result.remarks,
    );
  }

  Future<void> _openAddAdmin() async {
    final deptOptions = await _departmentOptions();
    if (!mounted) return;
    final message = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) =>
          _AddAdminSheet(token: widget.token, deptOptions: deptOptions),
    );
    if (message == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 6)),
    );
  }

  /// Departments from the cached employee registry — the searchable drop-down the
  /// add-admin form offers, so an office in "ICT Services" is typed or picked, not
  /// groped for. Offline and empty, pure typing still works (it is optional).
  Future<List<RefItem>> _departmentOptions() async {
    final people = await patrolStore.officePeople();
    final names =
        people
            .map((p) => p.department)
            .where((d) => d.trim().isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    return [for (final d in names) RefItem(d, d)];
  }
}

/// One search hit. Tapping opens the sheet — the card itself cannot record, so a
/// verdict is always two deliberate actions rather than one thumb on a scrolling list.
class OfficeResultCard extends StatelessWidget {
  const OfficeResultCard({
    super.key,
    required this.person,
    required this.recorded,
    required this.onOpen,
  });

  final OfficePerson person;
  final OfficeVisit? recorded;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurfaceVariant;
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                person.fullName.isNotEmpty ? person.fullName : person.staffId,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              Text(
                person.staffId,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: onSurface,
                  fontFamily: 'monospace',
                ),
              ),
              if (person.jobTitle.isNotEmpty || person.department.isNotEmpty)
                Text(
                  [
                    person.jobTitle,
                    person.department,
                  ].where((s) => s.isNotEmpty).join(' · '),
                  style: theme.textTheme.bodySmall?.copyWith(color: onSurface),
                ),
              Text(
                'Office: ${person.office.isNotEmpty ? person.office : 'not on file — you will type it'}',
                style: theme.textTheme.bodySmall?.copyWith(color: onSurface),
              ),
              if (recorded != null) ...[
                const SizedBox(height: 6),
                Text(
                  'Already today: ${officeVerdictLabel(recorded!.status)} at '
                  '${recorded!.visitTime}${!recorded!.synced ? ' · queued' : ''}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: recorded!.status == 'ABSENT'
                        ? theme.colorScheme.error
                        : theme.colorScheme.primary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The verdict sheet: three answers, not two.
///
/// "Elsewhere, on duty" is the whole reason this is not a pair of buttons. A
/// monitor who knocks, finds nobody, and then learns the person is at a meeting has
/// established something quite different from a monitor who finds an empty room
/// nobody can account for — and a boolean would force them to record the first as
/// the second. Only "Office empty" is reported to the person, so the distinction
/// decides whether they get a message at all.
class OfficeConfirmSheet extends StatefulWidget {
  const OfficeConfirmSheet({
    super.key,
    required this.person,
    required this.existing,
  });

  final OfficePerson person;
  final OfficeVisit? existing;

  @override
  State<OfficeConfirmSheet> createState() => _OfficeConfirmSheetState();
}

class _OfficeConfirmSheetState extends State<OfficeConfirmSheet> {
  late String _office;
  String _foundAt = '';
  String _remarks = '';
  // Correcting today's record, or filing a fresh visit. Defaults to CORRECT when
  // one exists — the commoner case is fixing a tap, and the monitor has to choose
  // the other deliberately.
  late bool _correcting;

  @override
  void initState() {
    super.initState();
    _office = widget.person.office;
    _correcting = widget.existing != null;
  }

  String get _officeSource {
    // Prefilled from the registry. officeSource is DERIVED by comparing what is in
    // the box with what the registry said, rather than tracked as its own flag —
    // two sources of truth for one fact is how they end up disagreeing.
    final p = widget.person;
    return _office.trim() == p.office.trim() && p.office.isNotEmpty
        ? 'REGISTRY'
        : 'TYPED';
  }

  void _submit(String status) {
    if (widget.existing == null && !_correcting) return;
    final id = (_correcting && widget.existing != null)
        ? widget.existing!.id
        : _uuid();
    Navigator.of(context).pop((
      visitId: id,
      office: _office.trim(),
      source: _officeSource,
      status: status,
      foundAt: status == 'ELSEWHERE_ON_DUTY' ? _foundAt.trim() : '',
      remarks: _remarks.trim(),
    ));
  }

  String _uuid() {
    final r = Random.secure();
    final b = List<int>.generate(16, (_) => r.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final hex = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = widget.person;
    final onSurface = theme.colorScheme.onSurfaceVariant;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              p.fullName.isNotEmpty ? p.fullName : p.staffId,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              [
                p.staffId,
                p.jobTitle,
                p.department,
              ].where((s) => s.isNotEmpty).join(' · '),
              style: theme.textTheme.bodySmall?.copyWith(color: onSurface),
            ),
            const SizedBox(height: 10),
            TextField(
              onChanged: (v) => setState(() => _office = v),
              decoration: const InputDecoration(
                labelText: 'Office you went to',
                hintText: 'e.g. Block C, Room 14',
                border: OutlineInputBorder(),
              ),
            ),
            Text(
              _officeSource == 'REGISTRY'
                  ? 'From the employee record'
                  : _office.trim().isEmpty
                  ? 'Not on file — type where you looked'
                  : 'Typed — the record will show the employee list has this wrong',
              style: theme.textTheme.bodySmall?.copyWith(color: onSurface),
            ),
            if (widget.existing != null) ...[
              const SizedBox(height: 10),
              // A second call at the same office is a real thing and must not be
              // mistaken for a correction — nor the other way round. Said in words,
              // because the difference is invisible afterwards and only the monitor
              // knows which they mean.
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Already recorded today: '
                      '${officeVerdictLabel(widget.existing!.status)} at '
                      '${widget.existing!.visitTime}',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    RadioGroup<bool>(
                      groupValue: _correcting,
                      onChanged: (v) => setState(() => _correcting = v ?? true),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              Radio<bool>(value: true),
                              const Text('Correct that record'),
                            ],
                          ),
                          Row(
                            children: [
                              Radio<bool>(value: false),
                              const Text('Record another visit'),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 10),
            TextField(
              onChanged: (v) => setState(() => _foundAt = v),
              decoration: const InputDecoration(
                labelText: 'If they were elsewhere, where?',
                hintText: 'e.g. Bursar\'s meeting, Block A',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              onChanged: (v) => setState(() => _remarks = v),
              decoration: const InputDecoration(
                labelText: 'Remarks (optional)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 18),
            FilledButton(
              onPressed: () => _submit('AT_OFFICE'),
              child: const Text('✓  At their office'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: _foundAt.trim().isNotEmpty
                  ? () => _submit('ELSEWHERE_ON_DUTY')
                  : null,
              child: const Text('↗  Elsewhere, on duty'),
            ),
            Text(
              _foundAt.trim().isEmpty
                  ? 'Say where they were to use this — an unexplained "elsewhere" '
                        'tells a reader nothing.'
                  : 'Recorded as working, not as absent. Nothing is sent to them.',
              style: theme.textTheme.bodySmall?.copyWith(color: onSurface),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () => _submit('ABSENT'),
              style: OutlinedButton.styleFrom(
                foregroundColor: theme.colorScheme.error,
              ),
              child: const Text('✗  Office empty'),
            ),
            // The warning goes under the button it is about, and names the
            // consequence rather than the rule.
            Text(
              'Only if nobody could say where they are. If you found them, or '
              'learned where they were, use "Elsewhere" — an empty office is '
              'reported to the person, and it should be reported for the right '
              'reason.',
              style: theme.textTheme.bodySmall?.copyWith(color: onSurface),
            ),
          ],
        ),
      ),
    );
  }
}

/// The ADD-ONLY administrator form a monitor can open from the offices round.
///
/// This is deliberately narrower than the admin Users screen: it can only CREATE
/// an administrator — never edit, disable or delete — and the backend re-checks
/// that on every call. The surname is asked first because that is how a missing
/// employee is usually known ("NAKATO" is on the door); email is the account.
class _AddAdminSheet extends StatefulWidget {
  const _AddAdminSheet({required this.token, required this.deptOptions});

  final String token;
  final List<RefItem> deptOptions;

  @override
  State<_AddAdminSheet> createState() => _AddAdminSheetState();
}

class _AddAdminSheetState extends State<_AddAdminSheet> {
  final _surname = TextEditingController();
  final _givenNames = TextEditingController();
  final _email = TextEditingController();
  String _departmentId = '';
  String _departmentTyped = '';
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _surname.dispose();
    _givenNames.dispose();
    _email.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (_sending) return;
    final surname = _surname.text.trim();
    final given = _givenNames.text.trim();
    final fullName = [given, surname].where((s) => s.isNotEmpty).join(' ');
    final email = _email.text.trim();
    if (fullName.isEmpty || email.isEmpty) {
      setState(() => _error = 'Both the name and the email are required.');
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    final message = await const PortalClient().monitorAddAdmin(
      widget.token,
      fullName,
      email,
      _departmentTyped.trim(),
    );
    if (!mounted) return;
    // A created account says so (and carries the first-login word); anything else
    // is the server's refusal, shown verbatim.
    Navigator.of(context).pop(message);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Add an administrator',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Creates an account they sign in with. Nothing here edits or '
              'removes anyone — this is add-only, and the backend enforces it.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _surname,
              enabled: !_sending,
              decoration: const InputDecoration(
                labelText: 'Surname',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _givenNames,
              enabled: !_sending,
              decoration: const InputDecoration(
                labelText: 'Other names',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _email,
              enabled: !_sending,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                labelText: 'Email address',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            PickOrType(
              label: 'Department (optional)',
              options: widget.deptOptions,
              selectedId: _departmentId,
              typed: _departmentTyped,
              onPick: (item) => setState(() {
                _departmentId = item?.id ?? '';
                _departmentTyped = item?.label ?? '';
              }),
              onType: (v) => setState(() {
                _departmentTyped = v;
                _departmentId = '';
              }),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: _sending ? null : _create,
                    child: Text(_sending ? 'Creating…' : 'Create account'),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: _sending
                      ? null
                      : () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
