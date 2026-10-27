import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huntingdogs/huntingdogs.dart';

Future<T> _settle<T>(WidgetTester tester, Future<T> future) async {
  var done = false;
  future.then<void>(
    (_) => done = true,
    onError: (Object _, StackTrace __) => done = true,
  );
  for (var i = 0; i < 80 && !done; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  if (!done) throw TestFailure('Scroll did not settle');
  return future;
}

void main() {
  testWidgets('point scrolling selects the owner for the requested axis', (
    tester,
  ) async {
    late OperatorApp app;
    final vertical = ScrollController();
    final horizontal = ScrollController();
    const listKey = ValueKey('horizontal-list');
    await tester.pumpWidget(
      OperatorAppHost(
        config: const OperatorFlutterConfig(
          appId: 'nested-scroll-fixture',
          environment: OperatorEnvironment.dev,
        ),
        onReady: (ready) => app = ready,
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              controller: vertical,
              child: Column(
                children: [
                  const SizedBox(height: 50),
                  SizedBox(
                    height: 180,
                    width: 350,
                    child: ListView.builder(
                      key: listKey,
                      controller: horizontal,
                      scrollDirection: Axis.horizontal,
                      itemExtent: 60,
                      itemCount: 80,
                      itemBuilder: (_, i) => Text('Horizontal $i'),
                    ),
                  ),
                  const SizedBox(height: 1400),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final point = tester.getCenter(find.byKey(listKey));
    final inspector =
        app.binding.adapter.actuator as OperatorFlutterPointInspector;
    Future<ActionResult> scroll(String direction) async {
      await app.operator.getSnapshot(
        refreshVisual: false,
        refreshStorageProviders: false,
      );
      final found = inspector.inspectPoint(
        point.dx,
        point.dy,
        scrollDirection: direction,
      );
      expect(found['status'], 'found');
      final control = found['control'] as Map;
      final ref = control['observationTargetRef'] as Map;
      return _settle(
        tester,
        app.binding.adapter.execute(
          ActionCommand(
            type: OperatorActionType.scroll,
            direction: direction,
            amount: '100',
            deliveryId: direction,
            container: ElementTarget(
              id: control['id'] as String,
              point: FallbackPoint(x: point.dx, y: point.dy),
              observationTargetRef: FlutterObservationTargetRef(
                ticketId: ref['ticketId'] as String,
                snapshotId: ref['snapshotId'] as String,
              ),
            ),
          ),
        ),
      );
    }

    final right = await scroll('right');
    expect(right.ok, true, reason: right.error?.message);
    expect(horizontal.offset, 100);
    expect(vertical.offset, 0);
    final down = await scroll('down');
    expect(down.ok, true, reason: down.error?.message);
    expect(vertical.offset, 100);
    expect(horizontal.offset, 100);
    expect(
      (right.data as Map)['scroll']['ownerId'],
      isNot((down.data as Map)['scroll']['ownerId']),
    );
    await tester.pumpWidget(const SizedBox());
    horizontal.dispose();
    vertical.dispose();
  });
  for (final reverse in [false, true]) {
    testWidgets(
      'point scroll moves only the front list and measures the edge, reverse=$reverse',
      (tester) async {
        late OperatorApp app;
        late StateSetter rebuild;
        final behind = ScrollController();
        final front = ScrollController();
        var covered = false;
        const frontKey = ValueKey('front-list');
        await tester.pumpWidget(
          OperatorAppHost(
            config: const OperatorFlutterConfig(
              appId: 'scroll-owner-fixture',
              environment: OperatorEnvironment.dev,
            ),
            onReady: (ready) => app = ready,
            child: MaterialApp(
              home: Scaffold(
                body: StatefulBuilder(
                  builder: (context, setState) {
                    rebuild = setState;
                    return Stack(
                      children: [
                        ListView.builder(
                          controller: behind,
                          itemExtent: 60,
                          itemCount: 80,
                          itemBuilder: (_, i) => Text('Behind $i'),
                        ),
                        Positioned(
                          left: 100,
                          top: 100,
                          width: 350,
                          height: 300,
                          child: Material(
                            child: ListView.builder(
                              key: frontKey,
                              controller: front,
                              reverse: reverse,
                              itemExtent: 60,
                              itemCount: 80,
                              itemBuilder: (_, i) => Text('Front $i'),
                            ),
                          ),
                        ),
                        if (covered)
                          const Positioned(
                            left: 100,
                            top: 100,
                            width: 350,
                            height: 300,
                            child: ColoredBox(color: Colors.white),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        front.jumpTo(500);
        await tester.pumpAndSettle();
        final inspector =
            app.binding.adapter.actuator as OperatorFlutterPointInspector;
        final point = tester.getCenter(find.byKey(frontKey));
        Future<ElementTarget> observeTarget() async {
          await app.operator.getSnapshot(
            refreshVisual: false,
            refreshStorageProviders: false,
          );
          final found = inspector.inspectPoint(
            point.dx,
            point.dy,
            scrollDirection: 'down',
          );
          expect(found['status'], 'found');
          final control = found['control'] as Map;
          final ref = control['observationTargetRef'] as Map;
          return ElementTarget(
            id: control['id'] as String,
            point: FallbackPoint(x: point.dx, y: point.dy),
            observationTargetRef: FlutterObservationTargetRef(
              ticketId: ref['ticketId'] as String,
              snapshotId: ref['snapshotId'] as String,
            ),
          );
        }

        var target = await observeTarget();
        ActionCommand command(String id) => ActionCommand(
          type: OperatorActionType.scroll,
          direction: 'down',
          amount: '300',
          container: target,
          deliveryId: id,
        );
        final encoded =
            operatorActionResultToJson(
                  ActionResult(ok: true, action: command('first')),
                )['action']
                as JsonMap;
        final decoded = operatorActionCommandFromJson(encoded);
        expect(decoded.container!.point!.x, point.dx);
        final result = await _settle(
          tester,
          app.binding.adapter.execute(decoded),
        );
        expect(result.ok, true, reason: result.error?.message);
        expect(front.offset, reverse ? 200 : 800);
        expect(behind.offset, 0);
        final facts = (result.data as Map)['scroll'] as Map;
        expect(facts['before'], 500);
        expect(facts['after'], front.offset);
        expect(facts['outcome'], 'moved');
        final replay = await _settle(
          tester,
          app.binding.adapter.execute(decoded),
        );
        expect(replay.ok, true);
        expect(
          front.offset,
          reverse ? 200 : 800,
          reason: 'Replay must not scroll again',
        );

        front.jumpTo(
          reverse
              ? front.position.minScrollExtent
              : front.position.maxScrollExtent,
        );
        await tester.pumpAndSettle();
        target = await observeTarget();
        final edge = await _settle(
          tester,
          app.binding.adapter.execute(command('edge')),
        );
        expect(edge.ok, true, reason: edge.error?.message);
        expect((edge.data as Map)['scroll']['outcome'], 'boundary');
        expect((edge.data as Map)['scroll']['delta'], 0);
        expect(
          behind.offset,
          0,
          reason: 'Boundary cannot fall through to the background list',
        );

        target = await observeTarget();
        rebuild(() => covered = true);
        await tester.pumpAndSettle();
        final rejected = await _settle(
          tester,
          app.binding.adapter.execute(command('covered')),
        );
        expect(rejected.ok, false);
        expect((rejected.data as Map)['operationPhase'], 'zero_dispatch');
        expect(behind.offset, 0);
        await tester.pumpWidget(const SizedBox());
        front.dispose();
        behind.dispose();
      },
    );
  }
}
