import 'models.dart';

abstract class Store {
  DeviceBinding? bindingByFingerprint(String fingerprintHash);

  DeviceBinding? bindingByStudent(String studentIdHash);

  void putBinding(DeviceBinding binding);

  bool hasAttendance(String sessionId, String studentIdHash);

  bool deviceUsedByOther(String sessionId, String fingerprintHash, String studentIdHash);

  int attendanceCount(String sessionId);

  void addAttendance(AttendanceRecord record);
}

class InMemoryStore implements Store {
  final List<DeviceBinding> _bindings = [];
  final List<AttendanceRecord> _attendance = [];

  @override
  DeviceBinding? bindingByFingerprint(String fingerprintHash) {
    for (final b in _bindings) {
      if (b.fingerprintHash == fingerprintHash) return b;
    }
    return null;
  }

  @override
  DeviceBinding? bindingByStudent(String studentIdHash) {
    for (final b in _bindings) {
      if (b.studentIdHash == studentIdHash) return b;
    }
    return null;
  }

  @override
  void putBinding(DeviceBinding binding) {
    _bindings
        .removeWhere((b) => b.studentIdHash == binding.studentIdHash);
    _bindings.add(binding);
  }

  @override
  bool hasAttendance(String sessionId, String studentIdHash) =>
      _attendance.any((r) =>
          r.sessionId == sessionId && r.studentIdHash == studentIdHash);

  @override
  bool deviceUsedByOther(String sessionId, String fingerprintHash, String studentIdHash) =>
      _attendance.any((r) =>
          r.sessionId == sessionId &&
          r.deviceFingerprintHash == fingerprintHash &&
          r.studentIdHash != studentIdHash);

  @override
  int attendanceCount(String sessionId) =>
      _attendance.where((r) => r.sessionId == sessionId).length;

  @override
  void addAttendance(AttendanceRecord record) {
    _attendance.add(record);
  }

  List<AttendanceRecord> all() => List.unmodifiable(_attendance);
}