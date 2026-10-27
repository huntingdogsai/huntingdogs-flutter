import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'action_registry.dart';
import 'capture_diagnostics.dart';
import 'protocol.dart';
import 'runtime.dart';

class OperatorScope extends InheritedWidget {
  const OperatorScope({
    super.key,
    required this.operator,
    this.actions,
    required super.child,
  });

  final OperatorFlutter operator;
  final OperatorActionRegistry? actions;

  static OperatorFlutter of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<OperatorScope>();
    if (scope == null) {
      throw FlutterError('OperatorScope was not found in the widget tree.');
    }
    return scope.operator;
  }

  static OperatorFlutter? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<OperatorScope>()
        ?.operator;
  }

  static OperatorActionRegistry? maybeActionsOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<OperatorScope>()?.actions;
  }

  @override
  bool updateShouldNotify(OperatorScope oldWidget) =>
      oldWidget.operator != operator || oldWidget.actions != actions;
}

class OperatorRuntimeLayer extends StatefulWidget {
  const OperatorRuntimeLayer({
    super.key,
    required this.operator,
    required this.child,
    this.observeSemantics = true,
    this.observeWidgets = true,
    this.enableActuator = true,
    this.enableVerification = true,
  });

  final OperatorFlutter operator;
  final Widget child;
  final bool observeSemantics;
  final bool observeWidgets;
  final bool enableActuator;
  final bool enableVerification;

  @override
  State<OperatorRuntimeLayer> createState() => _OperatorRuntimeLayerState();
}

class OperatorVisualCaptureLayer extends StatefulWidget {
  const OperatorVisualCaptureLayer({
    super.key,
    required this.operator,
    required this.child,
    this.enabled = true,
  });

  final OperatorFlutter operator;
  final Widget child;
  final bool enabled;

  @override
  State<OperatorVisualCaptureLayer> createState() =>
      _OperatorVisualCaptureLayerState();
}

class OperatorTarget extends StatefulWidget {
  const OperatorTarget({
    super.key,
    required this.id,
    required this.role,
    required this.child,
    this.operator,
    this.label,
    this.text,
    this.value,
    this.hint,
    this.enabled = true,
    this.visible = true,
    this.actions = const <String>[],
    this.data = const <String, Object?>{},
    this.actionRegistry,
    this.onTap,
    this.onTextChanged,
  });

  final String id;
  final OperatorUiRole role;
  final Widget child;
  final OperatorFlutter? operator;
  final String? label;
  final String? text;
  final Object? value;
  final String? hint;
  final bool enabled;
  final bool visible;
  final List<String> actions;
  final JsonMap data;
  final OperatorActionRegistry? actionRegistry;
  final OperatorTapHandler? onTap;
  final OperatorTextHandler? onTextChanged;

  @override
  State<OperatorTarget> createState() => _OperatorTargetState();
}

