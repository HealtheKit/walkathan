/// Live step display between syncs.
///
/// Two phone signals keep the number moving:
///  * the step COUNTER (cumulative, accurate, but it reports in small
///    batches, often only after the first ~10 steps), and
///  * the step DETECTOR (Android: one event per step, almost instant).
///
/// Each detected step shows at once as a "pending" step. When the counter
/// catches up it confirms them: pending steps are swapped for counted ones,
/// so a step is never shown twice and the number never jumps back.
///
/// Display only. The server total stays the authority (it applies the
/// valid-step rules); after each sync the overlay keeps only the live steps
/// the new total does not yet include, so a downward correction (for example
/// a cycling session being excluded) is never hidden.
class LiveStepOverlay {
  LiveStepOverlay({this.pendingTtl = const Duration(seconds: 15)});

  /// Detected steps the counter has not confirmed within this time are
  /// dropped (the detector occasionally fires on a shake).
  final Duration pendingTtl;

  int? _base; // counter value at the last sync / first reading
  int? _last; // most recent counter value
  int _carry = 0; // counted steps the synced total has not caught up with yet
  int _pending = 0; // detected, not yet counted
  DateTime? _lastDetectedAt;

  int get _counted => (_last ?? 0) - (_base ?? _last ?? 0);

  /// Extra steps to show on top of the synced total.
  int get extra => _carry + _counted + _pending;

  /// Feed a cumulative counter reading. Returns the new [extra].
  ///
  /// [countable] is false while GPS shows the phone is standing still: the
  /// steps in this reading came from shaking, so they are skipped.
  int onCounter(int counter, {DateTime? now, bool countable = true}) {
    now ??= DateTime.now();
    if (_base == null || _last == null) {
      // First reading: start counting from here. Steps detected just before
      // it are already inside this value, so they are dropped rather than
      // counted twice (Android reports right after connecting, so this is
      // at most a step or two).
      _base = counter;
      _last = counter;
      _pending = 0;
      return extra;
    }
    if (counter < _last!) {
      // The phone rebooted (the counter restarts at 0): keep what was
      // counted so far; every step in the new value is new.
      _carry += _counted;
      _base = 0;
      _last = counter;
      _pending = 0;
      return extra;
    }
    final advance = counter - _last!;
    _last = counter;
    if (!countable) {
      // Move the baseline with the counter so these steps never show up.
      _base = (_base ?? counter) + advance;
      _pending = 0;
      return extra;
    }
    // Counted steps replace the detected ones they confirm.
    _pending = advance >= _pending ? 0 : _pending - advance;
    final seen = _lastDetectedAt;
    if (_pending > 0 && (seen == null || now.difference(seen) > pendingTtl)) {
      _pending = 0;
    }
    return extra;
  }

  /// One step from the step detector. Returns the new [extra].
  int onDetectedStep({DateTime? now}) {
    now ??= DateTime.now();
    final seen = _lastDetectedAt;
    if (_pending > 0 && seen != null && now.difference(seen) > pendingTtl) {
      _pending = 0; // stale, never confirmed
    }
    _lastDetectedAt = now;
    _pending++;
    return extra;
  }

  /// Call when a sync finishes. [oldTotal] is the synced total shown before,
  /// [newTotal] the one just received. Pending (detected) steps are never
  /// part of a sync, so they stay as they are.
  void onSynced({required int oldTotal, required int newTotal}) {
    final countedNow = _carry + _counted;
    final missing = oldTotal + countedNow - newTotal; // not in the new total
    _carry = missing <= 0 ? 0 : (missing > countedNow ? countedNow : missing);
    _base = _last;
  }

  void reset() {
    _base = null;
    _last = null;
    _carry = 0;
    _pending = 0;
    _lastDetectedAt = null;
  }
}
