import 'package:coordinator_flutter/engine/lecturer_gate.dart';
import 'package:coordinator_flutter/engine/room_code.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final secret = 'gate-secret'.codeUnits;
  const t = 1782604800;
  final code = RoomCode.derive(secret, t);
  final gate = LecturerGate(nowSeconds: () => t);

  LecturerGateContext ctx({
    GateState state = GateState.notStarted,
    int attended = 0,
    int enrolled = 0,
    double ratio = 0.5,
    String? staff = 'KIU/STAFF/001',
    bool bio = false,
  }) =>
      LecturerGateContext(
        assignedStaffId: staff,
        roomCodeSecret: secret,
        gateState: state,
        attended: attended,
        enrolled: enrolled,
        ratio: ratio,
        requireBiometric: bio,
      );

  test('START on a valid first scan', () {
    final r = gate.evaluate('KIU/STAFF/001', code, false, ctx());
    expect(r.ok, isTrue);
    expect(r.action, GateAction.start);
  });

  test('no staff id registered', () {
    final r = gate.evaluate('KIU/STAFF/001', code, false, ctx(staff: ' '));
    expect(r.ok, isFalse);
    expect(r.rejection, GateRejection.noStaffId);
  });

  test('staff id mismatch', () {
    final r = gate.evaluate('KIU/STAFF/999', code, false, ctx());
    expect(r.rejection, GateRejection.staffIdMismatch);
  });

  test('bad room code', () {
    final r = gate.evaluate('KIU/STAFF/001', '000000', false, ctx());
    expect(r.rejection, GateRejection.badRoomCode);
  });

  test('biometric required when enrolled', () {
    final misses = gate.evaluate('KIU/STAFF/001', code, false, ctx(bio: true));
    expect(misses.rejection, GateRejection.biometricRequired);
    final passes = gate.evaluate('KIU/STAFF/001', code, true, ctx(bio: true));
    expect(passes.action, GateAction.start);
  });

  test('END with quorum met', () {
    final r = gate.evaluate('KIU/STAFF/001', code, false, ctx(state: GateState.started, attended: 30, enrolled: 60));
    expect(r.ok, isTrue);
    expect(r.action, GateAction.end);
    expect(r.requiredQuorum, 30);
  });

  test('END without quorum', () {
    final r = gate.evaluate('KIU/STAFF/001', code, false, ctx(state: GateState.started, attended: 29, enrolled: 60));
    expect(r.rejection, GateRejection.noQuorum);
    expect(r.requiredQuorum, 30);
  });

  test('quorum floor is 1', () {
    final r = gate.evaluate('KIU/STAFF/001', code, false, ctx(state: GateState.started, attended: 1, enrolled: 0));
    expect(r.ok, isTrue);
    expect(r.action, GateAction.end);
  });

  test('already ended', () {
    final r = gate.evaluate('KIU/STAFF/001', code, false, ctx(state: GateState.ended, attended: 60, enrolled: 60));
    expect(r.rejection, GateRejection.alreadyEnded);
  });
}