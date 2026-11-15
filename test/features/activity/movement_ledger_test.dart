import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:walkathan/features/activity/movement_ledger.dart';
import 'package:walkathan/features/activity/movement_rules.dart';

const _mPerDeg = 111320.0;
final _t0 = DateTime(2026, 11, 1, 10);

MovementFix _fix(int sec, double eastM, {double northM = 0, double acc = 8, double? speed}) => MovementFix(
    speedMps: speed,
    tMs: _t0.add(Duration(seconds: sec)).millisecondsSinceEpoch,
    lat: northM / _mPerDeg,
    lon: eastM / _mPerDeg,
    accuracyM: acc);

DateTime _at(int sec) => _t0.add(Duration(seconds: sec));

/// Person walking east at [speed] m/s, one fix every [every] seconds.
void _walk(MovementLedger l, int fromSec, int toSec, {double speed = 1.3, int every = 4, double startM = 0}) {
  for (var s = fromSec; s <= toSec; s += every) {
    l.onFix(_fix(s, startM + (s - fromSec) * speed));
  }
}

void main() {
  test('walking is moving, nothing is stationary', () {
    final l = MovementLedger();
    _walk(l, 0, 300);
    expect(l.stationaryFraction(_at(10), _at(300)), 0);
    expect(l.stationaryAt(_at(301)), isFalse);
    expect(l.stationaryIn(TimeSpan(_at(0), _at(300))), isEmpty);
  });

  test('standing still and shaking: tracker alive, never moves => all stationary', () {
    final l = MovementLedger();
    // phone on the spot: tiny GPS jitter, heartbeats every 30 s
    final rnd = math.Random(1);
    for (var s = 0; s <= 600; s += 5) {
      l.onFix(_fix(s, rnd.nextDouble() * 6 - 3, northM: rnd.nextDouble() * 6 - 3, acc: 10));
      if (s % 30 == 0) l.heartbeat(_at(s));
    }
    expect(l.stationaryFraction(_at(0), _at(600)), greaterThan(0.95));
    expect(l.stationaryAt(_at(601)), isTrue);
  });

  test('slow GPS drift of 15 m over 90 s is not travel', () {
    final l = MovementLedger();
    for (var s = 0; s <= 300; s += 10) {
      // drifts 1.5 m every 10 s = 0.15 m/s
      l.onFix(_fix(s, s * 0.15));
    }
    expect(l.stationaryFraction(_at(0), _at(300)), greaterThan(0.9));
  });

  test('a slow stroll (0.8 m/s) still counts', () {
    final l = MovementLedger();
    _walk(l, 0, 300, speed: 0.8, every: 5);
    expect(l.stationaryFraction(_at(20), _at(300)), lessThan(0.05));
  });

  test('stand 10 min, then walk: the standing is removed, the walk counts', () {
    final l = MovementLedger();
    for (var s = 0; s <= 600; s += 30) {
      l.onFix(_fix(s, 0));
    }
    _walk(l, 620, 900, startM: 0);
    final stood = l.stationaryFraction(_at(0), _at(600));
    final walked = l.stationaryFraction(_at(640), _at(900));
    expect(stood, greaterThan(0.95));
    expect(walked, lessThan(0.05));
  });

  test('a 20 s pause while walking is tolerated', () {
    final l = MovementLedger();
    _walk(l, 0, 120);
    // stop for 20 s at 156 m, then continue
    _walk(l, 140, 260, startM: 156);
    expect(l.stationaryFraction(_at(0), _at(260)), lessThan(0.1));
  });

  test('no tracker coverage is unknown, never penalised', () {
    final l = MovementLedger();
    expect(l.stationaryFraction(_at(0), _at(600)), 0);
    expect(l.stationaryAt(_at(100)), isFalse);
    _walk(l, 0, 120);
    // two hours later, tracker was not running
    expect(l.stationaryFraction(_at(3600), _at(7200)), 0);
    expect(l.stationaryAt(_at(7200)), isFalse);
  });

  test('vehicle speed is not walking', () {
    final l = MovementLedger();
    for (var s = 0; s <= 120; s += 4) {
      l.onFix(_fix(s, s * 20.0)); // 20 m/s
    }
    expect(l.stationaryFraction(_at(20), _at(120)), greaterThan(0.9));
  });

  test('no usable GPS signal (indoors) is UNKNOWN: steps keep counting', () {
    final l = MovementLedger();
    // ten minutes of weak fixes that never move, as inside a building
    for (var s = 0; s <= 600; s += 5) {
      l.onFix(_fix(s, 0, acc: 45));
    }
    expect(l.alive, isEmpty, reason: 'a weak fix proves nothing');
    expect(l.stationaryFraction(_at(0), _at(600)), 0);
    expect(l.stationaryAt(_at(601)), isFalse);
  });

  test('signal lost after a clear stretch: only the clear stretch is judged', () {
    final l = MovementLedger();
    for (var s = 0; s <= 120; s += 5) {
      l.onFix(_fix(s, 0)); // clear, not moving
    }
    for (var s = 125; s <= 600; s += 5) {
      l.onFix(_fix(s, 0, acc: 80)); // walked indoors: signal gone
    }
    expect(l.stationaryFraction(_at(0), _at(120)), greaterThan(0.9));
    expect(l.stationaryFraction(_at(200), _at(600)), 0);
    expect(l.stationaryAt(_at(600)), isFalse);
  });

  test('walking around a room: a confident Wi-Fi position that never moves is not "standing still"', () {
    final l = MovementLedger();
    // Android indoors: ~15 m accuracy from Wi-Fi, same spot for ten minutes
    for (var s = 0; s <= 600; s += 5) {
      l.onFix(_fix(s, 0, acc: 15));
    }
    expect(l.stationaryFraction(_at(0), _at(600)), 0, reason: 'steps must keep counting');
    expect(l.stationaryAt(_at(601)), isFalse);
  });

  test('pacing in a small area outdoors counts, from the GPS speed', () {
    final l = MovementLedger();
    // back and forth within 6 m: never 12 m from the start, but clearly walking
    for (var s = 0; s <= 300; s += 5) {
      l.onFix(_fix(s, (s ~/ 5).isEven ? 0 : 6, speed: 1.2));
    }
    expect(l.stationaryFraction(_at(10), _at(300)), lessThan(0.05));
    expect(l.stationaryAt(_at(301)), isFalse);
  });

  test('shaking outdoors: clear fix, no speed, no travel => still blocked', () {
    final l = MovementLedger();
    for (var s = 0; s <= 300; s += 5) {
      l.onFix(_fix(s, 0, acc: 5, speed: 0.1));
    }
    expect(l.stationaryFraction(_at(0), _at(300)), greaterThan(0.95));
    expect(l.stationaryAt(_at(301)), isTrue);
  });

  test('inaccurate fixes are ignored', () {
    final l = MovementLedger();
    for (var s = 0; s <= 120; s += 4) {
      l.onFix(_fix(s, s * 1.3, acc: 120));
    }
    expect(l.moving, isEmpty);
  });

  test('stationaryAt needs the tracker to have run a while', () {
    final l = MovementLedger();
    l.onFix(_fix(0, 0));
    expect(l.stationaryAt(_at(10)), isFalse, reason: 'just started: unsure');
    for (var s = 30; s <= 120; s += 30) {
      l.heartbeat(_at(s));
    }
    expect(l.stationaryAt(_at(125)), isTrue);
    expect(l.stationaryAt(_at(400)), isFalse, reason: 'tracker stopped: unsure');
  });

  test('persists and restores', () {
    final l = MovementLedger();
    _walk(l, 0, 100);
    final back = MovementLedger.decode(l.encode());
    expect(back.moving.length, l.moving.length);
    expect(back.alive.length, l.alive.length);
    expect(back.anchor?.tMs, l.anchor?.tMs);
    expect(MovementLedger.decode('garbage{').moving, isEmpty);
    expect(MovementLedger.decode(null).alive, isEmpty);
  });

  test('distanceMeters is sane', () {
    expect(distanceMeters(0, 0, 0, 0), 0);
    expect(distanceMeters(0, 0, 0, 100 / _mPerDeg), closeTo(100, 0.5));
  });
}
