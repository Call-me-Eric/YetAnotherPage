import '../ink/spatial_index.dart';
import '../storage/write_queue.dart';

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../ids.dart';
import '../ink/eraser.dart';
import '../ink/marks.dart';
import '../ink/fix_text.dart';
import '../ink/pen_palette.dart';
import '../ink/selection.dart';
import '../ink/stroke.dart';
import '../ink/text_box.dart';
import '../input/finger.dart';
import '../input/stylus_feedback.dart';
import '../input/stylus_preferences.dart';
import '../input/stylus_side_button.dart';
import '../storage/note_document.dart';
import '../storage/vault.dart';
import 'layer_panel.dart';
import 'page_canvas.dart';
import 'pen_settings.dart';
import 'selection_frame.dart';
import 'settings_page.dart';
import 'title_dialog.dart';
import 'tool_arc.dart';

class NotePage extends StatefulWidget {
  const NotePage({required this.vault, required this.note, super.key});

  final NoteLibrary vault;
  final OpenNote note;

  @override
  State<NotePage> createState() => _NotePageState();
}

class _NotePageState extends State<NotePage> with TickerProviderStateMixin {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  late OpenNote _note;
  late String _selectedPageId;
  late final TransformationController _transform;
  _PenSession? _session;
  StrokeObject? _preview;
  String? _previewPageId;
  final ValueNotifier<({String pageId, StrokeObject stroke})?> _live =
      ValueNotifier(null);
  final ValueNotifier<InkPatch?> _patches = ValueNotifier(null);
  final ValueNotifier<StrokeFade> _fading = ValueNotifier(const StrokeFade());
  final List<Offset> _eraser = [];
  final List<_MarkEdit> _undoStack = [];
  final List<_MarkEdit> _redoStack = [];
  final Map<int, _PanContact> _fingers = {};
  final Set<int> _ignoredFingers = {};
  var _multiTouch = false;
  Offset _panVelocity = Offset.zero;
  Duration? _lastPanStamp;
  Ticker? _inertia;
  double _tileScale = 1;
  var _centered = false;
  var _centerScheduled = false;
  InkTool _tool = InkTool.pen;
  var _penBarOpen = false;
  PenPalette _penPalette = PenPalette.initial();
  PenPalette _highlighterPalette = PenPalette.highlighter();
  bool get _isHighlighter => _tool == InkTool.highlighter;
  PenPalette get _pen => _isHighlighter ? _highlighterPalette : _penPalette;
  var _penEpoch = 0;
  var _highlighterEpoch = 0;
  String? _editingTextId;
  String? _selectedTextId;
  String? _textHoverPageId;
  Offset? _textHoverLocal;
  final Map<String, ({String pageId, String layerId, TextBox box})>
  _textDrafts = {};
  final Map<String, TextBox> _editOrigin = {};
  final Map<String, TextBox> _gestureBefore = {};
  String? _eraserPageId;
  String? _eraserLayerId;
  LayerFile? _regionBase;
  _InkLocator? _regionLocator;
  final Map<String, List<StrokeObject>> _regionPieces = {};
  List<String> _selectionOriginIds = const [];
  EraserKind _eraserKind = EraserKind.stroke;
  double _eraserRadius = 14;
  var _eraserBarOpen = false;
  LassoShape _lassoShape = LassoShape.free;
  final Set<LassoTarget> _lassoTargets = {
    LassoTarget.stroke,
    LassoTarget.text,
    LassoTarget.highlighter,
  };
  var _lassoBarOpen = false;
  String? _lassoPageId;
  List<Offset> _lassoPoints = const [];
  final ValueNotifier<LassoDrag?> _lassoLive = ValueNotifier(null);
  List<Offset> _lassoOutline = const [];
  List<Offset>? _gestureOutline;
  StylusPreferences _stylus = StylusPreferences.initial;
  InkTool? _toolBeforeEraser;
  var _selectionMenuOpen = false;
  Rect? _lassoRect;
  String? _selectionPageId;
  String? _selectionLayerId;
  List<StrokeObject> _selectedStrokes = const [];
  List<TextBox> _selectedTexts = const [];
  Rect? _selectionBounds;
  List<StrokeObject>? _gestureStrokes;
  List<TextBox>? _gestureTexts;

  /// Sticker is out of the note (origins tombstoned) until deselect pastes it back.
  var _selectionLifted = false;
  List<TextBox> _liftedTexts = const [];
  final ValueNotifier<SelectionPreview?> _selectionLive = ValueNotifier(null);
  Offset? _gestureCenter;
  Offset? _dragStart;
  SelectionHandle? _scaleHandle;
  Rect? _gestureBounds;
  Matrix4? _gestureMatrix;
  Matrix4? _gestureBaseMatrix;

  /// Cumulative display transform of the lift-time picture.
  Matrix4? _stickerMatrix;
  Rect? _stickerOriginBounds;

  /// Lasso outline in lift-time picture space (drawn dashed + translucent).
  List<Offset> _stickerOutline = const [];
  ui.Picture? _stickerPicture;
  OverlayEntry? _optionsArc;
  Offset? _tip;
  OverlayEntry? _arc;
  OverlayEntry? _presetArc;
  Offset? _arcCenter;
  List<PenPresetTarget> _presetTargets = const [];
  final Map<String, StrokeObject> _geometry = {};
  final Expando<List<StrokeObject>> _layerGeometry = Expando();
  final Map<(String, String), _InkLocator> _indices = {};
  _InkLocator? _locator;
  String? _locatorPageId;
  String? _locatorLayerId;
  final WriteQueue _writes = WriteQueue();
  var _checkpointCount = 0;
  double _checkpointTime = 0;
  var _closing = false;
  var _savingExit = false;
  var _structureBusy = false;

