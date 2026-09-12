import 'dart:math';

import 'room_code.dart' show RoomCode;

enum GateState { notStarted, started, ended }

enum GateAction { start, end }

enum GateRejection {
  noStaffId,
  staffIdMismatch,
  badRoomCode,
  biometricRequired,
  noQuorum,
  alreadyEnded,
}

class GateResult {
  final bool ok;
  final GateAction? action;
  final GateRejection? rejection;
  final int requiredQuorum;

  const GateResult(this.ok, {this.action, this.rejection, this.requiredQuorum = 0});
}

class LecturerGateContext {
  final String? assignedStaffId;
  final List<int> roomCodeSecret;
  final GateState gateState;
  final int attended;
  final int enrolled;
  final double ratio;
  final bool requireBiometric;

  const LecturerGateContext({
    this.assignedStaffId,
    required this.roomCodeSecret,
    required this.gateState,
    required this.attended,
    required this.enrolled,
    required this.ratio,
    required this.requireBiometric,
  });
}

class LecturerGate {
  final int Function() nowSeconds;

  LecturerGate({int Function()? nowSeconds})
      : nowSeconds = nowSeconds ?? _defaultNowSeconds;

  static int _defaultNowSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  GateResult evaluate(
    String staffId,
    String roomCode,
    bool biometricVerified,
    LecturerGateContext ctx,
  ) {
    final assigned = ctx.assignedStaffId?.trim() ?? '';
    if (assigned.isEmpty) {
      return const GateResult(false, rejection: GateRejection.noStaffId);
    }
    if (staffId.trim() != assigned) {
      return const GateResult(false, rejection: GateRejection.staffIdMismatch);
    }

    if (!RoomCode.validate(ctx.roomCodeSecret, roomCode.trim(), nowSeconds())) {
      return const GateResult(false, rejection: GateRejection.badRoomCode);
    }

    if (ctx.requireBiometric && !biometricVerified) {
      return const GateResult(false, rejection: GateRejection.biometricRequired);
    }

    switch (ctx.gateState) {
      case GateState.notStarted:
        return const GateResult(true, action: GateAction.start);
      case GateState.ended:
        return const GateResult(false, rejection: GateRejection.alreadyEnded);
      case GateState.started:
        final required = max(1, (ctx.ratio * ctx.enrolled).ceil());
        if (ctx.attended < required) {
          return GateResult(false, rejection: GateRejection.noQuorum, requiredQuorum: required);
        }
        return GateResult(true, action: GateAction.end, requiredQuorum: required);
    }
  }
}