import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lottie/lottie.dart';
import 'package:walkathan/pages/widgets/brand_animation.dart';
import 'package:walkathan/pages/widgets/infographics.dart';

void main() {
  for (final k in BrandAnimationKind.values) {
    test('${k.name}: valid Lottie, 200x200, short, small', () async {
      final bytes = File(k.asset).readAsBytesSync();
      final comp = await LottieComposition.fromBytes(bytes);
      expect(comp.bounds.width, 200);
      expect(comp.bounds.height, 200);
      expect(comp.duration.inMilliseconds, inInclusiveRange(1000, 1600));
      expect(bytes.length, lessThan(16 * 1024));
    });
  }

  for (final reduce in [false, true]) {
    testWidgets('BrandAnimation renders (reduce motion: $reduce)', (tester) async {
      await tester.runAsync(() async {
        await tester.pumpWidget(MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: reduce),
            child: const Column(children: [
              BrandAnimation(BrandAnimationKind.goalReached),
              BrandAnimation(BrandAnimationKind.walker, semanticLabel: 'Walking'),
            ]),
          ),
        ));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
      expect(find.bySemanticsLabel('Walking'), findsOneWidget);
      expect(find.byType(Lottie), findsNWidgets(2));
    });
  }

  testWidgets('ProgressRing and DonutChart animate to their values', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Column(children: [
          ProgressRing(value: 0.6, size: 80),
          DonutChart(segments: [
            DonutSegment(3, Colors.green, 'Walked today'),
            DonutSegment(1, Colors.blue, 'Not started'),
          ]),
        ]),
      ),
    ));
    await tester.pumpAndSettle();
    final ring = tester.widget<CircularProgressIndicator>(find.byType(CircularProgressIndicator));
    expect(ring.value, closeTo(0.6, 1e-9));
    expect(find.text('Walked today  3 (75%)'), findsOneWidget);
    expect(find.bySemanticsLabel('Walked today: 3, Not started: 1'), findsOneWidget);
  });
}
