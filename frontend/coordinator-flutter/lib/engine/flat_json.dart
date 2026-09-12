import 'models.dart';

class FlatJson {
  static Map<String, String> parse(String raw) => _Parser(raw).run();

  static SubmittedQr? parseQr(String raw) {
    try {
      final m = parse(raw);
      return SubmittedQr(
        fields: QrFields(
          studentId: m['student_id']!,
          tenantId: m['tenant_id']!,
          courseId: m['course_id']!,
          fullName: m['full_name']!,
          academicYear: m['academic_year']!,
          serialNumber: m['serial_number']!,
          expiryDate: m['expiry_date']!,
          issuedAt: m['issued_at']!,
        ),
        signatureB64: m['signature']!,
      );
    } catch (_) {
      return null;
    }
  }
}

class _Parser {
  final String raw;
  int _i = 0;

  _Parser(this.raw);

  int get _n => raw.length;

  void _skipWs() {
    while (_i < _n && raw[_i].trim().isEmpty) {
      _i++;
    }
  }

  String _readString() {
    _i++;
    final sb = StringBuffer();
    while (_i < _n) {
      final c = raw[_i];
      if (c == r'\' && _i + 1 < _n) {
        final e = raw[_i + 1];
        String chunk;
        switch (e) {
          case '"':
            chunk = '"';
          case r'\':
            chunk = r'\';
          case '/':
            chunk = '/';
          case 'n':
            chunk = '\n';
          case 'r':
            chunk = '\r';
          case 't':
            chunk = '\t';
          case 'b':
            chunk = '\b';
          case 'u':
            final hex = raw.substring(_i + 2, _i + 6);
            _i += 4;
            sb.writeCharCode(int.parse(hex, radix: 16));
            _i += 2;
            continue;
          default:
            chunk = e;
        }
        sb.write(chunk);
        _i += 2;
      } else if (c == '"') {
        _i++;
        return sb.toString();
      } else {
        sb.write(c);
        _i++;
      }
    }
    throw ArgumentError('unterminated string');
  }

  Map<String, String> run() {
    final out = <String, String>{};
    _skipWs();
    if (!(_i < _n && raw[_i] == '{')) {
      throw ArgumentError('expected object');
    }
    _i++;
    while (true) {
      _skipWs();
      if (_i < _n && raw[_i] == '}') {
        _i++;
        break;
      }
      if (!(_i < _n && raw[_i] == '"')) {
        throw ArgumentError('expected key');
      }
      final key = _readString();
      _skipWs();
      if (!(_i < _n && raw[_i] == ':')) {
        throw ArgumentError("expected ':'");
      }
      _i++;
      _skipWs();
      if (!(_i < _n && raw[_i] == '"')) {
        throw ArgumentError('only string values supported');
      }
      out[key] = _readString();
      _skipWs();
      if (_i < _n && raw[_i] == ',') {
        _i++;
        continue;
      }
    }
    return out;
  }
}