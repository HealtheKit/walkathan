import 'package:flutter_test/flutter_test.dart';
import 'package:walkathan/features/activity/live_overlay.dart';

void main() {
  gpsOverlayTests();
  test('first reading is a baseline; later readings add live steps', () {
    final o = LiveStepOverlay();
    expect(o.onCounter(5000), 0);
    expect(o.onCounter(5012), 12);
    expect(o.onCounter(5040), 40);
  });

  test('sync that includes the live steps resets the overlay', () {
    final o = LiveStepOverlay()..onCounter(100)..onCounter(160);
    o.onSynced(oldTotal: 2000, newTotal: 2060);
    expect(o.extra, 0);
    expect(o.onCounter(170), 10);
  });

  test('a lagging health total keeps the live steps on screen (no jump back)', () {
    final o = LiveStepOverlay()..onCounter(100)..onCounter(160); // +60 live
    o.onSynced(oldTotal: 2000, newTotal: 2020); // store only caught 20 of them
    expect(o.extra, 40);
    expect(2020 + o.extra, 2060); // same number as before the sync
    o.onCounter(175);
    expect(o.extra, 55);
    o.onSynced(oldTotal: 2020, newTotal: 2075); // store caught up
    expect(o.extra, 0);
  });

  test('a downward correction is shown: carry never exceeds live steps', () {
    final o = LiveStepOverlay()..onCounter(100)..onCounter(130); // +30 live
    // a cycling session was excluded: total drops by 1,450
    o.onSynced(oldTotal: 5000, newTotal: 3550);
    expect(o.extra, 30);
    expect(3550 + o.extra, lessThan(5000));
  });

  test('reboot (counter restarts at 0) keeps earlier live steps', () {
    final o = LiveStepOverlay()..onCounter(9000)..onCounter(9050);
    expect(o.onCounter(12), 62); // 50 before the reboot + 12 after
    expect(o.onCounter(30), 80);
  });

  group('step detector', () {
    final t0 = DateTime(2026, 11, 15, 9);
    DateTime at(int s) => t0.add(Duration(seconds: s));

    test('5 steps show as 5 immediately, before the counter reports', () {
      final o = LiveStepOverlay()..onCounter(1000, now: at(0));
      for (var i = 1; i <= 5; i++) {
        expect(o.onDetectedStep(now: at(i)), i);
      }
    });

    test('counter confirms detected steps without double counting', () {
      final o = LiveStepOverlay()..onCounter(1000, now: at(0));
      for (var i = 1; i <= 12; i++) {
        o.onDetectedStep(now: at(i));
      }
      expect(o.extra, 12);
      expect(o.onCounter(1010, now: at(12)), 12); // 10 counted + 2 pending
      expect(o.onCounter(1012, now: at(13)), 12); // all confirmed
      expect(o.onCounter(1015, now: at(14)), 15); // counter ahead: trust it
    });

    test('number never drops when the counter lags the detector', () {
      final o = LiveStepOverlay()..onCounter(0, now: at(0));
      var shown = 0;
      for (var i = 1; i <= 30; i++) {
        final v = o.onDetectedStep(now: at(i));
        expect(v, greaterThanOrEqualTo(shown));
        shown = v;
        if (i % 7 == 0) {
          final c = o.onCounter(i - 3, now: at(i)); // counter 3 steps behind
          expect(c, greaterThanOrEqualTo(shown));
          shown = c;
        }
      }
    });

    test('unconfirmed detector steps expire', () {
      final o = LiveStepOverlay()..onCounter(500, now: at(0));
      o.onDetectedStep(now: at(1));
      o.onDetectedStep(now: at(2));
      expect(o.extra, 2);
      expect(o.onCounter(500, now: at(40)), 0); // shake, not steps
    });

    test('pending steps survive a sync; counted ones go to the total', () {
      final o = LiveStepOverlay()..onCounter(100, now: at(0));
      o.onCounter(120, now: at(5)); // 20 counted
      o.onDetectedStep(now: at(6));
      o.onDetectedStep(now: at(7)); // 2 pending
      o.onSynced(oldTotal: 3000, newTotal: 3020);
      expect(o.extra, 2);
      expect(o.onCounter(122, now: at(8)), 2); // confirmed, still 2
    });
  });

  test('reset clears everything', () {
    final o = LiveStepOverlay()..onCounter(1)..onCounter(50);
    o.reset();
    expect(o.extra, 0);
    expect(o.onCounter(500), 0);
  });
}

void gpsOverlayTests() {
  test('counter advances while standing still are never shown', () {
    final o = LiveStepOverlay();
    o.onCounter(1000); // baseline
    expect(o.onCounter(1010), 10);
    expect(o.onCounter(1310, countable: false), 10, reason: 'shaken steps skipped');
    expect(o.onCounter(1320), 20, reason: 'walking resumes from the new baseline');
  });
}