class _OperatorTargetState extends State<OperatorTarget> {
  OperatorFlutter? _operator;
  OperatorActionRegistry? _actionRegistry;
  OperatorRegistrationDisposer? _tapDisposer;
  OperatorRegistrationDisposer? _textDisposer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _operator = widget.operator ?? OperatorScope.maybeOf(context);
    _actionRegistry =
        widget.actionRegistry ?? OperatorScope.maybeActionsOf(context);
    _registerHandlers();
    _scheduleCapture();
  }

  @override
  void didUpdateWidget(covariant OperatorTarget oldWidget) {
    super.didUpdateWidget(oldWidget);
    _operator = widget.operator ?? OperatorScope.maybeOf(context);
    _actionRegistry =
        widget.actionRegistry ?? OperatorScope.maybeActionsOf(context);
    if (oldWidget.id != widget.id) {
      _operator?.removeUiElement(oldWidget.id);
    }
    _registerHandlers();
    _scheduleCapture();
  }

  @override
  void dispose() {
    _tapDisposer?.call();
    _textDisposer?.call();
    _operator?.removeUiElement(widget.id);
    super.dispose();
  }

  void _registerHandlers() {
    _tapDisposer?.call();
    _textDisposer?.call();
    _tapDisposer = null;
    _textDisposer = null;
    final registry = _actionRegistry;
    if (registry == null) return;
    final tap = widget.onTap;
    if (tap != null) {
      _tapDisposer = registry.registerAction(
        id: widget.id,
        label: widget.label ?? widget.text,
        handler: tap,
      );
    }
    final textChanged = widget.onTextChanged;
    if (textChanged != null) {
      _textDisposer = registry.registerTextInput(
        id: widget.id,
        label: widget.label,
        onChanged: textChanged,
      );
    }
  }

  void _scheduleCapture() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _capture();
    });
  }

  void _capture() {
    final operator = _operator;
    if (operator == null) return;
    final box = context.findRenderObject();
    ElementBounds? bounds;
    if (box is RenderBox && box.hasSize) {
      final offset = box.localToGlobal(Offset.zero);
      bounds = ElementBounds(
        x: offset.dx,
        y: offset.dy,
        width: box.size.width,
        height: box.size.height,
      );
    }
    operator.captureUiElement(
      UiElement(
        id: widget.id,
        role: widget.role,
        label: widget.label,
        text: widget.text,
        value: widget.value,
        hint: widget.hint,
        enabled: widget.enabled,
        visible: widget.visible,
        bounds: bounds,
        actions: widget.actions,
        data: widget.data,
        confidence: 1,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _OperatorRuntimeLayerState extends State<OperatorRuntimeLayer> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _captureRoute();
  }

  @override
  void didUpdateWidget(covariant OperatorRuntimeLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    _captureRoute();
  }

  void _captureRoute() {
    final route = ModalRoute.of(context);
    widget.operator.captureRoute(
      name: route?.settings.name,
      path: route?.settings.name,
      screenClass: route?.runtimeType.toString(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return OperatorScope(operator: widget.operator, child: widget.child);
  }
}

class _OperatorVisualCaptureLayerState
    extends State<OperatorVisualCaptureLayer> {
  final GlobalKey _boundaryKey = GlobalKey(debugLabel: 'operator-visual-root');
  bool _captureScheduled = false;
  int _captureFailures = 0;
  DateTime? _lastCaptureFailureLogAt;
  Future<VisualFrame?>? _pendingCapture;
  VoidCallback? _visualProviderDisposer;

  @override
  void initState() {
    super.initState();
    _registerProvider();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scheduleCapture();
  }

  @override
  void didUpdateWidget(covariant OperatorVisualCaptureLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.operator != widget.operator) {
      _visualProviderDisposer?.call();
      _registerProvider();
    }
    _scheduleCapture();
  }

  @override
  void dispose() {
    _visualProviderDisposer?.call();
    _visualProviderDisposer = null;
    super.dispose();
  }

  void _registerProvider() {
    _visualProviderDisposer = widget.operator.addVisualFrameProvider(
      _captureFrame,
    );
  }

  void _scheduleCapture() {
    if (!widget.enabled || _captureScheduled || _isWidgetTestBinding) {
      return;
    }
    _captureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _captureScheduled = false;
      unawaited(_captureAndStoreFrame());
    });
  }

  Future<void> _captureAndStoreFrame() async {
    final frame = await _captureFrame();
    if (frame != null) {
      widget.operator.captureVisualFrame(frame);
    }
  }

  Future<VisualFrame?> _captureFrame() async {
    final pending = _pendingCapture;
    if (pending != null) {
      operatorCaptureMark('flutter.capture_join', 'enter', {
        'pendingCaptureId': _pendingDiagnosticId,
        'pendingAgeMs': _pendingDiagnosticClock?.elapsedMilliseconds,
      });
      return operatorCaptureAsyncStage(
        'flutter.capture_join_wait',
        () => pending,
      );
    }
    _pendingDiagnosticId =
        '${operatorCaptureTrace}:frame:${++_diagnosticCaptureSequence}';
    _pendingDiagnosticClock = Stopwatch()..start();
    final next = operatorCaptureTraceScope(
      _pendingDiagnosticId!,
      () => operatorCaptureAsyncStage('flutter.capture', _captureFrameNow),
    );
    _pendingCapture = next;
    next.whenComplete(() {
      if (_pendingCapture == next) {
        _pendingCapture = null;
        _pendingDiagnosticClock = null;
        _pendingDiagnosticId = null;
      }
    });
    return next;
  }

  String? _pendingDiagnosticId;
  Stopwatch? _pendingDiagnosticClock;
  int _diagnosticCaptureSequence = 0;

  Future<VisualFrame?> _captureFrameNow() async {
    if (!mounted || !widget.enabled || _isWidgetTestBinding) {
      return null;
    }
    try {
      await _waitForFreshFrame();
      final boundary =
          _boundaryKey.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      // The awaited draw has flushed paint. debugNeedsPaint is assertion-only and
      // throws in release; mounted geometry is checked through production APIs.
      if (boundary == null ||
          !boundary.attached ||
          !boundary.hasSize ||
          boundary.size.isEmpty) {
        _scheduleCapture();
        return null;
      }
      final pixelRatio =
          widget.operator.config.privacy.screenshotPixelRatio <= 0
              ? 1.0
              : widget.operator.config.privacy.screenshotPixelRatio;
      final boundaryFrame = await _captureBoundaryFrame(
        boundary: boundary,
        pixelRatio: pixelRatio,
      );
      if (!_shouldTryRenderViewFallback(boundaryFrame)) {
        _captureFailures = 0;
        return boundaryFrame;
      }
      final renderViewFrame = await _captureRenderViewFrame(
        flutterView: View.maybeOf(context),
        pixelRatio: pixelRatio,
      );
      _captureFailures = 0;
      return _bestVisualFrame(boundaryFrame, renderViewFrame);
    } catch (error) {
      _captureFailures++;
      _reportCaptureFailure(error);
      if (mounted) {
        Future<void>.delayed(const Duration(milliseconds: 500), () {
          if (mounted) _scheduleCapture();
        });
      }
      return null;
    }
  }

  Future<void> _waitForFreshFrame() async {
    final binding = WidgetsBinding.instance;
    operatorCaptureMark('flutter.frame_wait', 'enter', {
      'schedulerPhase': binding.schedulerPhase.name,
      'hasScheduledFrame': binding.hasScheduledFrame,
      'framesEnabled': binding.framesEnabled,
      'lifecycle': binding.lifecycleState?.name,
    });
    if (binding.schedulerPhase != SchedulerPhase.idle) {
      await operatorCaptureAsyncStage(
        'flutter.pre_warmup_end_of_frame',
        () => binding.endOfFrame,
      );
    }
    final completed = binding.endOfFrame;
    // An explicit capture needs build/layout/paint even when the browser has
    // suspended display-refresh callbacks. Warm-up draws are timer-driven on web;
    // the owned browser launcher keeps those timers running while hidden.
    operatorCaptureStage(
      'flutter.schedule_warmup',
      binding.scheduleWarmUpFrame,
    );
    await operatorCaptureAsyncStage(
      'flutter.warmup_completion',
      () => completed,
    );
    operatorCaptureMark('flutter.frame_wait', 'exit');
  }

  Future<VisualFrame> _captureBoundaryFrame({
    required RenderRepaintBoundary boundary,
    required double pixelRatio,
  }) async {
    final image = await operatorCaptureAsyncStage(
      'flutter.boundary_readback',
      () => boundary
          .toImage(pixelRatio: pixelRatio)
          .timeout(const Duration(seconds: 2)),
    );
    final data = await _pngBase64FromImage(image);
    return VisualFrame(
      id: 'flutter-root-frame',
      format: 'png',
      encoding: 'base64',
      data: data,
      width: boundary.size.width,
      height: boundary.size.height,
      pixelRatio: pixelRatio,
      source: 'repaint_boundary',
      redacted: false,
    );
  }

  Future<VisualFrame?> _captureRenderViewFrame({
    required ui.FlutterView? flutterView,
    required double pixelRatio,
  }) async {
    RenderView? renderView;
    for (final candidate in RendererBinding.instance.renderViews) {
      if (!candidate.attached ||
          candidate.size.width <= 1 ||
          candidate.size.height <= 1) {
        continue;
      }
      if (flutterView != null && candidate.flutterView != flutterView) {
        continue;
      }
      renderView = candidate;
      break;
    }
    if (renderView == null) {
      for (final candidate in RendererBinding.instance.renderViews) {
        if (!candidate.attached ||
            candidate.size.width <= 1 ||
            candidate.size.height <= 1) {
          continue;
        }
        renderView = candidate;
        break;
      }
    }
    // RenderObject documents layer as the production counterpart of debugLayer.
    // There is no public RenderView.toImage; read the completed composited layer.
    // ignore: invalid_use_of_protected_member
    final layer = renderView?.layer;
    if (renderView == null || layer is! OffsetLayer) return null;
    final renderSize = renderView.size;
    final image = await operatorCaptureAsyncStage(
      'flutter.render_view_readback',
      () => layer
          .toImage(Offset.zero & renderSize, pixelRatio: pixelRatio)
          .timeout(const Duration(seconds: 2)),
    );
    final data = await _pngBase64FromImage(image);
    return VisualFrame(
      id: 'flutter-render-view-frame',
      format: 'png',
      encoding: 'base64',
      data: data,
      width: renderView.size.width,
      height: renderView.size.height,
      pixelRatio: pixelRatio,
      source: 'screenshot',
      redacted: false,
    );
  }

  Future<String> _pngBase64FromImage(ui.Image image) async {
    try {
      operatorCaptureMark('flutter.pixels', 'size', {
        'width': image.width,
        'height': image.height,
      });
      final byteData = await operatorCaptureAsyncStage(
        'flutter.png_encode',
        () => image
            .toByteData(format: ui.ImageByteFormat.png)
            .timeout(const Duration(seconds: 2)),
      );
      if (byteData == null) {
        throw StateError('visual capture returned empty PNG bytes');
      }
      operatorCaptureMark('flutter.png', 'size', {
        'bytes': byteData.lengthInBytes,
      });
      return operatorCaptureStage(
        'flutter.base64',
        () => base64Encode(byteData.buffer.asUint8List()),
      );
    } finally {
      image.dispose();
    }
  }

  bool _shouldTryRenderViewFallback(VisualFrame frame) {
    final dataLength = frame.data?.length ?? 0;
    final area = frame.width * frame.height;
    return area > 100000 && dataLength > 0 && dataLength < 16 * 1024;
  }

  VisualFrame _bestVisualFrame(
    VisualFrame boundaryFrame,
    VisualFrame? renderViewFrame,
  ) {
    if (renderViewFrame == null) return boundaryFrame;
    final boundarySuspicious = _shouldTryRenderViewFallback(boundaryFrame);
    final renderViewSuspicious = _shouldTryRenderViewFallback(renderViewFrame);
    if (boundarySuspicious && !renderViewSuspicious) return renderViewFrame;
    if (!boundarySuspicious && renderViewSuspicious) return boundaryFrame;
    final boundaryLength = boundaryFrame.data?.length ?? 0;
    final renderViewLength = renderViewFrame.data?.length ?? 0;
    return renderViewLength > boundaryLength ? renderViewFrame : boundaryFrame;
  }

  void _reportCaptureFailure(Object error) {
    final now = DateTime.now();
    final shouldLog =
        _lastCaptureFailureLogAt == null ||
        now.difference(_lastCaptureFailureLogAt!) > const Duration(seconds: 5);
    if (!shouldLog) return;
    _lastCaptureFailureLogAt = now;
    widget.operator.captureLog(
      'warn',
      'visual pixel capture failed',
      data: <String, Object?>{
        'failureCount': _captureFailures,
        'error': error.toString(),
        'pixelBacked': false,
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    _scheduleCapture();
    return RepaintBoundary(key: _boundaryKey, child: widget.child);
  }

  bool get _isWidgetTestBinding => WidgetsBinding.instance.runtimeType
      .toString()
      .contains('TestWidgetsFlutterBinding');
}