  @override
  void initState() {
    super.initState();
    _note = widget.note;
    _selectedPageId = widget.note.pages.first.id;
    _transform = TransformationController();
    stylusSideButton.addListener(_toggleArc);
    stylusSideButton.addDoubleTapListener(_onDoubleTap);
    final vault = widget.vault;
    if (vault is Vault) {
      final epoch = _penEpoch;
      vault.readStylusPreferences().then((preferences) {
        if (mounted) {
          setState(() => _stylus = preferences);
        }
      });
      vault.readPenPalette().then((palette) {
        if (mounted && epoch == _penEpoch) {
          setState(() => _penPalette = palette);
        }
      });
    }
    if (vault is Vault) {
      vault.readPenPalette(highlighter: true).then((palette) {
        if (mounted && _highlighterEpoch == 0) {
          setState(() => _highlighterPalette = palette);
        }
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      FocusManager.instance.primaryFocus?.unfocus();
    });
  }

  @override
  void dispose() {
    stylusSideButton.removeListener(_toggleArc);
    stylusSideButton.removeDoubleTapListener(_onDoubleTap);
    _inertia?.dispose();
    _arc?.remove();
    _arc = null;
    _optionsArc?.remove();
    _optionsArc = null;
    _stickerPicture?.dispose();
    _stickerPicture = null;
    _selectionLive.dispose();
    _lassoLive.dispose();
    _transform.dispose();
    _live.dispose();
    _patches.dispose();
    _fading.dispose();
    super.dispose();
  }

  PageFile get _selectedPage {
    return _note.pages.firstWhere(
      (page) => page.id == _selectedPageId,
      orElse: () => _note.pages.first,
    );
  }

  void _queueSave(Future<void> Function() write) {
    _writes.add(write).catchError((Object error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('保存失败，修改保留在内存中：$error')));
      }
    });
  }

  void _settleEdits() {
    _flushEditing();
    final session = _session;
    if (session != null) _endStroke(session.pageId);
    final eraserPage = _eraserPageId;
    if (eraserPage != null) _eraseEnd(eraserPage);
    _clearSelection();
  }

  Future<void> _leaveNote() async {
    if (_savingExit) return;
    _savingExit = true;
    try {
      _settleEdits();
      await _writes.flush();
      if (!mounted) return;
      setState(() => _closing = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop();
      });
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('无法保存，暂未退出笔记：$error')));
      }
    } finally {
      _savingExit = false;
    }
  }

  Future<void> _replace(
    Future<OpenNote> Function() operation, {
    String? selectPageId,
  }) async {
    if (_structureBusy) return;
    setState(() => _structureBusy = true);
    try {
      _settleEdits();
      await _writes.flush();
      final updated = await operation();
      if (!mounted) return;
      setState(() {
        _note = updated;
        if (selectPageId != null &&
            updated.pages.any((p) => p.id == selectPageId)) {
          _selectedPageId = selectPageId;
        } else if (!updated.pages.any((p) => p.id == _selectedPageId)) {
          _selectedPageId = updated.pages.first.id;
        }
      });
    } finally {
      if (mounted) setState(() => _structureBusy = false);
    }
  }

  Future<void> _rename() async {
    final title = await askTitle(context, heading: '重命名', initial: _note.title);
    if (title == null || !mounted) {
      return;
    }
    try {
      await _replace(() => widget.vault.renameNote(_note, title));
    } on NoteNameTaken catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  void _settleScale() {
    final scale = _transform.value.getMaxScaleOnAxis();
    if ((scale - _tileScale).abs() < 0.04) {
      return;
    }
    setState(() => _tileScale = scale);
  }

  void _scheduleCenter(Size viewport) {
    if (_centered ||
        _centerScheduled ||
        viewport.width <= 0 ||
        viewport.height <= 0) {
      return;
    }
    _centerScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _centered) {
        return;
      }
      _centered = true;
      final page = _selectedPage;
      const inset = 48.0;
      _transform.value = Matrix4.translationValues(
        viewport.width / 2 - inset - page.width / 2,
        viewport.height / 2 - inset - page.height / 2,
        0,
      );
    });
  }

  void _fingerDown(PointerDownEvent event) {
    final finger = actsAsFinger(
      event.kind,
      stylusAsFinger: _tool == InkTool.text,
    );
    final mouseInText =
        _tool == InkTool.text && event.kind == PointerDeviceKind.mouse;
    if (!finger && !mouseInText) {
      return;
    }
    if (_ignoredFingers.contains(event.pointer)) {
      return;
    }
    _stopInertia();
    _fingers[event.pointer] = _PanContact(event.position, event.kind);
    if (_touchCount > 1) {
      _multiTouch = true;
      _panVelocity = Offset.zero;
      _stopInertia();
    }
    _lastPanStamp = event.timeStamp;
    if (!_multiTouch) {
      _panVelocity = Offset.zero;
    }
  }

  void _fingerMove(PointerMoveEvent event) {
    if (_ignoredFingers.contains(event.pointer)) {
      return;
    }
    final contact = _fingers[event.pointer];
    if (contact == null) {
      return;
    }
    if (_touchCount == 2 && contact.kind == PointerDeviceKind.touch) {
      final before = _touchCentroid();
      final spanBefore = _touchSpan();
      contact.position = event.position;
      final spanAfter = _touchSpan();
      final ratio = spanBefore == 0 ? 1.0 : spanAfter / spanBefore;
      if (before != null && ratio > 0.98 && ratio < 1.02) {
        final after = _touchCentroid();
        if (after != null) {
          final delta = after - before;
          _transform.value =
              Matrix4.translationValues(delta.dx, delta.dy, 0) *
              _transform.value;
        }
      }
      _panVelocity = Offset.zero;
      _lastPanStamp = event.timeStamp;
      return;
    }
    final previous = contact.position;
    contact.position = event.position;
    if (_fingers.length != 1) {
      _lastPanStamp = event.timeStamp;
      return;
    }
    final delta = event.position - previous;
    final stamp = _lastPanStamp;
    _lastPanStamp = event.timeStamp;
    if (stamp != null) {
      final dt = (event.timeStamp - stamp).inMicroseconds / 1000000;
      if (dt > 0.001 && dt < 0.08) {
        final instant = delta / dt;
        _panVelocity = Offset(
          _panVelocity.dx * 0.45 + instant.dx * 0.55,
          _panVelocity.dy * 0.45 + instant.dy * 0.55,
        );
      }
    }
    _transform.value =
        Matrix4.translationValues(delta.dx, delta.dy, 0) * _transform.value;
  }

  void _fingerUp(PointerEvent event) {
    final ignored = _ignoredFingers.remove(event.pointer);
    final wasMoving = _fingers.containsKey(event.pointer);
    _fingers.remove(event.pointer);
    if (ignored || !wasMoving) {
      return;
    }
    if (_fingers.isNotEmpty) {
      _stopInertia();
      return;
    }
    if (_multiTouch) {
      _multiTouch = false;
      _panVelocity = Offset.zero;
      return;
    }
    _startInertia();
  }

  int get _touchCount {
    var count = 0;
    for (final contact in _fingers.values) {
      if (contact.kind == PointerDeviceKind.touch) {
        count += 1;
      }
    }
    return count;
  }

  Offset? _touchCentroid() {
    final points = [
      for (final contact in _fingers.values)
        if (contact.kind == PointerDeviceKind.touch) contact.position,
    ];
    if (points.length < 2) {
      return null;
    }
    var sum = Offset.zero;
    for (final point in points) {
      sum += point;
    }
    return sum / points.length.toDouble();
  }

  double _touchSpan() {
    final points = [
      for (final contact in _fingers.values)
        if (contact.kind == PointerDeviceKind.touch) contact.position,
    ];
    if (points.length < 2) {
      return 0;
    }
    return (points[0] - points[1]).distance;
  }

  void _suppressPan(int pointer) {
    _stopInertia();
    _ignoredFingers.add(pointer);
    _fingers.remove(pointer);
    _panVelocity = Offset.zero;
    _lastPanStamp = null;
  }

  void _endMoving() {
    _stopInertia();
    _ignoredFingers.addAll(_fingers.keys);
    _fingers.clear();
    _panVelocity = Offset.zero;
    _lastPanStamp = null;
  }

  void _stopInertia() {
    _inertia?.stop();
    _panVelocity = Offset.zero;
  }

  void _startInertia() {
    if (_panVelocity.distance < 80) {
      _panVelocity = Offset.zero;
      return;
    }
    _inertia?.dispose();
    var last = Duration.zero;
    _inertia = createTicker((elapsed) {
      final dt = (elapsed - last).inMicroseconds / 1000000;
      last = elapsed;
      if (dt <= 0) {
        return;
      }
      _panVelocity *= math.exp(-3.4 * dt);
      if (_panVelocity.distance < 12) {
        _stopInertia();
        return;
      }
      final delta = _panVelocity * dt;
      _transform.value =
          Matrix4.translationValues(delta.dx, delta.dy, 0) * _transform.value;
    });
    _inertia!.start();
  }

  void _startStroke(String pageId, PointerEvent event) {
    _endMoving();
    if (_selectionBounds != null) {
      setState(_clearSelection);
    }
    final page = _note.pages.firstWhere((item) => item.id == pageId);
    final layer = _drawingLayer(page);
    if (layer == null) {
      return;
    }
    final width = _pen.width;
    final first = sampleFromPointer(
      event: event,
      x: event.localPosition.dx,
      y: event.localPosition.dy,
      time: 0,
      baseWidth: width,
    );
    final stroke = StrokeObject(
      id: newId(),
      tool: _isHighlighter ? 'highlighter' : 'pen',
      color: _pen.color,
      baseWidth: width,
      dashCycle: _pen.dash.cycle,
      dashRatio: _pen.dash.ratio,
      finalized: false,
      points: [first],
    );
    setState(() {
      _selectedPageId = pageId;
      _session = _PenSession(
        pageId: pageId,
        layerId: layer.id,
        started: event.timeStamp,
        raw: [first],
        stroke: stroke,
        cursor: StrokeCursor(),
      );
      _preview = stroke;
      _previewPageId = pageId;
    });
    _live.value = (pageId: pageId, stroke: stroke);
    _checkpointCount = 0;
    _checkpointTime = 0;
    _checkpoint(_session!, force: true);
  }

  void _moveStroke(String pageId, PointerEvent event) {
    final session = _session;
    if (session == null || session.pageId != pageId) {
      return;
    }
    final sample = sampleFromPointer(
      event: event,
      x: event.localPosition.dx,
      y: event.localPosition.dy,
      time: (event.timeStamp - session.started).inMicroseconds / 1000000,
      baseWidth: session.stroke.baseWidth,
    );
    final paintedBefore = session.stroke.points.length;
    final next = appendCausalPoint(
      raw: session.raw,
      painted: session.stroke.points,
      sample: sample,
      baseWidth: session.stroke.baseWidth,
      connected: session.cursor.connected,
      cursor: session.cursor,
    );
    if (session.stroke.tool == 'highlighter') {
      for (var i = paintedBefore; i < next.painted.length; i++) {
        next.painted[i] = next.painted[i].copyWith(
          width: session.stroke.baseWidth,
          height: session.stroke.baseWidth,
        );
      }
    }
    final stroke = session.stroke.copyWith(points: next.painted);
    _session = session.copyWith(raw: next.raw, stroke: stroke);
    _preview = stroke;
    _live.value = (pageId: pageId, stroke: stroke);
    _checkpoint(_session!);
  }

  void _checkpoint(_PenSession session, {bool force = false}) {
    final store = widget.vault;
    if (store is! StrokeRecoveryStore || session.raw.isEmpty) return;
    final time = session.raw.last.time;
    if (!force && time - _checkpointTime < 0.032) return;
    final samples = session.raw.sublist(_checkpointCount);
    if (samples.isEmpty) return;
    _checkpointCount = session.raw.length;
    _checkpointTime = time;
    final directory = _note.directoryName;
    final header = session.stroke.copyWith(points: []);
    _queueSave(
      () => (store as StrokeRecoveryStore).checkpointStroke(
        directory,
        pageId: session.pageId,
        layerId: session.layerId,
        stroke: header,
        samples: samples,
      ),
    );
  }

  void _endStroke(String pageId) {
    final session = _session;
    if (session == null || session.pageId != pageId) {
      return;
    }
    _checkpoint(session, force: true);
    final flushed = finishStroke(
      raw: session.raw,
      painted: session.stroke.points,
      connected: session.cursor.connected,
      cursor: session.cursor,
    );
    final baked = session.stroke.copyWith(
      points: session.stroke.tool == 'highlighter'
          ? [
              for (final point in flushed.painted)
                point.copyWith(
                  width: session.stroke.baseWidth,
                  height: session.stroke.baseWidth,
                ),
            ]
          : flushed.painted,
      finalized: true,
    );
    _session = null;
    _preview = null;
    _previewPageId = null;
    _live.value = null;
    _commit(
      _MarkEdit(
        pageId: pageId,
        layerId: session.layerId,
        added: [baked],
        tombstoned: const [],
      ),
    );
  }

  void _lassoStart(String pageId, Offset point) {
    if (_stylus.selectionHaptic) {
      prepareSelectionHaptic();
    }
    setState(() {
      _lassoPageId = pageId;
      _lassoPoints = [point];
      _lassoRect = _lassoShape == LassoShape.rect
          ? Rect.fromPoints(point, point)
          : null;
      _clearSelection();
      _lassoLive.value = LassoDrag(points: _lassoPoints, rect: _lassoRect);
    });
  }

  void _lassoMove(String pageId, Offset point) {
    if (_lassoPageId != pageId || _lassoPoints.isEmpty) {
      return;
    }
    if (_lassoShape == LassoShape.rect) {
      _lassoRect = Rect.fromPoints(_lassoPoints.first, point);
      _lassoLive.value = LassoDrag(points: _lassoPoints, rect: _lassoRect);
      return;
    }
    if ((point - _lassoPoints.last).distance < 1.5) {
      return;
    }
    _lassoPoints.add(point);
    _lassoLive.value = LassoDrag(points: _lassoPoints, rect: null);
  }

  void _lassoEnd(String pageId, Offset point) {
    if (_lassoPageId != pageId) {
      return;
    }
    _lassoMove(pageId, point);
    final drawn = List<Offset>.of(_lassoPoints);
    final polygon = _lassoShape == LassoShape.free && drawn.length >= 3
        ? _coarsePolygon(drawn)
        : null;
    final rect = _lassoShape == LassoShape.rect ? _lassoRect : null;
    final page = _note.pages.where((item) => item.id == pageId);
    final layer = page.isEmpty ? null : _drawingLayer(page.single);
    final strokes = <StrokeObject>[];
    final texts = <TextBox>[];
    if (layer != null && (polygon != null || (rect != null && !rect.isEmpty))) {
      final query =
          rect ??
          Rect.fromPoints(
            Offset(
              polygon!.map((p) => p.dx).reduce(math.min),
              polygon.map((p) => p.dy).reduce(math.min),
            ),
            Offset(
              polygon.map((p) => p.dx).reduce(math.max),
              polygon.map((p) => p.dy).reduce(math.max),
            ),
          );
      for (final stroke in _indexFor(
        page.single,
        layer,
      ).near(query, layer.deletedObjectIds.toSet())) {
        final highlighter = stroke.tool == 'highlighter';
        if (highlighter && !_lassoTargets.contains(LassoTarget.highlighter)) {
          continue;
        }
        if (!highlighter && !_lassoTargets.contains(LassoTarget.stroke)) {
          continue;
        }
        if (strokeHitsRegion(stroke, rect: rect, polygon: polygon)) {
          strokes.add(stroke);
        }
      }
      if (_lassoTargets.contains(LassoTarget.text)) {
        for (final item in _textBoxes()) {
          if (item.pageId != pageId) {
            continue;
          }
          if (_layerOfText(item.box.id) != layer.id) {
            continue;
          }
          if (textHitsRegion(item.box, rect: rect, polygon: polygon)) {
            texts.add(item.box);
          }
        }
      }
    }
    final outline = strokes.isEmpty && texts.isEmpty
        ? const <Offset>[]
        : (_lassoShape == LassoShape.free && drawn.length >= 3
              ? drawn
              : const <Offset>[]);
    setState(() {
      _lassoPoints = const [];
      _lassoRect = null;
      _lassoPageId = null;
      _lassoLive.value = null;
    });
    if (strokes.isEmpty && texts.isEmpty) {
      return;
    }
    _liftSelection(
      pageId: pageId,
      layerId: layer!.id,
      strokes: strokes,
      texts: texts,
      outline: outline,
    );
  }

  /// Pull ink out of the note into a movable sticker, then tombstone the origins.
  void _liftSelection({
    required String pageId,
    required String layerId,
    required List<StrokeObject> strokes,
    required List<TextBox> texts,
    required List<Offset> outline,
  }) {
    if (_selectionLifted) {
      _pasteStickerIntoNote();
    }
    final originIds = [for (final stroke in strokes) stroke.id];
    _selectionOriginIds = originIds;
    final sticker = [
      for (final stroke in strokes) _cloneStroke(stroke, id: newId()),
    ];
    final liftedTexts = [for (final box in texts) box];
    final bounds = boundsOfObjects(strokes: sticker, texts: liftedTexts);
    _selectionPageId = pageId;
    _selectionLayerId = layerId;
    _selectedStrokes = sticker;
    _selectedTexts = liftedTexts;
    _liftedTexts = liftedTexts;
    _selectionBounds = bounds;
    _lassoOutline = outline;
    _selectionLifted = true;
    for (final box in liftedTexts) {
      _textDrafts[box.id] = (pageId: pageId, layerId: layerId, box: box);
    }
    _stickerOriginBounds = bounds;
    _stickerMatrix = null;
    _stickerOutline = outline;
    _showSticker(rerecord: true);
    if (originIds.isNotEmpty) {
      // Lifting is a display transaction, not a separate undo command.
      _note = applyMarks(
        _note,
        pageId: pageId,
        layerId: layerId,
        tombstone: originIds,
      );
      setState(() {});
    } else {
      setState(() {});
    }
  }

  void _showSticker({bool rerecord = false}) {
    final origin = _stickerOriginBounds ?? _selectionBounds;
    if (origin == null) {
      return;
    }
    if (rerecord || _stickerPicture == null) {
      final previous = _stickerPicture;
      // Outline is drawn live (dashed / translucent), not baked into the picture.
      _stickerPicture = _recordSelection(_selectedStrokes, null);
      _stickerOriginBounds = boundsOfObjects(
        strokes: _selectedStrokes,
        texts: _selectedTexts,
      );
      _stickerMatrix = null;
      if (previous != null && !identical(previous, _stickerPicture)) {
        WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
      }
    }
    final display = _stickerMatrix;
    final frame = _stickerOriginBounds ?? origin;
    final visual = display == null ? frame : _boundsThrough(display, frame);
    _selectionBounds = visual;
    _selectionLive.value = SelectionPreview(
      strokes: const [],
      bounds: visual,
      frameBounds: frame,
      outline: _stickerOutline,
      picture: _stickerPicture,
      transform: display?.storage,
    );
  }

  void _selectionMove(Offset pagePoint) {
    _beginSelectionGesture();
    _dragStart ??= pagePoint;
    final delta = pagePoint - _dragStart!;
    _gestureMatrix = Matrix4.translationValues(delta.dx, delta.dy, 0);
    _publishPreview();
  }

  void _selectionScale(SelectionHandle handle, Offset pagePoint) {
    if (!handle.corner) {
      return;
    }
    final origin = _stickerOriginBounds;
    if (origin == null || origin.width < 1 || origin.height < 1) {
      return;
    }
    _beginSelectionGesture();
    final base = _gestureBaseMatrix ?? Matrix4.identity();
    late final Matrix4 inverse;
    try {
      inverse = Matrix4.inverted(base);
    } catch (_) {
      return;
    }
    _scaleHandle ??= handle;
    _dragStart ??= pagePoint;
    // Scale in lift/local space so rotated handles track the finger and keep
    // the opposite corner fixed. gesture * base == base * localScale.
    final localScale = selectionScaleMatrix(
      handle: _scaleHandle!,
      startBounds: origin,
      startPointer: _through(inverse, _dragStart!),
      currentPointer: _through(inverse, pagePoint),
    );
    _gestureMatrix = base.multiplied(localScale).multiplied(inverse);
    _publishPreview();
  }

  void _selectionRotate(Offset pagePoint) {
    final origin = _stickerOriginBounds ?? _selectionBounds;
    if (origin == null) {
      return;
    }
    _beginSelectionGesture();
    // Rotate about the oriented frame center (not the upright AABB).
    final base = _gestureBaseMatrix ?? Matrix4.identity();
    _gestureCenter ??= _through(base, origin.center);
    _dragStart ??= pagePoint;
    _gestureMatrix = selectionRotateMatrix(
      center: _gestureCenter!,
      startPointer: _dragStart!,
      currentPointer: pagePoint,
    );
    _publishPreview();
  }

  void _mirrorSelection({required bool horizontal}) {
    final bounds = _selectionBounds;
    if (bounds == null) {
      return;
    }
    _ensureSelectionLifted();
    _beginSelectionGesture();
    final center = _gestureBounds!.center;
    final mirror = Matrix4.identity();
    if (horizontal) {
      mirror
        ..translateByDouble(center.dx, 0.0, 0, 1)
        ..scaleByDouble(-1.0, 1.0, 1, 1)
        ..translateByDouble(-center.dx, 0.0, 0, 1);
    } else {
      mirror
        ..translateByDouble(0.0, center.dy, 0, 1)
        ..scaleByDouble(1.0, -1.0, 1, 1)
        ..translateByDouble(0.0, -center.dy, 0, 1);
    }
    _gestureMatrix = mirror;
    _publishPreview();
    _finishSelectionGesture();
  }

  void _ensureSelectionLifted() {
    if (_selectionLifted) {
      return;
    }
    final pageId = _selectionPageId;
    final layerId = _selectionLayerId;
    if (pageId == null || layerId == null) {
      return;
    }
    if (_selectedStrokes.isEmpty && _selectedTexts.isEmpty) {
      return;
    }
    _liftSelection(
      pageId: pageId,
      layerId: layerId,
      strokes: _selectedStrokes,
      texts: _selectedTexts,
      outline: _lassoOutline,
    );
  }

  void _beginSelectionGesture() {
    _ensureSelectionLifted();
    if (_gestureStrokes != null) {
      return;
    }
    _gestureStrokes = _selectedStrokes;
    _gestureTexts = [for (final box in _selectedTexts) box];
    _gestureOutline = List<Offset>.of(_lassoOutline);
    _gestureBounds = _selectionBounds;
    _gestureBaseMatrix = Matrix4.copy(_stickerMatrix ?? Matrix4.identity());
    _gestureMatrix = Matrix4.identity();
    _dragStart = null;
    _scaleHandle = null;
    _gestureCenter = null;
  }

  ui.Picture? _recordSelection(
    List<StrokeObject> strokes,
    List<Offset>? outline,
  ) {
    if (strokes.isEmpty && (outline == null || outline.length < 2)) {
      return null;
    }
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    for (final stroke in strokes) {
      paintStroke(canvas, stroke);
    }
    if (outline != null && outline.length >= 2) {
      final path = Path()..moveTo(outline.first.dx, outline.first.dy);
      for (final point in outline.skip(1)) {
        path.lineTo(point.dx, point.dy);
      }
      path.close();
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = const Color(0xFF3D7EFF);
      canvas.drawPath(path, paint);
    }
    return recorder.endRecording();
  }

  List<Offset> _coarsePolygon(List<Offset> points) {
    if (points.length <= 96) {
      return points;
    }
    final step = (points.length / 96).ceil();
    final coarse = <Offset>[
      for (var index = 0; index < points.length; index += step) points[index],
    ];
    if (coarse.last != points.last) {
      coarse.add(points.last);
    }
    return coarse;
  }

  void _publishPreview() {
    final gesture = _gestureMatrix;
    final base = _gestureBaseMatrix;
    final origin = _stickerOriginBounds;
    if (gesture == null || base == null || origin == null) {
      return;
    }
    // gesture * base: lift picture → previous sticker pose → this gesture.
    final display = gesture.multiplied(base);
    final visual = _boundsThrough(display, origin);
    _selectionBounds = visual;
    _selectionLive.value = SelectionPreview(
      strokes: const [],
      bounds: visual,
      frameBounds: origin,
      outline: _stickerOutline,
      picture: _stickerPicture,
      transform: display.storage,
    );
  }

  Rect _boundsThrough(Matrix4 matrix, Rect bounds) {
    final corners = [
      bounds.topLeft,
      bounds.topRight,
      bounds.bottomRight,
      bounds.bottomLeft,
    ];
    var left = double.infinity;
    var top = double.infinity;
    var right = double.negativeInfinity;
    var bottom = double.negativeInfinity;
    for (final corner in corners) {
      final next = _through(matrix, corner);
      left = math.min(left, next.dx);
      top = math.min(top, next.dy);
      right = math.max(right, next.dx);
      bottom = math.max(bottom, next.dy);
    }
    return Rect.fromLTRB(left, top, right, bottom);
  }

  Offset _through(Matrix4 matrix, Offset point) {
    final m = matrix.storage;
    return Offset(
      m[0] * point.dx + m[4] * point.dy + m[12],
      m[1] * point.dx + m[5] * point.dy + m[13],
    );
  }

  double _widthScaleOf(Matrix4 matrix) {
    final m = matrix.storage;
    final scaleX = Offset(m[0], m[1]).distance;
    final scaleY = Offset(m[4], m[5]).distance;
    if (scaleX < 1e-6 || scaleY < 1e-6) {
      return 1;
    }
    return math.sqrt(scaleX * scaleY);
  }

  /// Bake the active gesture into the sticker only — do not write the note yet.
  void _finishSelectionGesture() {
    final origins = _gestureStrokes;
    final originTexts = _gestureTexts ?? const <TextBox>[];
    final gesture = _gestureMatrix;
    final base = _gestureBaseMatrix;
    if (origins != null && gesture != null && base != null) {
      _selectedTexts = [
        for (final box in originTexts)
          mapTextBox(box, (point) => _through(gesture, point)),
      ];
      _lassoOutline = [
        for (final point in _gestureOutline ?? const <Offset>[])
          _through(gesture, point),
      ];
      // Keep the lift-space outline; the display transform carries it.
      _stickerMatrix = gesture.multiplied(base);
      final origin = _stickerOriginBounds;
      if (origin != null) {
        _selectionBounds = _boundsThrough(_stickerMatrix!, origin);
      }
      final pageId = _selectionPageId;
      final layerId = _selectionLayerId;
      if (pageId != null && layerId != null) {
        for (final box in _selectedTexts) {
          _textDrafts[box.id] = (pageId: pageId, layerId: layerId, box: box);
        }
      }
    }
    _gestureStrokes = null;
    _gestureTexts = null;
    _gestureCenter = null;
    _gestureBounds = null;
    _gestureMatrix = null;
    _gestureBaseMatrix = null;
    _dragStart = null;
    _scaleHandle = null;
    _gestureOutline = null;
    if (_selectionLifted && _stickerOriginBounds != null) {
      // Keep the lift-time picture; only the cumulative matrix changes.
      _showSticker();
      if (originTexts.isNotEmpty) {
        setState(() {});
      }
      return;
    }
    _selectionLive.value = null;
  }

  List<StrokeObject> _selectionInkSnapshot() {
    final matrix = _stickerMatrix;
    if (matrix == null) return _selectedStrokes;
    final scale = _widthScaleOf(matrix);
    return [
      for (final stroke in _selectedStrokes)
        mapStroke(
          stroke,
          (point) => _through(matrix, point),
          widthScale: scale,
        ),
    ];
  }

  void _copySelection() {
    NoteClipboard.put(
      strokes: _selectionInkSnapshot(),
      texts: [for (final box in _selectedTexts) box],
    );
  }

  void _deleteSelection() {
    final pageId = _selectionPageId;
    final layerId = _selectionLayerId;
    final textIds = [for (final box in _selectedTexts) box.id];
    final strokeIds = _selectionLifted
        ? _selectionOriginIds
        : [for (final stroke in _selectedStrokes) stroke.id];
    _selectionLifted = false;
    setState(() {
      for (final id in textIds) {
        _textDrafts.remove(id);
      }
      _discardSticker();
    });
    final tombstone = [...strokeIds, ...textIds];
    if (pageId == null || layerId == null || tombstone.isEmpty) {
      return;
    }
    _commit(
      _MarkEdit(
        pageId: pageId,
        layerId: layerId,
        added: const [],
        tombstoned: tombstone,
      ),
    );
  }

  void _cutSelection() {
    _copySelection();
    _deleteSelection();
  }

  void _paste({bool fromArc = false}) {
    if (NoteClipboard.isEmpty) {
      if (fromArc) {
        _closeArc();
      }
      return;
    }
    final page = _note.pages.firstWhere((item) => item.id == _selectedPageId);
    final layer = _drawingLayer(page);
    if (layer == null) {
      return;
    }
    if (_selectionLifted) {
      _pasteStickerIntoNote();
      _discardSticker();
    }
    final strokes = [
      for (final stroke in NoteClipboard.strokes)
        _cloneStroke(stroke, id: newId()),
    ];
    final texts = [
      for (final box in NoteClipboard.texts)
        TextBox(
          id: newId(),
          version: 1,
          x: box.x,
          y: box.y,
          width: box.width,
          height: box.height,
          source: box.source,
        ),
    ];
    _selectionOriginIds = const [];
    // Clipboard paste becomes a sticker that is not yet in the note.
    _selectionPageId = page.id;
    _selectionLayerId = layer.id;
    _selectedStrokes = strokes;
    _selectedTexts = texts;
    _liftedTexts = const [];
    _selectionBounds = boundsOfObjects(strokes: strokes, texts: texts);
    _lassoOutline = const [];
    _stickerOutline = const [];
    _selectionLifted = true;
    for (final box in texts) {
      _textDrafts[box.id] = (pageId: page.id, layerId: layer.id, box: box);
    }
    _stickerOriginBounds = _selectionBounds;
    _stickerMatrix = null;
    _showSticker(rerecord: true);
    setState(() => _selectedPageId = page.id);
    if (fromArc) {
      _closeArc();
    }
  }

  /// Paste sticker ink back into the note, then drop the movable sticker.
  void _clearSelection() {
    if (_selectionLifted) {
      if (_gestureStrokes != null) {
        _finishSelectionGesture();
      }
      // Keep the sticker on screen for one frame while settled ink appears under it.
      final bridge = _selectionLive.value;
      final bridgePicture = _stickerPicture;
      _pasteStickerIntoNote();
      _selectionPageId = null;
      _selectionLayerId = null;
      _selectedStrokes = const [];
      _selectedTexts = const [];
      _liftedTexts = const [];
      _selectionBounds = null;
      _gestureStrokes = null;
      _gestureTexts = null;
      _gestureCenter = null;
      _gestureBounds = null;
      _gestureMatrix = null;
      _gestureBaseMatrix = null;
      _dragStart = null;
      _scaleHandle = null;
      _gestureOutline = null;
      _lassoOutline = const [];
      _stickerOutline = const [];
      _selectionLifted = false;
      _stickerOriginBounds = null;
      _stickerMatrix = null;
      _stickerPicture = null;
      if (bridge != null) {
        _selectionLive.value = bridge;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          bridgePicture?.dispose();
          return;
        }
        if (identical(_selectionLive.value, bridge)) {
          _selectionLive.value = null;
        }
        bridgePicture?.dispose();
      });
      return;
    }
    _discardSticker();
  }

  void _pasteStickerIntoNote() {
    final pageId = _selectionPageId;
    final layerId = _selectionLayerId;
    if (!_selectionLifted || pageId == null || layerId == null) {
      return;
    }
    final moved = <({TextBox before, TextBox after})>[];
    final created = <TextBox>[];
    for (final after in _selectedTexts) {
      TextBox? before;
      for (final item in _liftedTexts) {
        if (item.id == after.id) {
          before = item;
          break;
        }
      }
      if (before == null) {
        created.add(after);
        continue;
      }
      if (before.x != after.x ||
          before.y != after.y ||
          before.width != after.width ||
          before.height != after.height) {
        moved.add((before: before, after: after));
      } else {
        _textDrafts[after.id] = (pageId: pageId, layerId: layerId, box: after);
      }
    }
    if (_selectionOriginIds.isNotEmpty &&
        _stickerMatrix == null &&
        moved.isEmpty &&
        created.isEmpty) {
      _note = applyMarks(
        _note,
        pageId: pageId,
        layerId: layerId,
        restore: _selectionOriginIds,
      );
      _selectionLifted = false;
      return;
    }
    final added = _selectionInkSnapshot();
    final origins = _selectionOriginIds;
    _selectionLifted = false;
    if (added.isEmpty && moved.isEmpty && created.isEmpty) {
      return;
    }
    _commit(
      _MarkEdit(
        pageId: pageId,
        layerId: layerId,
        added: added,
        tombstoned: origins,
        movedTexts: moved,
        createdTexts: created,
      ),
    );
  }

  void _discardSticker() {
    _selectionOriginIds = const [];
    _selectionPageId = null;
    _selectionLayerId = null;
    _selectedStrokes = const [];
    _selectedTexts = const [];
    _liftedTexts = const [];
    _selectionBounds = null;
    _gestureStrokes = null;
    _gestureTexts = null;
    _gestureCenter = null;
    _gestureBounds = null;
    _gestureMatrix = null;
    _gestureBaseMatrix = null;
    _dragStart = null;
    _scaleHandle = null;
    _gestureOutline = null;
    _lassoOutline = const [];
    _stickerOutline = const [];
    _selectionLifted = false;
    _stickerOriginBounds = null;
    _stickerMatrix = null;
    final recorded = _stickerPicture;
    _stickerPicture = null;
    _selectionLive.value = null;
    if (recorded != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => recorded.dispose());
    }
  }

  Future<void> _openSelectionMenu() async {
    if (_selectionMenuOpen) {
      Navigator.of(context).pop();
      return;
    }
    _selectionMenuOpen = true;
    final at = _tip ?? Offset(MediaQuery.sizeOf(context).width / 2, 160);
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(at.dx, at.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: const [
        PopupMenuItem(value: 'delete', child: Text('删除')),
        PopupMenuItem(value: 'copy', child: Text('复制')),
        PopupMenuItem(value: 'cut', child: Text('剪切')),
        PopupMenuItem(value: 'flip-horizontal', child: Text('水平镜像')),
        PopupMenuItem(value: 'flip-vertical', child: Text('垂直镜像')),
      ],
    );
    _selectionMenuOpen = false;
    if (!mounted || action == null) {
      return;
    }
    switch (action) {
      case 'delete':
        _deleteSelection();
      case 'copy':
        _copySelection();
      case 'cut':
        _cutSelection();
      case 'flip-horizontal':
        _mirrorSelection(horizontal: true);
      case 'flip-vertical':
        _mirrorSelection(horizontal: false);
    }
  }

  StrokeObject _cloneStroke(StrokeObject stroke, {String? id}) {
    return StrokeObject(
      id: id ?? stroke.id,
      tool: stroke.tool,
      color: stroke.color,
      baseWidth: stroke.baseWidth,
      points: stroke.points,
      finalized: true,
      dashCycle: stroke.dashCycle,
      dashRatio: stroke.dashRatio,
      dashOffset: stroke.dashOffset,
    );
  }

  void _eraseStart(String pageId, Offset point) {
    _endMoving();
    if (_selectionBounds != null) {
      setState(_clearSelection);
    }
    final page = _note.pages.firstWhere((item) => item.id == pageId);
    final layer = _drawingLayer(page);
    if (layer == null) {
      return;
    }
    _eraser
      ..clear()
      ..add(point);
    _eraserPageId = pageId;
    _eraserLayerId = layer.id;
    _regionBase = _tool == InkTool.regionEraser ? layer : null;
    _regionPieces.clear();
    _regionLocator = _regionBase == null ? null : _indexFor(page, layer);
    if (_regionBase != null) {
      _previewRegion(pageId, [point]);
    } else {
      _fadeTouched(page, layer.id, [point]);
    }
  }

  void _eraseMove(String pageId, Offset point) {
    if (_eraserPageId != pageId || _eraser.isEmpty) {
      return;
    }
    if ((point - _eraser.last).distance < 1) {
      return;
    }
    final previous = _eraser.last;
    _eraser.add(point);
    if (_tool == InkTool.regionEraser) {
      _previewRegion(pageId, [previous, point]);
      return;
    }
    final page = _note.pages.firstWhere((item) => item.id == pageId);
    final layerId = _eraserLayerId;
    if (layerId == null) {
      return;
    }
    _fadeTouched(page, layerId, [previous, point]);
  }

  void _eraseEnd(String pageId) {
    final path = List<Offset>.of(_eraser);
    final layerId = _eraserLayerId;
    _eraser.clear();
    _eraserPageId = null;
    _eraserLayerId = null;
    if (path.isEmpty || layerId == null) {
      _fading.value = const StrokeFade();
      return;
    }
    final added = <StrokeObject>[];
    final tombstoned = <String>[];
    if (_tool == InkTool.objectEraser) {
      final hits = [
        for (final stroke in _fading.value.strokes)
          if (_fading.value.pageId == pageId) stroke,
      ];
      if (hits.isEmpty) {
        _fading.value = const StrokeFade();
        return;
      }
      tombstoned.addAll([for (final stroke in hits) stroke.id]);
      _commit(
        _MarkEdit(
          pageId: pageId,
          layerId: layerId,
          added: added,
          tombstoned: tombstoned,
        ),
      );
      _fading.value = const StrokeFade();
      return;
    }
    _fading.value = const StrokeFade();
    tombstoned.addAll(_regionPieces.keys);
    added.addAll(_regionPieces.values.expand((pieces) => pieces));
    _regionBase = null;
    _regionPieces.clear();
    if (tombstoned.isEmpty) {
      return;
    }
    _commit(
      _MarkEdit(
        pageId: pageId,
        layerId: layerId,
        added: added,
        tombstoned: tombstoned,
      ),
    );
  }

  void _previewRegion(String pageId, List<Offset> path) {
    final base = _regionBase;
    if (base == null) return;
    var changed = false;
    final query = Rect.fromPoints(path.first, path.last).inflate(_eraserRadius);
    for (final original in _regionLocator!.near(
      query,
      base.deletedObjectIds.toSet(),
    )) {
      final current = _regionPieces[original.id] ?? [original];
      final next = <StrokeObject>[];
      var touched = false;
      for (final stroke in current) {
        final pieces = eraseRegion(stroke, path, radius: _eraserRadius);
        touched |= pieces != null;
        next.addAll(pieces ?? [stroke]);
      }
      if (touched) {
        _regionPieces[original.id] = next;
        changed = true;
      }
    }
    if (!changed) return;
    _note = OpenNote(
      directoryName: _note.directoryName,
      manifest: _note.manifest,
      pages: [
        for (final page in _note.pages)
          if (page.id != pageId)
            page
          else
            page.updateLayer(
              base.id,
              (_) => base.copyWith(
                strokeCache: {
                  ...base.strokeCache,
                  for (final pieces in _regionPieces.values)
                    for (final stroke in pieces) stroke.id: stroke,
                },
                objects: [
                  for (final object in base.objects) ...[
                    object,
                    if (object is Map)
                      for (final stroke
                          in _regionPieces[object['id']] ?? <StrokeObject>[])
                        stroke.toJson(),
                  ],
                ],
                deletedObjectIds: [
                  ...base.deletedObjectIds,
                  ..._regionPieces.keys,
                ],
              ),
            ),
      ],
    );
    setState(() {});
  }

  List<StrokeObject> _editableStrokes(PageFile page, String layerId) {
    final layer = page.layers.where((item) => item.id == layerId);
    if (layer.isEmpty) {
      return const [];
    }
    final cached = _layerGeometry[layer.single];
    if (cached != null) return cached;
    final deleted = layer.single.deletedObjectIds.toSet();
    final found = <StrokeObject>[];
    for (final object in layer.single.objects) {
      if (object is! Map || object['type'] != 'stroke') continue;
      final id = object['id'];
      if (id is! String || deleted.contains(id)) continue;
      final stroke =
          _geometry[id] ??
          layer.single.strokeCache[id] ??
          strokeFromObject(object);
      if (stroke != null && stroke.finalized) {
        _geometry[id] = stroke;
        found.add(stroke);
      }
    }
    _layerGeometry[layer.single] = found;
    return found;
  }

  _InkLocator _indexFor(PageFile page, LayerFile layer) {
    final index = _indices.putIfAbsent((
      page.id,
      layer.id,
    ), () => _InkLocator());
    if (!identical(index.source, layer.objects) ||
        !identical(index.deleted, layer.deletedObjectIds)) {
      index.source = layer.objects;
      index.deleted = layer.deletedObjectIds;
      index.index.sync(_editableStrokes(page, layer.id));
    }
    return index;
  }

  void _fadeTouched(PageFile page, String layerId, List<Offset> path) {
    if (path.isEmpty) {
      return;
    }
    final layer = page.layers.where((item) => item.id == layerId);
    if (layer.isEmpty) {
      return;
    }
    final objects = layer.single.objects;
    if (_locator == null ||
        !identical(_locator!.source, objects) ||
        _locatorPageId != page.id ||
        _locatorLayerId != layerId) {
      _locator = _indexFor(page, layer.single);
      _locatorPageId = page.id;
      _locatorLayerId = layerId;
    }
    final query = Rect.fromPoints(path.first, path.last).inflate(_eraserRadius);
    final deleted = layer.single.deletedObjectIds.toSet();
    final byId = {
      for (final stroke in _fading.value.strokes) stroke.id: stroke,
    };
    var changed = false;
    for (final stroke in _locator!.near(query, deleted)) {
      if (byId.containsKey(stroke.id)) {
        continue;
      }
      if (strokeHitsEraser(stroke, path, radius: _eraserRadius, near: query)) {
        byId[stroke.id] = stroke;
        changed = true;
      }
    }
    if (changed) {
      _fading.value = StrokeFade(
        pageId: page.id,
        strokes: byId.values.toList(),
      );
    }
  }

  void _commit(_MarkEdit edit) {
    _undoStack.add(edit);
    _redoStack.clear();
    if (edit.added.isNotEmpty || edit.tombstoned.isNotEmpty) {
      _note = applyMarks(
        _note,
        pageId: edit.pageId,
        layerId: edit.layerId,
        add: edit.added,
        tombstone: edit.tombstoned,
      );
    }
    for (final item in edit.movedTexts) {
      _textDrafts[item.after.id] = (
        pageId: edit.pageId,
        layerId: edit.layerId,
        box: item.after,
      );
      _persistText(edit.pageId, edit.layerId, item.after);
    }
    for (final box in edit.createdTexts) {
      _textDrafts[box.id] = (
        pageId: edit.pageId,
        layerId: edit.layerId,
        box: box,
      );
      _persistText(edit.pageId, edit.layerId, box);
    }
    setState(() {});
    if (edit.added.isEmpty && edit.tombstoned.isEmpty) {
      return;
    }
    final snapshot = edit;
    final noteSnapshot = _note;
    _queueSave(() async {
      await widget.vault.changeMarks(
        noteSnapshot,
        pageId: snapshot.pageId,
        layerId: snapshot.layerId,
        add: snapshot.added,
        tombstone: snapshot.tombstoned,
      );
      final store = widget.vault;
      if (store is StrokeRecoveryStore) {
        for (final stroke in snapshot.added) {
          await (store as StrokeRecoveryStore).finishCheckpoint(
            noteSnapshot.directoryName,
            pageId: snapshot.pageId,
            strokeId: stroke.id,
          );
        }
      }
    });
  }

  void _undo() {
    if (_selectionLifted || _selectionBounds != null) {
      setState(_clearSelection);
    }
    if (_undoStack.isEmpty) return;
    final edit = _undoStack.removeLast();
    _redoStack.add(edit);
    _retint(edit, undo: true);
  }

  void _redo() {
    if (_selectionLifted || _selectionBounds != null) {
      setState(_clearSelection);
    }
    if (_redoStack.isEmpty) {
      return;
    }
    final edit = _redoStack.removeLast();
    _undoStack.add(edit);
    _retint(edit, undo: false);
  }

  void _retint(_MarkEdit edit, {required bool undo}) {
    for (final item in edit.movedTexts) {
      final box = undo ? item.before : item.after;
      setState(() {
        _textDrafts[box.id] = (
          pageId: edit.pageId,
          layerId: edit.layerId,
          box: box,
        );
      });
      _persistText(edit.pageId, edit.layerId, box);
    }
    if (edit.textBefore != null && edit.textAfter != null) {
      final box = undo ? edit.textBefore! : edit.textAfter!;
      setState(() {
        _textDrafts[box.id] = (
          pageId: edit.pageId,
          layerId: edit.layerId,
          box: box,
        );
      });
      _persistText(edit.pageId, edit.layerId, box);
      if (edit.added.isEmpty &&
          edit.tombstoned.isEmpty &&
          edit.createdTexts.isEmpty) {
        return;
      }
    }
    final created = [for (final box in edit.createdTexts) box.id];
    if (undo) {
      for (final id in created) {
        _textDrafts.remove(id);
      }
    } else {
      for (final box in edit.createdTexts) {
        _textDrafts[box.id] = (
          pageId: edit.pageId,
          layerId: edit.layerId,
          box: box,
        );
        _persistText(edit.pageId, edit.layerId, box);
      }
    }
    final tombstone = [
      ...undo ? [for (final stroke in edit.added) stroke.id] : edit.tombstoned,
      if (undo) ...created,
    ];
    final restore = [
      ...undo ? edit.tombstoned : [for (final stroke in edit.added) stroke.id],
      if (!undo) ...created,
    ];
    if (tombstone.isEmpty && restore.isEmpty) {
      return;
    }
    _note = applyMarks(
      _note,
      pageId: edit.pageId,
      layerId: edit.layerId,
      tombstone: tombstone,
      restore: restore,
    );
    setState(() {});
    final pageId = edit.pageId;
    final layerId = edit.layerId;
    final tombstoneIds = tombstone;
    final restoreIds = restore;
    final noteSnapshot = _note;
    _queueSave(() async {
      await widget.vault.changeMarks(
        noteSnapshot,
        pageId: pageId,
        layerId: layerId,
        tombstone: tombstoneIds,
        restore: restoreIds,
      );
    });
  }

  LayerFile? _drawingLayer(PageFile page) {
    for (final layer in page.layers.reversed) {
      if (layer.visible && !layer.locked) {
        return layer;
      }
    }
    return null;
  }

  Future<void> _deletePage() async {
    if (_note.pages.length < 2) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('至少要留下一页')));
      return;
    }
    final ok = await askConfirm(context, heading: '删除此页', body: '这一页会从笔记里去掉。');
    if (!ok || !mounted) {
      return;
    }
    final pages = _note.pages;
    final index = pages.indexWhere((page) => page.id == _selectedPageId);
    final neighbor = pages[index > 0 ? index - 1 : index + 1].id;
    final pageId = _selectedPageId;
    await _replace(
      () => widget.vault.deletePage(_note, pageId: pageId),
      selectPageId: neighbor,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _undoStack.removeWhere((edit) => edit.pageId == pageId);
      _redoStack.removeWhere((edit) => edit.pageId == pageId);
      if (_session?.pageId == pageId) {
        _session = null;
        _preview = null;
        _previewPageId = null;
        _live.value = null;
      }
    });
  }

  Future<void> _deleteNote() async {
    final ok = await askConfirm(
      context,
      heading: '删除笔记',
      body: '「${_note.title}」会从笔记库里去掉。',
    );
    if (!ok || !mounted) {
      return;
    }
    _closeArc();
    _settleEdits();
    await _writes.flush();
    await widget.vault.deleteNote(_note);
    _closing = true;
    if (!mounted) {
      return;
    }
    Navigator.of(context).pop();
  }

  void _toggleArc(Offset? globalPosition) {
    if (_selectionMenuOpen) {
      Navigator.of(context).pop();
      return;
    }
    if (_tool == InkTool.text) {
      final pageId = _textHoverPageId;
      final local = _textHoverLocal;
      final hit = pageId == null || local == null
          ? null
          : _boxAt(pageId, local);
      if (hit != null) {
        if (_selectedTextId == hit.id) {
          setState(() {
            _selectedTextId = null;
            _editingTextId = null;
          });
          return;
        }
        _selectText(pageId!, hit.id);
        return;
      }
      if (_selectedTextId != null) {
        setState(() => _selectedTextId = null);
        return;
      }
    }
    if (_presetArc != null && globalPosition != null) {
      for (final target in _presetTargets) {
        if (target.rect.inflate(8).contains(globalPosition)) {
          target.onLong();
          return;
        }
      }
    }
    if (_arc != null) {
      _closeArc();
      return;
    }
    if (_selectionBounds != null && _selectionPageId == _selectedPageId) {
      _openSelectionMenu();
      return;
    }
    final media = MediaQuery.of(context);
    final at =
        globalPosition ??
        _tip ??
        Offset(media.size.width / 2, media.size.height / 2);
    _arcCenter = at;
    _arc = OverlayEntry(
      builder: (context) => ToolArc(
        center: at,
        onDismiss: _closeArc,
        actions: [
          ToolArcAction(
            id: 'arc-pen',
            icon: Icons.edit,
            label: '钢笔',
            selected: _tool == InkTool.pen,
            onPressed: () => _selectArcTool(InkTool.pen),
          ),
          ToolArcAction(
            id: 'arc-highlighter',
            icon: Icons.border_color,
            label: '荧光笔',
            selected: _isHighlighter,
            onPressed: () => _selectArcTool(InkTool.highlighter),
          ),
          ToolArcAction(
            id: 'arc-text',
            icon: Icons.text_fields,
            label: '文字',
            selected: _tool == InkTool.text,
            onPressed: () => _selectArcTool(InkTool.text),
          ),
          ToolArcAction(
            id: 'arc-eraser',
            icon: Icons.auto_fix_off,
            label: '橡皮',
            selected:
                _tool == InkTool.objectEraser || _tool == InkTool.regionEraser,
            onPressed: () => _selectArcTool(_eraserTool),
          ),
          ToolArcAction(
            id: 'arc-lasso',
            icon: Icons.gesture,
            label: '套索',
            selected: _tool == InkTool.lasso,
            onPressed: () => _selectArcTool(InkTool.lasso),
          ),
          ToolArcAction(
            id: 'arc-paste',
            icon: Icons.content_paste,
            label: '粘贴',
            onPressed: () => _paste(fromArc: true),
          ),
          ToolArcAction(
            id: 'arc-undo',
            icon: Icons.undo,
            label: '撤销',
            onPressed: _undoStack.isEmpty ? null : () => _historyFromArc(_undo),
          ),
          ToolArcAction(
            id: 'arc-redo',
            icon: Icons.redo,
            label: '重做',
            onPressed: _redoStack.isEmpty ? null : () => _historyFromArc(_redo),
          ),
        ],
      ),
    );
    Overlay.of(context).insert(_arc!);
    if (_hasNextToolbar) {
      _openSecondary(_tool);
    }
  }

  InkTool get _eraserTool => _eraserKind == EraserKind.region
      ? InkTool.regionEraser
      : InkTool.objectEraser;

  bool get _hasNextToolbar {
    return switch (_tool) {
      InkTool.pen || InkTool.highlighter => _presetArc == null,
      InkTool.objectEraser ||
      InkTool.regionEraser ||
      InkTool.lasso => _optionsArc == null,
      _ => false,
    };
  }

  void _selectArcTool(InkTool tool) {
    if (_tool != tool) {
      _flushEditing();
      final session = _session;
      if (session != null) _endStroke(session.pageId);
      final eraserPage = _eraserPageId;
      if (eraserPage != null) _eraseEnd(eraserPage);
      if ((tool == InkTool.objectEraser || tool == InkTool.regionEraser) &&
          _tool != InkTool.objectEraser &&
          _tool != InkTool.regionEraser) {
        _toolBeforeEraser = _tool;
      }
      setState(() {
        if (_tool == InkTool.lasso) {
          _clearSelection();
        }
        _tool = tool;
        if (tool == InkTool.objectEraser || tool == InkTool.regionEraser) {
          _eraserKind = tool == InkTool.regionEraser
              ? EraserKind.region
              : EraserKind.stroke;
        }
        if (tool != InkTool.text) {
          _editingTextId = null;
          _selectedTextId = null;
        }
      });
      _closeSecondary();
      if (_hasNextToolbar) {
        _openSecondary(tool);
      }
      _arc?.markNeedsBuild();
      return;
    }
    if (_hasNextToolbar) {
      _openSecondary(tool);
    }
    _arc?.markNeedsBuild();
  }

  void _openSecondary(InkTool tool) {
    if (tool == InkTool.pen || tool == InkTool.highlighter) {
      _closeOptionsArc();
      _openPresetArc();
      return;
    }
    if (tool == InkTool.objectEraser ||
        tool == InkTool.regionEraser ||
        tool == InkTool.lasso) {
      _closePresetArc();
      _openOptionsArc();
    }
  }

  void _onDoubleTap() {
    if (_stylus.doubleTap != DoubleTapAction.eraser) {
      return;
    }
    final eraser =
        _tool == InkTool.objectEraser || _tool == InkTool.regionEraser;
    if (eraser) {
      _chooseTool(_toolBeforeEraser ?? InkTool.pen);
      return;
    }
    _toolBeforeEraser = _tool;
    _chooseTool(_eraserTool);
  }

  void _openOptionsArc() {
    final raw = _arcCenter;
    if (raw == null) {
      return;
    }
    _closeOptionsArc();
    final media = MediaQuery.of(context);
    final center = ToolArc.placedCenter(raw, media.size, media.padding);
    final eraser =
        _tool == InkTool.objectEraser || _tool == InkTool.regionEraser;
    _optionsArc = OverlayEntry(
      builder: (context) => ChoiceArc(
        key: ValueKey(eraser ? 'eraser-options' : 'lasso-options'),
        center: center,
        items: eraser ? _eraserArcItems() : _lassoArcItems(),
      ),
    );
    Overlay.of(context).insert(_optionsArc!);
  }

  List<ChoiceArcItem> _eraserArcItems() {
    const radii = [8.0, 14.0, 24.0, 40.0];
    return [
      ChoiceArcItem(
        label: '笔画',
        selected: _tool == InkTool.objectEraser,
        onPressed: () => _setEraserKind(EraserKind.stroke),
      ),
      ChoiceArcItem(
        label: '区域',
        selected: _tool == InkTool.regionEraser,
        onPressed: () => _setEraserKind(EraserKind.region),
      ),
      for (final radius in radii)
        ChoiceArcItem(
          label: radius.toStringAsFixed(0),
          selected: (_eraserRadius - radius).abs() < 0.5,
          onPressed: () {
            setState(() => _eraserRadius = radius);
            _optionsArc?.markNeedsBuild();
          },
        ),
    ];
  }

  List<ChoiceArcItem> _lassoArcItems() {
    return [
      ChoiceArcItem(
        label: '自由',
        selected: _lassoShape == LassoShape.free,
        onPressed: () => _setLassoShape(LassoShape.free),
      ),
      ChoiceArcItem(
        label: '矩形',
        selected: _lassoShape == LassoShape.rect,
        onPressed: () => _setLassoShape(LassoShape.rect),
      ),
      ChoiceArcItem(
        label: '笔画',
        selected: _lassoTargets.contains(LassoTarget.stroke),
        onPressed: () => _toggleLassoTarget(
          LassoTarget.stroke,
          !_lassoTargets.contains(LassoTarget.stroke),
        ),
      ),
      ChoiceArcItem(
        label: '文本',
        selected: _lassoTargets.contains(LassoTarget.text),
        onPressed: () => _toggleLassoTarget(
          LassoTarget.text,
          !_lassoTargets.contains(LassoTarget.text),
        ),
      ),
      ChoiceArcItem(
        label: '荧光笔',
        selected: _lassoTargets.contains(LassoTarget.highlighter),
        onPressed: () => _toggleLassoTarget(
          LassoTarget.highlighter,
          !_lassoTargets.contains(LassoTarget.highlighter),
        ),
      ),
    ];
  }

  void _setEraserKind(EraserKind kind) {
    setState(() {
      _eraserKind = kind;
      _tool = _eraserTool;
    });
    _optionsArc?.markNeedsBuild();
  }

  void _setLassoShape(LassoShape shape) {
    setState(() => _lassoShape = shape);
    _optionsArc?.markNeedsBuild();
  }

  void _toggleLassoTarget(LassoTarget target, bool on) {
    setState(() {
      if (on) {
        _lassoTargets.add(target);
      } else {
        _lassoTargets.remove(target);
      }
    });
    _optionsArc?.markNeedsBuild();
  }

  void _closeOptionsArc() {
    _optionsArc?.remove();
    _optionsArc = null;
  }

  void _closeSecondary() {
    _closePresetArc();
    _closeOptionsArc();
  }

  Future<void> _openSettings() {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => SettingsPage(
          load: () {
            final vault = widget.vault;
            if (vault is Vault) {
              return vault.readPenPalette(highlighter: _isHighlighter);
            }
            return Future.value(_pen);
          },
          save: (palette) {
            _applyPen(palette);
            return Future.value();
          },
          loadStylus: () {
            final vault = widget.vault;
            if (vault is Vault) {
              return vault.readStylusPreferences();
            }
            return Future.value(_stylus);
          },
          saveStylus: (preferences) {
            setState(() => _stylus = preferences);
            final vault = widget.vault;
            if (vault is Vault) {
              return vault.writeStylusPreferences(preferences);
            }
            return Future.value();
          },
        ),
      ),
    );
  }

  void _penPressed() {
    if (_tool == InkTool.pen) {
      setState(() => _penBarOpen = !_penBarOpen);
      return;
    }
    _chooseTool(InkTool.pen);
  }

  void _eraserPressed() {
    final eraser =
        _tool == InkTool.objectEraser || _tool == InkTool.regionEraser;
    if (eraser) {
      setState(() => _eraserBarOpen = !_eraserBarOpen);
      return;
    }
    _chooseTool(_eraserTool);
  }

  void _lassoPressed() {
    if (_tool == InkTool.lasso) {
      setState(() => _lassoBarOpen = !_lassoBarOpen);
      return;
    }
    _chooseTool(InkTool.lasso);
  }

  void _openPresetArc() {
    final raw = _arcCenter;
    if (raw == null) {
      return;
    }
    _closePresetArc();
    final media = MediaQuery.of(context);
    final center = ToolArc.placedCenter(raw, media.size, media.padding);
    _presetArc = OverlayEntry(
      builder: (context) => PenPresetArc(
        palette: _pen,
        center: center,
        onChanged: _applyPen,
        onTargets: (targets) => _presetTargets = targets,
      ),
    );
    Overlay.of(context).insert(_presetArc!);
  }

  void _closePresetArc() {
    _presetArc?.remove();
    _presetArc = null;
    _presetTargets = const [];
  }

  void _applyPen(PenPalette palette) {
    final highlighter = _isHighlighter;
    if (highlighter) {
      _highlighterEpoch += 1;
    } else {
      _penEpoch += 1;
    }
    setState(() {
      if (highlighter) {
        _highlighterPalette = palette;
      } else {
        _penPalette = palette;
      }
    });
    _presetArc?.markNeedsBuild();
    final vault = widget.vault;
    if (vault is Vault) {
      _queueSave(
        () => vault.writePenPalette(palette, highlighter: highlighter),
      );
    }
  }

  void _chooseTool(InkTool tool) {
    if (tool != _tool) {
      _flushEditing();
      final session = _session;
      if (session != null) _endStroke(session.pageId);
      final pageId = _eraserPageId;
      if (pageId != null) _eraseEnd(pageId);
    }
    final leavingEraser =
        _tool == InkTool.objectEraser || _tool == InkTool.regionEraser;
    final enteringEraser =
        tool == InkTool.objectEraser || tool == InkTool.regionEraser;
    if (!leavingEraser && enteringEraser) {
      _toolBeforeEraser = _tool;
    }
    _closeArc();
    setState(() {
      if (_tool == InkTool.lasso && tool != InkTool.lasso) {
        _clearSelection();
      }
      _penBarOpen = false;
      _eraserBarOpen = false;
      _lassoBarOpen = false;
      _tool = tool;
      if (tool == InkTool.objectEraser || tool == InkTool.regionEraser) {
        _eraserKind = tool == InkTool.regionEraser
            ? EraserKind.region
            : EraserKind.stroke;
      }
      if (tool != InkTool.text) {
        _editingTextId = null;
        _selectedTextId = null;
      }
    });
  }

  List<({String pageId, TextBox box})> _textBoxes() {
    final boxes = <({String pageId, TextBox box})>[];
    final seen = <String>{};
    for (final page in _note.pages) {
      for (final layer in page.layers) {
        if (!layer.visible) {
          continue;
        }
        final deleted = layer.deletedObjectIds.toSet();
        for (final object in layer.objects) {
          final box = TextBox.fromObject(object);
          if (box == null || deleted.contains(box.id)) {
            continue;
          }
          final draft = _textDrafts[box.id];
          final shown = draft == null ? box : draft.box;
          if (seen.add(shown.id)) {
            boxes.add((pageId: page.id, box: shown));
          }
        }
      }
    }
    for (final draft in _textDrafts.values) {
      final pages = _note.pages.where((page) => page.id == draft.pageId);
      if (pages.isEmpty) continue;
      final layers = pages.single.layers.where(
        (layer) => layer.id == draft.layerId,
      );
      if (layers.isEmpty ||
          !layers.single.visible ||
          layers.single.deletedObjectIds.contains(draft.box.id)) {
        continue;
      }
      if (seen.add(draft.box.id)) {
        boxes.add((pageId: draft.pageId, box: draft.box));
      }
    }
    return boxes;
  }

  TextBox? _boxAt(String pageId, Offset point) {
    final boxes = [
      for (final item in _textBoxes())
        if (item.pageId == pageId) item.box,
    ];
    for (final box in boxes.reversed) {
      if (box.rect.contains(point)) {
        return box;
      }
    }
    return null;
  }

  void _blurText() {
    _flushEditing();
    setState(() {
      _editingTextId = null;
      _selectedTextId = null;
    });
    FocusManager.instance.primaryFocus?.unfocus();
  }

  void _createText(String pageId, Rect rect) {
    _flushEditing();
    final page = _note.pages.firstWhere((item) => item.id == pageId);
    final layer = _drawingLayer(page);
    if (layer == null) {
      return;
    }
    final box = TextBox(
      id: newId(),
      version: 1,
      x: rect.left,
      y: rect.top,
      width: rect.width,
      height: rect.height,
      source: '',
    );
    setState(() {
      _selectedPageId = pageId;
      _selectedTextId = box.id;
      _editingTextId = box.id;
      _textDrafts[box.id] = (pageId: pageId, layerId: layer.id, box: box);
    });
    _commit(
      _MarkEdit(
        pageId: pageId,
        layerId: layer.id,
        added: const [],
        tombstoned: const [],
        createdTexts: [box],
      ),
    );
  }

  void _selectText(String pageId, String id) {
    if (_editingTextId != null && _editingTextId != id) {
      _flushEditing();
    }
    setState(() {
      _selectedPageId = pageId;
      _selectedTextId = id;
      _editingTextId = null;
    });
  }

  void _editText(String pageId, String id) {
    if (_editingTextId == id) {
      return;
    }
    if (_editingTextId != null) {
      _flushEditing();
    }
    final stored = _storedText(id);
    if (stored != null) {
      _editOrigin[id] = stored;
    }
    setState(() {
      _selectedPageId = pageId;
      _selectedTextId = id;
      _editingTextId = id;
    });
  }

  void _rememberText(
    String pageId,
    String layerId,
    TextBox before,
    TextBox after,
  ) {
    if (before.source == after.source &&
        before.x == after.x &&
        before.y == after.y &&
        before.width == after.width &&
        before.height == after.height) {
      _persistText(pageId, layerId, after);
      return;
    }
    _undoStack.add(
      _MarkEdit(
        pageId: pageId,
        layerId: layerId,
        added: const [],
        tombstoned: const [],
        textBefore: before,
        textAfter: after,
      ),
    );
    _redoStack.clear();
    _persistText(pageId, layerId, after);
  }

  void _deleteText(String pageId, String id) {
    final layerId = _textDrafts[id]?.layerId ?? _layerOfText(id);
    if (layerId == null) {
      return;
    }
    setState(() {
      _textDrafts.remove(id);
      if (_editingTextId == id) {
        _editingTextId = null;
      }
      if (_selectedTextId == id) {
        _selectedTextId = null;
      }
    });
    _commit(
      _MarkEdit(
        pageId: pageId,
        layerId: layerId,
        added: const [],
        tombstoned: [id],
      ),
    );
  }

  void _moveText(String pageId, String id, Offset delta) {
    final current = _textDrafts[id];
    final stored = _storedText(id);
    final box = current?.box ?? stored;
    final layerId = current?.layerId ?? _layerOfText(id);
    if (box == null || layerId == null) {
      return;
    }
    _gestureBefore.putIfAbsent(id, () => stored ?? box);
    final page = _note.pages.firstWhere((item) => item.id == pageId);
    final next = box.copyWith(
      x: (box.x + delta.dx).clamp(0.0, math.max(0.0, page.width - box.width)),
      y: (box.y + delta.dy).clamp(0.0, math.max(0.0, page.height - box.height)),
    );
    setState(() {
      _textDrafts[id] = (pageId: pageId, layerId: layerId, box: next);
    });
  }

  void _moveTextEnd(String pageId, String id) {
    final draft = _textDrafts[id];
    final before = _gestureBefore.remove(id);
    if (draft == null) {
      return;
    }
    if (before == null) {
      _persistText(pageId, draft.layerId, draft.box);
      return;
    }
    _rememberText(pageId, draft.layerId, before, draft.box);
  }

  TextBox? _storedText(String id) {
    for (final page in _note.pages) {
      for (final layer in page.layers) {
        for (final object in layer.objects) {
          final box = TextBox.fromObject(object);
          if (box?.id == id) {
            return box;
          }
        }
      }
    }
    return null;
  }

  void _draftText(TextBox box, String source) {
    final current = _textDrafts[box.id];
    final pageId = current?.pageId ?? _pageOfText(box.id);
    final layerId = current?.layerId ?? _layerOfText(box.id);
    if (pageId == null || layerId == null) {
      return;
    }
    final base = current?.box ?? box;
    _textDrafts[box.id] = (
      pageId: pageId,
      layerId: layerId,
      box: base.copyWith(source: source),
    );
  }

  void _flushEditing() {
    final id = _editingTextId;
    if (id == null) {
      return;
    }
    _editingTextId = null;
    final draft = _textDrafts[id];
    final before = _editOrigin.remove(id);
    if (draft == null) {
      return;
    }
    if (before == null) {
      _persistText(draft.pageId, draft.layerId, draft.box);
      return;
    }
    _rememberText(draft.pageId, draft.layerId, before, draft.box);
  }

  void _commitText(TextBox box, String source) {
    final draft = _textDrafts[box.id];
    final pageId = draft?.pageId ?? _pageOfText(box.id);
    final layerId = draft?.layerId ?? _layerOfText(box.id);
    if (pageId == null || layerId == null) {
      return;
    }
    final before = _editOrigin.remove(box.id) ?? _storedText(box.id) ?? box;
    final next = (draft?.box ?? box).copyWith(source: source);
    setState(() {
      _editingTextId = null;
      if (_tool == InkTool.text) {
        _selectedTextId = next.id;
      }
      _textDrafts[next.id] = (pageId: pageId, layerId: layerId, box: next);
    });
    _rememberText(pageId, layerId, before, next);
  }

  void _resizeText(TextBox box, double width, double height) {
    final draft = _textDrafts[box.id];
    final pageId = draft?.pageId ?? _pageOfText(box.id);
    final layerId = draft?.layerId ?? _layerOfText(box.id);
    if (pageId == null || layerId == null) {
      return;
    }
    final before = draft?.box ?? box;
    final page = _note.pages.firstWhere((item) => item.id == pageId);
    final next = before.copyWith(
      width: width.clamp(64.0, math.max(64.0, page.width - before.x)),
      height: height.clamp(40.0, math.max(40.0, page.height - before.y)),
    );
    setState(() {
      _textDrafts[next.id] = (pageId: pageId, layerId: layerId, box: next);
    });
    _rememberText(pageId, layerId, before, next);
  }

  // ignore: unused_element
  Future<void> _fixText(String pageId, String id) async {
    final box = _textDrafts[id]?.box ?? _storedText(id);
    final layerId = _textDrafts[id]?.layerId ?? _layerOfText(id);
    if (box == null || layerId == null) {
      return;
    }
    final strokes = await fixTextBox(box);
    if (!mounted) {
      return;
    }
    setState(() {
      _textDrafts.remove(id);
      _selectedTextId = null;
      _editingTextId = null;
    });
    _commit(
      _MarkEdit(
        pageId: pageId,
        layerId: layerId,
        added: strokes,
        tombstoned: [id],
      ),
    );
  }

  String? _pageOfText(String id) {
    for (final page in _note.pages) {
      for (final layer in page.layers) {
        for (final object in layer.objects) {
          if (TextBox.fromObject(object)?.id == id) {
            return page.id;
          }
        }
      }
    }
    return null;
  }

  String? _layerOfText(String id) {
    for (final page in _note.pages) {
      for (final layer in page.layers) {
        for (final object in layer.objects) {
          if (TextBox.fromObject(object)?.id == id) {
            return layer.id;
          }
        }
      }
    }
    return null;
  }

  void _persistText(String pageId, String layerId, TextBox box) {
    _note = OpenNote(
      directoryName: _note.directoryName,
      manifest: _note.manifest,
      pages: [
        for (final page in _note.pages)
          if (page.id != pageId)
            page
          else
            page.updateLayer(
              layerId,
              (layer) =>
                  layer.copyWith(objects: replaceTextBox(layer.objects, box)),
            ),
      ],
    );
    final snapshot = _note;
    _queueSave(() async {
      await widget.vault.saveTextBox(
        snapshot,
        pageId: pageId,
        layerId: layerId,
        box: box,
      );
    });
  }

  void _historyFromArc(void Function() action) {
    action();
    _arc?.markNeedsBuild();
  }

  void _closeArc() {
    _closeSecondary();
    _arc?.remove();
    _arc = null;
    _arcCenter = null;
  }

  Future<void> _insert({required bool before}) async {
    final currentId = _selectedPage.id;
    final beforeIds = _note.pages.map((page) => page.id).toSet();
    await _replace(
      () => widget.vault.insertPage(_note, pageId: currentId, before: before),
    );
    final inserted = _note.pages
        .map((page) => page.id)
        .where((id) => !beforeIds.contains(id));
    if (inserted.isNotEmpty) {
      setState(() => _selectedPageId = inserted.first);
    }
  }

  @override
  Widget build(BuildContext context) {
    final page = _selectedPage;
    return PopScope(
      canPop: _closing,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _leaveNote();
      },
      child: AbsorbPointer(
        absorbing: _structureBusy || _savingExit,
        child: Scaffold(
          key: _scaffoldKey,
          appBar: AppBar(
            title: Text(_note.title),
            actions: [
              IconButton(
                onPressed: _rename,
                tooltip: '重命名',
                icon: const Icon(Icons.drive_file_rename_outline),
              ),
              IconButton(
                onPressed: _deleteNote,
                tooltip: '删除笔记',
                icon: const Icon(Icons.delete_outline),
              ),
              IconButton(
                tooltip: '设置',
                onPressed: _openSettings,
                icon: const Icon(Icons.settings),
              ),
            ],
          ),
          endDrawer: Drawer(
            child: SafeArea(
              child: LayerPanel(
                page: page,
                onMove: (layerId, {required upward}) {
                  _replace(
                    () => widget.vault.moveLayer(
                      _note,
                      pageId: page.id,
                      layerId: layerId,
                      upward: upward,
                    ),
                  );
                },
                onVisible: (layerId, {required visible}) {
                  _replace(
                    () => widget.vault.setLayerVisible(
                      _note,
                      pageId: page.id,
                      layerId: layerId,
                      visible: visible,
                    ),
                  );
                },
                onLocked: (layerId, {required locked}) {
                  _replace(
                    () => widget.vault.setLayerLocked(
                      _note,
                      pageId: page.id,
                      layerId: layerId,
                      locked: locked,
                    ),
                  );
                },
              ),
            ),
          ),
          body: LayoutBuilder(
            builder: (context, constraints) {
              _scheduleCenter(constraints.biggest);
              return Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: _fingerDown,
                onPointerMove: _fingerMove,
                onPointerUp: _fingerUp,
                onPointerCancel: _fingerUp,
                child: PageCanvas(
                  pages: _note.pages,
                  selectedPageId: page.id,
                  transformation: _transform,
                  preview: _preview,
                  previewPageId: _previewPageId,
                  settledStrokes: const [],
                  live: _live,
                  tool: _tool,
                  hiddenIds: const {},
                  patches: _patches,
                  fading: _fading,
                  onSelectPage: (pageId) =>
                      setState(() => _selectedPageId = pageId),
                  onStrokeStart: _startStroke,
                  onStrokeMove: _moveStroke,
                  onStrokeEnd: _endStroke,
                  onEraseStart: _eraseStart,
                  onEraseMove: _eraseMove,
                  onEraseEnd: _eraseEnd,
                  textBoxes: _textBoxes(),
                  editingTextId: _editingTextId,
                  selectedTextId: _selectedTextId,
                  onTextCommit: _commitText,
                  onTextDraft: _draftText,
                  onTextResize: _resizeText,
                  onTextBlur: _blurText,
                  onSuppressPan: _suppressPan,
                  onTextCreate: _createText,
                  onTextSelect: _selectText,
                  onTextEdit: _editText,
                  onTextDelete: _deleteText,
                  onTextMove: _moveText,
                  onTextMoveEnd: _moveTextEnd,
                  onTextHover: (pageId, local, global) {
                    _tip = global;
                    _textHoverPageId = local == null ? null : pageId;
                    _textHoverLocal = local;
                  },
                  onTip: (tip) => _tip = tip,
                  viewScale: _tileScale,
                  onScaleSettled: _settleScale,
                  eraserRadius: _eraserRadius,
                  penWidth: _pen.width,
                  penColor: _pen.color,
                  selectionLive: _selectionLive,
                  onSelectionClear: () => setState(_clearSelection),
                  lassoPoints: _lassoPoints,
                  lassoOutline: _lassoOutline,
                  lassoRect: _lassoRect,
                  lassoLive: _lassoLive,
                  selectionHaptic: _stylus.selectionHaptic,
                  selectionBounds:
                      _selectedStrokes.isEmpty && _selectedTexts.isEmpty
                      ? null
                      : (_selectedPageId == _selectionPageId
                            ? _selectionBounds
                            : null),
                  selectionInk: const [],
                  onLassoStart: _lassoStart,
                  onLassoMove: _lassoMove,
                  onLassoEnd: _lassoEnd,
                  onSelectionMove: _selectionMove,
                  onSelectionMoveEnd: _finishSelectionGesture,
                  onSelectionScale: _selectionScale,
                  onSelectionScaleEnd: _finishSelectionGesture,
                  onSelectionRotate: _selectionRotate,
                  onSelectionRotateEnd: _finishSelectionGesture,
                  onSelectionMenu: _openSelectionMenu,
                ),
              );
            },
          ),
          bottomNavigationBar: Material(
            elevation: 2,
            child: SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if ((_tool == InkTool.pen || _tool == InkTool.highlighter) &&
                      _penBarOpen)
                    PenPresetBar(palette: _pen, onChanged: _applyPen),
                  if ((_tool == InkTool.objectEraser ||
                          _tool == InkTool.regionEraser) &&
                      _eraserBarOpen)
                    EraserOptionsBar(
                      region: _tool == InkTool.regionEraser,
                      radius: _eraserRadius,
                      onRegion: (region) {
                        setState(() {
                          _eraserKind = region
                              ? EraserKind.region
                              : EraserKind.stroke;
                          _tool = _eraserTool;
                        });
                      },
                      onRadius: (radius) =>
                          setState(() => _eraserRadius = radius),
                    ),
                  if (_tool == InkTool.lasso && _lassoBarOpen)
                    LassoOptionsBar(
                      rect: _lassoShape == LassoShape.rect,
                      strokes: _lassoTargets.contains(LassoTarget.stroke),
                      texts: _lassoTargets.contains(LassoTarget.text),
                      highlighters: _lassoTargets.contains(
                        LassoTarget.highlighter,
                      ),
                      onRect: (rect) => setState(
                        () => _lassoShape = rect
                            ? LassoShape.rect
                            : LassoShape.free,
                      ),
                      onStrokes: (on) => setState(() {
                        if (on) {
                          _lassoTargets.add(LassoTarget.stroke);
                        } else {
                          _lassoTargets.remove(LassoTarget.stroke);
                        }
                      }),
                      onTexts: (on) => setState(() {
                        if (on) {
                          _lassoTargets.add(LassoTarget.text);
                        } else {
                          _lassoTargets.remove(LassoTarget.text);
                        }
                      }),
                      onHighlighters: (on) => setState(() {
                        if (on) {
                          _lassoTargets.add(LassoTarget.highlighter);
                        } else {
                          _lassoTargets.remove(LassoTarget.highlighter);
                        }
                      }),
                    ),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        IconButton(
                          tooltip: '钢笔',
                          onPressed: _penPressed,
                          color: _tool == InkTool.pen
                              ? Theme.of(context).colorScheme.primary
                              : null,
                          icon: const Icon(Icons.edit),
                        ),
                        IconButton(
                          tooltip: '荧光笔',
                          onPressed: () {
                            if (_isHighlighter) {
                              setState(() => _penBarOpen = !_penBarOpen);
                            } else {
                              _chooseTool(InkTool.highlighter);
                            }
                          },
                          color: _isHighlighter
                              ? Theme.of(context).colorScheme.primary
                              : null,
                          icon: const Icon(Icons.border_color),
                        ),
                        IconButton(
                          tooltip: '文字',
                          onPressed: () => _chooseTool(InkTool.text),
                          color: _tool == InkTool.text
                              ? Theme.of(context).colorScheme.primary
                              : null,
                          icon: const Icon(Icons.text_fields),
                        ),
                        IconButton(
                          tooltip: '橡皮',
                          onPressed: _eraserPressed,
                          color:
                              _tool == InkTool.objectEraser ||
                                  _tool == InkTool.regionEraser
                              ? Theme.of(context).colorScheme.primary
                              : null,
                          icon: const Icon(Icons.auto_fix_off),
                        ),
                        IconButton(
                          tooltip: '套索',
                          onPressed: _lassoPressed,
                          color: _tool == InkTool.lasso
                              ? Theme.of(context).colorScheme.primary
                              : null,
                          icon: const Icon(Icons.gesture),
                        ),
                        IconButton(
                          tooltip: '撤销',
                          onPressed: _undoStack.isEmpty ? null : _undo,
                          icon: const Icon(Icons.undo),
                        ),
                        IconButton(
                          tooltip: '重做',
                          onPressed: _redoStack.isEmpty ? null : _redo,
                          icon: const Icon(Icons.redo),
                        ),
                        PopupMenuButton<bool>(
                          tooltip: '插入页面',
                          onSelected: (before) => _insert(before: before),
                          itemBuilder: (context) => const [
                            PopupMenuItem(value: true, child: Text('在此页前面插入')),
                            PopupMenuItem(value: false, child: Text('在此页后面插入')),
                          ],
                          icon: const Icon(Icons.note_add_outlined),
                        ),
                        IconButton(
                          tooltip: '删除此页',
                          onPressed: _deletePage,
                          icon: const Icon(Icons.remove_circle_outline),
                        ),
                        IconButton(
                          tooltip: '图层',
                          onPressed: () =>
                              _scaffoldKey.currentState?.openEndDrawer(),
                          icon: const Icon(Icons.layers_outlined),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PanContact {
  _PanContact(this.position, this.kind);

  Offset position;
  final PointerDeviceKind kind;
}

class _MarkEdit {
  const _MarkEdit({
    required this.pageId,
    required this.layerId,
    required this.added,
    required this.tombstoned,
    this.textBefore,
    this.textAfter,
    this.movedTexts = const [],
    this.createdTexts = const [],
  });

  final String pageId;
  final String layerId;
  final List<StrokeObject> added;
  final List<String> tombstoned;
  final TextBox? textBefore;
  final TextBox? textAfter;
  final List<({TextBox before, TextBox after})> movedTexts;
  final List<TextBox> createdTexts;
}

class _PenSession {
  _PenSession({
    required this.pageId,
    required this.layerId,
    required this.started,
    required this.raw,
    required this.stroke,
    required this.cursor,
  });

  final String pageId;
  final String layerId;
  final Duration started;
  final List<StrokePoint> raw;
  final StrokeObject stroke;
  final StrokeCursor cursor;

  _PenSession copyWith({List<StrokePoint>? raw, StrokeObject? stroke}) {
    return _PenSession(
      pageId: pageId,
      layerId: layerId,
      started: started,
      raw: raw ?? this.raw,
      stroke: stroke ?? this.stroke,
      cursor: cursor,
    );
  }
}

class _InkLocator {
  List<Object?>? source;
  List<String>? deleted;
  final StrokeSpatialIndex index = StrokeSpatialIndex();
  Iterable<StrokeObject> near(Rect query, Set<String> deleted) =>
      index.query(query, deleted: deleted);
}
