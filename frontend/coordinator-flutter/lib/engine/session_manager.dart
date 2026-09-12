enum SessionState { idle, pendingLecturer, active, closing, closed }

class SessionManager {
  final String sessionId;
  final int Function() nowMillis;

  SessionManager(this.sessionId, {int Function()? nowMillis})
      : nowMillis = nowMillis ?? _defaultNowMillis;

  static int _defaultNowMillis() => DateTime.now().millisecondsSinceEpoch;

  static const int checkinWindowMin = 120;
  static const int forceCloseMin = 180;

  SessionState _state = SessionState.idle;
  int _startedAtMs = 0;
  int _gateOpenAtMs = 0;
  int _closedAtMs = 0;

  SessionState get state => _state;
  int get startedAtMs => _startedAtMs;
  int get gateOpenAtMs => _gateOpenAtMs;
  int get closedAtMs => _closedAtMs;

  void open() {
    if (_state != SessionState.idle) {
      throw StateError('session already started');
    }
    _state = SessionState.pendingLecturer;
    _startedAtMs = nowMillis();
  }

  void lecturerStarted() {
    if (_state != SessionState.pendingLecturer) {
      throw StateError('not awaiting lecturer');
    }
    _state = SessionState.active;
    _gateOpenAtMs = nowMillis();
  }

  bool checkinOpen() =>
      _state == SessionState.active &&
      nowMillis() < _gateOpenAtMs + checkinWindowMin * 60000;

  void beginClose() {
    if (_state == SessionState.active) {
      _state = SessionState.closing;
    }
  }

  void close() {
    _state = SessionState.closed;
    _closedAtMs = nowMillis();
  }

  bool tickAutoExpiry() {
    if (_state == SessionState.closed) return false;
    if (_startedAtMs > 0 && nowMillis() >= _startedAtMs + forceCloseMin * 60000) {
      close();
      return true;
    }
    return false;
  }
}