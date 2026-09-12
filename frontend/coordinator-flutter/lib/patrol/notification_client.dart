import '../net/net.dart';

/// One notification as the server sends it (`/api/v1/app-notifications`).
class Notif {
  const Notif({
    required this.id,
    this.senderName = '',
    this.senderRole = '',
    this.subject = '',
    this.body = '',
    this.createdAt = '',
    this.read = false,
  });

  factory Notif.fromJson(Map<String, dynamic> o) => Notif(
    id: (o['notification_id'] ?? '') as String,
    senderName: (o['sender_name'] ?? '') as String,
    senderRole: (o['sender_role'] ?? '') as String,
    subject: (o['subject'] ?? '') as String,
    body: (o['body'] ?? '') as String,
    createdAt: (o['created_at'] ?? '') as String,
    read: (o['read'] ?? false) as bool,
  );

  final String id;
  final String senderName;
  final String senderRole;
  final String subject;
  final String body;
  final String createdAt;
  final bool read;
}

/// Cross-role in-app notifications over the cloud API (online) — a faithful port
/// of the native `NotificationClient`. The monitor's Alerts tab reads its inbox
/// here; there is deliberately no composer (a monitor reports by ticking a round,
/// not by messaging staff directly).
class NotificationClient {
  const NotificationClient();

  Future<List<Notif>> inbox(String token) async {
    if (token.isEmpty) return const [];
    try {
      final o =
          await Net.getJson('/api/v1/app-notifications', token: token) as List;
      return o.whereType<Map<String, dynamic>>().map(Notif.fromJson).toList();
    } on Object {
      return const [];
    }
  }

  Future<int> unread(String token) async {
    if (token.isEmpty) return 0;
    try {
      final o = await Net.getJson(
        '/api/v1/app-notifications/unread-count',
        token: token,
      ) as Map<String, dynamic>;
      return ((o['unread'] ?? 0) as num).toInt();
    } on Object {
      return 0;
    }
  }

  /// Dismiss from MY inbox (the ✕ on an alert). Returns null on success — 404 also
  /// counts (already gone), and a refusal says WHY rather than silently undoing.
  Future<String?> dismiss(String token, String id) async {
    if (token.isEmpty) return 'Not signed in';
    try {
      final r = await Net.retrying(
        () => Net.shared.delete(
          Uri.parse('${Net.baseUrl}/api/v1/app-notifications/$id'),
          headers: {'Authorization': 'Bearer $token'},
        ),
      );
      if (r.statusCode >= 200 && r.statusCode < 300 || r.statusCode == 404) {
        return null;
      }
      if (r.statusCode == 401 || r.statusCode == 403) {
        return "You're not allowed to clear this alert.";
      }
      return "Couldn't clear it (${r.statusCode}). Try again.";
    } on Object {
      return "Couldn't reach the server — the alert will come back until you're online.";
    }
  }

  Future<void> markRead(String token, String id) async {
    if (token.isEmpty) return;
    try {
      await Net.retrying(
        () => Net.shared.post(
          Uri.parse('${Net.baseUrl}/api/v1/app-notifications/$id/read'),
          headers: {'Authorization': 'Bearer $token'},
        ),
      );
    } on Object {
      // Best-effort: the alert stays bold until the next successful read.
    }
  }
}

/// Outcome of one send: [error] explains a refusal (display verbatim — a message
/// the monitor sent to nobody must SAY it went to nobody), and [recipients] is the
/// count the server reported back on success.
class SendOutcome {
  const SendOutcome({this.error, this.recipients});
  final String? error;
  final int? recipients;
}

/// Compose half of in-app notifications — [NotificationClient] above is the inbox.
///
/// The gateway validates the audience against the SENDER'S role, then returns how
/// many active accounts actually got it; the composer shows that number so "sent"
/// is never mistaken for "delivered to many".
extension NotificationSender on NotificationClient {
  Future<SendOutcome> send(
    String token, {
    required String audience,
    String? targetId,
    required String subject,
    required String body,
  }) async {
    if (token.isEmpty) return const SendOutcome(error: 'Not signed in');
    try {
      final o = await Net.postJson(
        '/api/v1/app-notifications',
        token: token,
        body: {
          'audience': audience,
          if (targetId != null && targetId.isNotEmpty) 'target_id': targetId,
          'subject': subject.trim(),
          'body': body.trim(),
        },
      );
      if (o is Map<String, dynamic>) {
        final n = o['recipients'];
        return SendOutcome(recipients: n is num ? n.toInt() : null);
      }
      return const SendOutcome();
    } on NetFailure catch (e) {
      return SendOutcome(error: e.message);
    } on Object {
      return const SendOutcome(
        error: "Couldn't reach the server — your message wasn't sent.",
      );
    }
  }
}
