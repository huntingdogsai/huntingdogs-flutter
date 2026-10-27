import 'package:flutter_test/flutter_test.dart';
import 'package:huntingdogs/huntingdogs.dart';

const _pngPrefix = 'iVBORw0KGgoAAAANSUhEUgAAAYYAAANM';

VisualFrame _rootFrame(String suffix) => VisualFrame(
      id: 'flutter-root-frame',
      format: 'png',
      width: 390,
      height: 844,
      source: 'repaint_boundary',
      redacted: false,
      encoding: 'base64',
      data: '$_pngPrefix$suffix',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('one frame id is retained once: the newest capture replaces the older one', () async {
    final operator = await OperatorFlutter.init(
      const OperatorFlutterConfig(
        appId: 'visual-retention-test',
        environment: OperatorEnvironment.dev,
      ),
    );
    var providerPixels = 'AAAA';
    operator.addVisualFrameProvider(() async => _rootFrame(providerPixels));
    // The capture layer's own post-frame capture stores the same frame id in its own slot.
    operator.captureVisualFrame(_rootFrame('SSSS'));

    providerPixels = 'BBBB';
    final refreshed = await operator.getSnapshot();
    final frames = refreshed.visual!.frames
        .where((frame) => frame.id == 'flutter-root-frame')
        .toList();
    expect(frames, hasLength(1));
    expect(frames.single.data, '${_pngPrefix}BBBB');

    // And the other direction: a later capture-layer frame replaces the provider's picture.
    operator.captureVisualFrame(_rootFrame('CCCC'));
    final later = await operator.getSnapshot(refreshVisual: false);
    final laterFrames = later.visual!.frames
        .where((frame) => frame.id == 'flutter-root-frame')
        .toList();
    expect(laterFrames, hasLength(1));
    expect(laterFrames.single.data, '${_pngPrefix}CCCC');
    operator.dispose();
  });
}
