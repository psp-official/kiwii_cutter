import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:video_player/video_player.dart';
import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';
import 'package:path_provider/path_provider.dart';
import 'package:gal/gal.dart';

void main() {
  runApp(const CapCutLosslessApp());
}

class CapCutLosslessApp extends StatelessWidget {
  const CapCutLosslessApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CapCut Lossless Cutter',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0E0E0E),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00E5FF),
          secondary: Colors.white,
        ),
      ),
      home: const CapCutEditorPage(),
    );
  }
}

class VideoSegment {
  double start;
  double end;

  VideoSegment({required this.start, required this.end});

  double get duration => (end - start).clamp(0.1, 36000.0);

  VideoSegment copy() => VideoSegment(start: start, end: end);
}

class SubtitleItem {
  final String id;
  double start;
  double end;
  String text;
  int trackRow; // Text တစ်ခုချင်းစီ အောက်တစ်တန်းစီ ဆင်းသွားရန် Row Index
  double xRatio; // Video ပေါ်ရှိ အလျားလိုက် တည်နေရာ (0.0 to 1.0)
  double yRatio; // Video ပေါ်ရှိ ဒေါင်လိုက် တည်နေရာ (0.0 to 1.0)
  double fontSize;
  String fontFamily;
  Color textColor;
  Color strokeColor;
  bool hasBackBox;

  SubtitleItem({
    required this.id,
    required this.start,
    required this.end,
    required this.text,
    required this.trackRow,
    this.xRatio = 0.5,
    this.yRatio = 0.82,
    this.fontSize = 20.0,
    this.fontFamily = 'Default',
    this.textColor = Colors.white,
    this.strokeColor = Colors.black,
    this.hasBackBox = true,
  });

  double get duration => (end - start).clamp(0.2, 36000.0);

  SubtitleItem copy() => SubtitleItem(
        id: id,
        start: start,
        end: end,
        text: text,
        trackRow: trackRow,
        xRatio: xRatio,
        yRatio: yRatio,
        fontSize: fontSize,
        fontFamily: fontFamily,
        textColor: textColor,
        strokeColor: strokeColor,
        hasBackBox: hasBackBox,
      );
}

class EditorSnapshot {
  final List<VideoSegment> segments;
  final List<SubtitleItem> subtitles;
  final int selectedIndex;
  final String? selectedSubId;

  EditorSnapshot({
    required this.segments,
    required this.subtitles,
    required this.selectedIndex,
    required this.selectedSubId,
  });
}

class CapCutEditorPage extends StatefulWidget {
  const CapCutEditorPage({super.key});

  @override
  State<CapCutEditorPage> createState() => _CapCutEditorPageState();
}

class _CapCutEditorPageState extends State<CapCutEditorPage> {
  VideoPlayerController? _controller;
  final ScrollController _timelineScrollController = ScrollController();
  final ScrollController _verticalTrackScrollController = ScrollController();

  String? _videoPath;
  bool _isProcessing = false;
  bool _isUserScrolling = false;
  bool _isMuted = false;
  String _statusMessage = '';

  final List<String?> _thumbnails = [];
  List<VideoSegment> _segments = [];
  List<SubtitleItem> _subtitles = [];
  int _selectedIndex = 0;
  String? _selectedSubId;

  // Custom Fonts စာရင်း
  final List<String> _loadedFonts = ['Default'];
  String _defaultFont = 'Default';

  // Undo / Redo Stacks
  final List<EditorSnapshot> _undoStack = [];
  final List<EditorSnapshot> _redoStack = [];

  // Timeline Pinch-to-Zoom အတွက် လက်ချောင်း အမှတ်များ
  final Map<int, Offset> _activePointers = {};
  double? _initialPinchDistance;
  double _basePixelsPerSecond = 55.0;
  double _pixelsPerSecond = 55.0;
  double _pinchAnchorSec = 0.0;

  static const int _thumbCount = 24;

  bool get _isPinching => _activePointers.length >= 2;

  double get _maxOriginalDuration => _controller != null
      ? _controller!.value.duration.inMilliseconds / 1000.0
      : 1.0;

  double get _totalActiveDuration =>
      _segments.fold(0.0, (sum, seg) => sum + seg.duration);

  // Playhead နှင့် 100% တိကျစေရန် Segment အားလုံး၏ စုစုပေါင်းအကျယ်အတိုင်း တွက်ချက်ခြင်း
  double get _totalTimelineWidth =>
      (_totalActiveDuration * _pixelsPerSecond).clamp(1.0, 100000.0);

  SubtitleItem? get _selectedSubtitle {
    if (_selectedSubId == null) return null;
    for (final s in _subtitles) {
      if (s.id == _selectedSubId) return s;
    }
    return null;
  }

  @override
  void dispose() {
    _controller?.dispose();
    _timelineScrollController.dispose();
    _verticalTrackScrollController.dispose();
    super.dispose();
  }

  void _saveStateForUndo() {
    _undoStack.add(
      EditorSnapshot(
        segments: _segments.map((s) => s.copy()).toList(),
        subtitles: _subtitles.map((s) => s.copy()).toList(),
        selectedIndex: _selectedIndex,
        selectedSubId: _selectedSubId,
      ),
    );
    _redoStack.clear();
  }

  void _undo() {
    if (_undoStack.isEmpty) return;
    _redoStack.add(
      EditorSnapshot(
        segments: _segments.map((s) => s.copy()).toList(),
        subtitles: _subtitles.map((s) => s.copy()).toList(),
        selectedIndex: _selectedIndex,
        selectedSubId: _selectedSubId,
      ),
    );
    final prev = _undoStack.removeLast();
    setState(() {
      _segments = prev.segments;
      _subtitles = prev.subtitles;
      _selectedIndex = prev.selectedIndex.clamp(0, _segments.length - 1);
      _selectedSubId = prev.selectedSubId;
    });
  }

  void _redo() {
    if (_redoStack.isEmpty) return;
    _undoStack.add(
      EditorSnapshot(
        segments: _segments.map((s) => s.copy()).toList(),
        subtitles: _subtitles.map((s) => s.copy()).toList(),
        selectedIndex: _selectedIndex,
        selectedSubId: _selectedSubId,
      ),
    );
    final next = _redoStack.removeLast();
    setState(() {
      _segments = next.segments;
      _subtitles = next.subtitles;
      _selectedIndex = next.selectedIndex.clamp(0, _segments.length - 1);
      _selectedSubId = next.selectedSubId;
    });
  }

  Future<void> _pickVideo() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.video);
    if (result != null && result.files.single.path != null) {
      final path = result.files.single.path!;
      await _controller?.dispose();

      final controller = VideoPlayerController.file(File(path));
      await controller.initialize();
      final maxDur = controller.value.duration.inMilliseconds / 1000.0;

      final autoPps = (600.0 / (maxDur > 0 ? maxDur : 10.0)).clamp(20.0, 100.0);

      controller.addListener(_onVideoTick);

      setState(() {
        _videoPath = path;
        _controller = controller;
        _pixelsPerSecond = autoPps;
        _basePixelsPerSecond = autoPps;
        _isMuted = false;
        _segments = [VideoSegment(start: 0.0, end: maxDur)];
        _subtitles.clear();
        _selectedIndex = 0;
        _selectedSubId = null;
        _undoStack.clear();
        _redoStack.clear();
        _statusMessage = '';
        _thumbnails
          ..clear()
          ..addAll(List<String?>.filled(_thumbCount, null));
      });

      if (_timelineScrollController.hasClients) {
        _timelineScrollController.jumpTo(0.0);
      }

      _generateThumbnails(path, maxDur);
    }
  }

  Future<void> _generateThumbnails(String videoPath, double maxDur) async {
    if (maxDur <= 0) return;
    final tempDir = await getTemporaryDirectory();
    final stamp = DateTime.now().millisecondsSinceEpoch;

    for (int i = 0; i < _thumbCount; i++) {
      if (!mounted || _videoPath != videoPath) return;
      final timeSec = (maxDur / _thumbCount) * i;
      final outPath = '${tempDir.path}/thumb_${stamp}_$i.jpg';

      final cmd =
          '-y -ss ${timeSec.toStringAsFixed(2)} -i "$videoPath" -frames:v 1 -vf "scale=160:90" -q:v 5 "$outPath"';
      final session = await FFmpegKit.execute(cmd);
      final rc = await session.getReturnCode();

      if (ReturnCode.isSuccess(rc) && await File(outPath).exists()) {
        if (mounted && _videoPath == videoPath) {
          setState(() {
            _thumbnails[i] = outPath;
          });
        }
      }
    }
  }

  // Video Play နေစဉ် Playhead နှင့် Timeline ကို တစ်ထပ်တည်း ရွှေ့ပေးခြင်း
  void _onVideoTick() {
    if (!mounted || _controller == null || _segments.isEmpty) return;
    final posSec = _controller!.value.position.inMilliseconds / 1000.0;

    if (_controller!.value.isPlaying && !_isUserScrolling && !_isPinching) {
      int foundIdx = -1;
      double activeBefore = 0.0;

      for (int i = 0; i < _segments.length; i++) {
        final s = _segments[i];
        if (posSec >= s.start - 0.04 && posSec <= s.end + 0.04) {
          foundIdx = i;
          final currentActiveSec =
              activeBefore + (posSec - s.start).clamp(0.0, s.duration);
          final targetScroll =
              (currentActiveSec * _pixelsPerSecond).clamp(0.0, _totalTimelineWidth);
          if (_timelineScrollController.hasClients) {
            _timelineScrollController.jumpTo(targetScroll);
          }
          break;
        }
        activeBefore += s.duration;
      }

      if (foundIdx != -1) {
        _selectedIndex = foundIdx;
      } else {
        VideoSegment? nextSeg;
        for (int i = 0; i < _segments.length; i++) {
          if (_segments[i].start > posSec) {
            nextSeg = _segments[i];
            _selectedIndex = i;
            break;
          }
        }
        if (nextSeg != null) {
          _seekToVideoSec(nextSeg.start);
        } else {
          _controller!.pause();
        }
      }
    }

    setState(() {});
  }

  void _seekToVideoSec(double sec) {
    if (_controller == null) return;
    final clamped = sec.clamp(0.0, _maxOriginalDuration);
    _controller!.seekTo(Duration(milliseconds: (clamped * 1000).toInt()));
  }

  // Timeline Scroll Offset မှ Video အချိန်သို့ တိကျစွာ ပြောင်းလဲခြင်း
  double _offsetToVideoSeconds(double scrollOffset) {
    if (_segments.isEmpty || _totalTimelineWidth <= 0) return 0.0;
    final clampedOffset = scrollOffset.clamp(0.0, _totalTimelineWidth);
    final targetActiveSec = clampedOffset / _pixelsPerSecond;

    double accSec = 0.0;
    for (int i = 0; i < _segments.length; i++) {
      final seg = _segments[i];
      if (targetActiveSec <= accSec + seg.duration || i == _segments.length - 1) {
        _selectedIndex = i;
        final localSec = (targetActiveSec - accSec).clamp(0.0, seg.duration);
        return seg.start + localSec;
      }
      accSec += seg.duration;
    }
    return _segments.last.end;
  }

  // လက်ရှိ Playhead ရောက်နေသော Active Timeline အချိန် (စက္ကန့်)
  double _currentTimelinePosition() {
    if (_controller == null || _segments.isEmpty) return 0.0;
    if (_timelineScrollController.hasClients && (_isUserScrolling || !_controller!.value.isPlaying)) {
      return (_timelineScrollController.offset / _pixelsPerSecond)
          .clamp(0.0, _totalActiveDuration);
    }
    final posSec = _controller!.value.position.inMilliseconds / 1000.0;
    double acc = 0.0;
    for (final seg in _segments) {
      if (posSec >= seg.start - 0.05 && posSec <= seg.end + 0.05) {
        return (acc + (posSec - seg.start).clamp(0.0, seg.duration))
            .clamp(0.0, _totalActiveDuration);
      }
      acc += seg.duration;
    }
    return acc.clamp(0.0, _totalActiveDuration);
  }

  List<SubtitleItem> _getActiveSubtitlesAt(double timelineSec) {
    return _subtitles
        .where((s) => timelineSec >= s.start && timelineSec <= s.end)
        .toList();
  }

  // လက်နှစ်ချောင်းဖြင့် Timeline ဆွဲချဲ့/ဆွဲချုံ့ခြင်း (CapCut Pinch Zoom)
  void _handlePointerDown(PointerDownEvent event) {
    _activePointers[event.pointer] = event.position;
    if (_activePointers.length == 2) {
      final pts = _activePointers.values.toList();
      _initialPinchDistance = (pts[0] - pts[1]).distance;
      _basePixelsPerSecond = _pixelsPerSecond;
      _pinchAnchorSec = _currentTimelinePosition();
      setState(() {});
    }
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (!_activePointers.containsKey(event.pointer)) return;
    _activePointers[event.pointer] = event.position;

    if (_activePointers.length >= 2 &&
        _initialPinchDistance != null &&
        _initialPinchDistance! > 10) {
      final pts = _activePointers.values.toList();
      final currentDist = (pts[0] - pts[1]).distance;
      final scale = currentDist / _initialPinchDistance!;
      final newPps = (_basePixelsPerSecond * scale).clamp(15.0, 240.0);

      setState(() {
        _pixelsPerSecond = newPps;
      });

      if (_timelineScrollController.hasClients) {
        final targetOffset =
            (_pinchAnchorSec * _pixelsPerSecond).clamp(0.0, _totalTimelineWidth);
        _timelineScrollController.jumpTo(targetOffset);
      }
    }
  }

  void _handlePointerUpOrCancel(PointerEvent event) {
    _activePointers.remove(event.pointer);
    if (_activePointers.length < 2) {
      _initialPinchDistance = null;
      setState(() {});
    }
  }

  // ချက်ချင်း Zoom အကျယ်/အကျဉ်း ကစားနိုင်သော ခလုတ်
  void _stepZoom(double factor) {
    final anchorSec = _currentTimelinePosition();
    setState(() {
      _pixelsPerSecond = (_pixelsPerSecond * factor).clamp(15.0, 240.0);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_timelineScrollController.hasClients) {
        _timelineScrollController.jumpTo(
          (anchorSec * _pixelsPerSecond).clamp(0.0, _totalTimelineWidth),
        );
      }
    });
  }

  // .srt ဖိုင် ထည့်သွင်းခြင်း (Row 0 တွင် စီပေးမည်)
  Future<void> _importSrtFile() async {
    if (_controller == null) return;
    final result = await FilePicker.platform.pickFiles(type: FileType.any);
    if (result != null && result.files.single.path != null) {
      final path = result.files.single.path!;
      if (!path.toLowerCase().endsWith('.srt')) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('ကျေးဇူးပြု၍ .srt ဖိုင်ကိုသာ ရွေးချယ်ပါ')),
          );
        }
        return;
      }

      final content = await File(path).readAsString();
      final parsed = _parseSrt(content);
      if (parsed.isEmpty) return;

      _saveStateForUndo();
      setState(() {
        _subtitles.addAll(parsed);
        _statusMessage = '✅ SRT စာတန်း (${parsed.length}) ကြောင်း ထည့်သွင်းပြီးပါပြီ';
      });
    }
  }

  List<SubtitleItem> _parseSrt(String raw) {
    final List<SubtitleItem> items = [];
    final normalized = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final blocks = normalized.split(RegExp(r'\n\s*\n'));

    final timeReg = RegExp(
      r'(\d{1,2}):(\d{2}):(\d{2})[,.](\d{1,3})\s*-->\s*(\d{1,2}):(\d{2}):(\d{2})[,.](\d{1,3})',
    );

    final nextRow = _getNextAvailableTextRow();
    int counter = 0;

    for (final block in blocks) {
      final lines = block.trim().split('\n');
      if (lines.length < 2) continue;

      int timeLineIdx = -1;
      RegExpMatch? match;
      for (int i = 0; i < lines.length; i++) {
        final m = timeReg.firstMatch(lines[i]);
        if (m != null) {
          timeLineIdx = i;
          match = m;
          break;
        }
      }

      if (match != null && timeLineIdx != -1) {
        final startSec = _hmsToSec(
          match.group(1)!,
          match.group(2)!,
          match.group(3)!,
          match.group(4)!,
        );
        final endSec = _hmsToSec(
          match.group(5)!,
          match.group(6)!,
          match.group(7)!,
          match.group(8)!,
        );
        final textLines = lines.sublist(timeLineIdx + 1);
        final cleanText = textLines
            .join('\n')
            .replaceAll(RegExp(r'<[^>]*>'), '')
            .trim();

        if (cleanText.isNotEmpty && endSec > startSec) {
          counter++;
          items.add(
            SubtitleItem(
              id: 'srt_${DateTime.now().microsecondsSinceEpoch}_$counter',
              start: startSec,
              end: endSec,
              text: cleanText,
              trackRow: nextRow,
              xRatio: 0.5,
              yRatio: 0.85,
              fontFamily: _defaultFont,
            ),
          );
        }
      }
    }
    return items;
  }

  double _hmsToSec(String h, String m, String s, String ms) {
    final hours = int.tryParse(h) ?? 0;
    final mins = int.tryParse(m) ?? 0;
    final secs = int.tryParse(s) ?? 0;
    final millis = int.tryParse(ms.padRight(3, '0').substring(0, 3)) ?? 0;
    return hours * 3600 + mins * 60 + secs + (millis / 1000.0);
  }

  // Text အသစ်ထပ်နှိပ်တိုင်း အောက်က တစ်တန်းအသစ်သို့ ရောက်သွားစေရန် Row တွက်ချက်ခြင်း
  int _getNextAvailableTextRow() {
    if (_subtitles.isEmpty) return 0;
    int maxRow = 0;
    for (final s in _subtitles) {
      if (s.trackRow >= maxRow) {
        maxRow = s.trackRow + 1;
      }
    }
    return maxRow;
  }

  // စိတ်ကြိုက် Font (.ttf / .otf) ထည့်သွင်းခြင်း
  Future<void> _importCustomFont() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.any);
    if (result != null && result.files.single.path != null) {
      final path = result.files.single.path!;
      final lower = path.toLowerCase();
      if (!lower.endsWith('.ttf') && !lower.endsWith('.otf')) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('ကျေးဇူးပြု၍ .ttf သို့မဟုတ် .otf Font ဖိုင်ကို ရွေးပါ'),
            ),
          );
        }
        return;
      }

      final fontName = path
          .split('/')
          .last
          .replaceAll(RegExp(r'\.(ttf|otf)$', caseSensitive: false), '');

      final bytes = await File(path).readAsBytes();
      final loader = FontLoader(fontName);
      loader.addFont(Future.value(ByteData.view(bytes.buffer)));
      await loader.load();

      setState(() {
        if (!_loadedFonts.contains(fontName)) {
          _loadedFonts.add(fontName);
        }
        _defaultFont = fontName;
        if (_selectedSubtitle != null) {
          _selectedSubtitle!.fontFamily = fontName;
        } else {
          for (final s in _subtitles) {
            s.fontFamily = fontName;
          }
        }
        _statusMessage = '🔤 Font "$fontName" ထည့်သွင်းပြီးပါပြီ';
      });
    }
  }

  // Split ခလုတ်နှိပ်သည့်အခါ ရွေးထားသော Text သို့မဟုတ် Video ကို ပိုင်းပေးခြင်း
  void _splitAtPlayhead() {
    if (_controller == null || _segments.isEmpty) return;
    final timelinePos = _currentTimelinePosition();

    // အကယ်၍ Text ကို ရွေးထားပါက ထို Text ကို နှစ်ပိုင်း ပိုင်းပေးမည်
    final selSub = _selectedSubtitle;
    if (selSub != null &&
        timelinePos > selSub.start + 0.2 &&
        timelinePos < selSub.end - 0.2) {
      _saveStateForUndo();
      setState(() {
        final secondHalf = selSub.copy()
          .. start = timelinePos;
        final newItem = SubtitleItem(
          id: 'txt_${DateTime.now().microsecondsSinceEpoch}',
          start: secondHalf.start,
          end: selSub.end,
          text: selSub.text,
          trackRow: selSub.trackRow,
          xRatio: selSub.xRatio,
          yRatio: selSub.yRatio,
          fontSize: selSub.fontSize,
          fontFamily: selSub.fontFamily,
          textColor: selSub.textColor,
          strokeColor: selSub.strokeColor,
          hasBackBox: selSub.hasBackBox,
        );
        selSub.end = timelinePos;
        _subtitles.add(newItem);
        _selectedSubId = newItem.id;
      });
      return;
    }

    // Video Segment ကို ပိုင်းခြင်း
    double acc = 0.0;
    for (int i = 0; i < _segments.length; i++) {
      final seg = _segments[i];
      final localPos = timelinePos - acc;
      if (localPos > 0.2 && localPos < seg.duration - 0.2) {
        final splitVideoSec = seg.start + localPos;
        _saveStateForUndo();
        setState(() {
          final first = VideoSegment(start: seg.start, end: splitVideoSec);
          final second = VideoSegment(start: splitVideoSec, end: seg.end);
          _segments[i] = first;
          _segments.insert(i + 1, second);
          _selectedIndex = i + 1;
          _selectedSubId = null;
        });
        return;
      }
      acc += seg.duration;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('ဖြတ်မည့်နေရာသည် အပိုင်းအစ/အဆုံးနှင့် အနည်းငယ် ကွာရပါမည်'),
        duration: Duration(milliseconds: 900),
      ),
    );
  }

  void _deleteSelectedItem() {
    if (_selectedSubId != null) {
      _saveStateForUndo();
      setState(() {
        _subtitles.removeWhere((s) => s.id == _selectedSubId);
        _selectedSubId = null;
      });
      return;
    }

    if (_segments.length <= 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('အပိုင်း (၁) ပိုင်းတည်းသာ ကျန်တော့သဖြင့် အရင် Split ပိုင်းပေးပါ'),
          duration: Duration(milliseconds: 1100),
        ),
      );
      return;
    }

    _saveStateForUndo();
    final removedDuration = _segments[_selectedIndex].duration;
    double removedTimelineStart = 0.0;
    for (int i = 0; i < _selectedIndex; i++) {
      removedTimelineStart += _segments[i].duration;
    }
    final removedTimelineEnd = removedTimelineStart + removedDuration;

    setState(() {
      _segments.removeAt(_selectedIndex);
      if (_selectedIndex >= _segments.length) {
        _selectedIndex = _segments.length - 1;
      }

      final List<SubtitleItem> updatedSubs = [];
      for (final s in _subtitles) {
        if (s.end <= removedTimelineStart) {
          updatedSubs.add(s);
        } else if (s.start >= removedTimelineEnd) {
          s.start -= removedDuration;
          s.end -= removedDuration;
          updatedSubs.add(s);
        }
      }
      _subtitles = updatedSubs;
    });

    final targetSeg = _segments[_selectedIndex];
    _seekToVideoSec(targetSeg.start);
  }

  void _toggleMute() {
    if (_controller == null) return;
    setState(() {
      _isMuted = !_isMuted;
      _controller!.setVolume(_isMuted ? 0.0 : 1.0);
    });
  }

  // CapCut ပုံစံ Text အသစ်ထည့်ခြင်း / ပြင်ဆင်ခြင်း Sheet
  void _showAddOrEditTextSheet({SubtitleItem? editItem}) {
    if (_controller == null) return;
    final curTime = _currentTimelinePosition();

    final textCtrl = TextEditingController(text: editItem?.text ?? '');
    String tempFont = editItem?.fontFamily ?? _defaultFont;
    double tempSize = editItem?.fontSize ?? 22.0;
    Color tempColor = editItem?.textColor ?? Colors.white;
    Color tempStroke = editItem?.strokeColor ?? Colors.black;
    bool tempBox = editItem?.hasBackBox ?? true;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 14,
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          editItem != null
                              ? '✏️ Text ဒီဇိုင်း ပြင်ဆင်ရန်'
                              : '➕ Text အသစ်ထည့်ရန် (အောက်တစ်တန်းသစ်)',
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        TextButton.icon(
                          onPressed: () async {
                            await _importCustomFont();
                            setModalState(() {
                              tempFont = _defaultFont;
                            });
                          },
                          icon: const Icon(
                            Icons.font_download,
                            color: Color(0xFF00E5FF),
                            size: 18,
                          ),
                          label: const Text(
                            '+ Font (.ttf/.otf)',
                            style: TextStyle(color: Color(0xFF00E5FF)),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: textCtrl,
                      autofocus: editItem == null,
                      maxLines: 2,
                      style: TextStyle(
                        fontFamily: tempFont == 'Default' ? null : tempFont,
                        fontSize: 16,
                      ),
                      decoration: InputDecoration(
                        hintText: 'စာသား ရိုက်ထည့်ပါ (ပြီးလျှင် Video ပေါ် လက်ဖြင့်ဆွဲရွှေ့နိုင်သည်)...',
                        filled: true,
                        fillColor: const Color(0xFF262626),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),

                    // Font ရွေးချယ်ရန်
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: _loadedFonts.map((f) {
                          final selected = f == tempFont;
                          return Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              label: Text(
                                f,
                                style: TextStyle(
                                  fontFamily: f == 'Default' ? null : f,
                                ),
                              ),
                              selected: selected,
                              selectedColor: const Color(0xFF00E5FF),
                              labelStyle: TextStyle(
                                color: selected ? Colors.black : Colors.white,
                              ),
                              onSelected: (_) {
                                setModalState(() => tempFont = f);
                                if (editItem != null) {
                                  setState(() => editItem.fontFamily = f);
                                }
                              },
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                    const SizedBox(height: 6),

                    // Size Slider
                    Row(
                      children: [
                        const Text('စာလုံးဆိုဒ်:', style: TextStyle(fontSize: 12)),
                        Expanded(
                          child: Slider(
                            value: tempSize.clamp(10.0, 56.0),
                            min: 10.0,
                            max: 56.0,
                            activeColor: const Color(0xFF00E5FF),
                            onChanged: (v) {
                              setModalState(() => tempSize = v);
                              if (editItem != null) {
                                setState(() => editItem.fontSize = v);
                              }
                            },
                          ),
                        ),
                        Text('${tempSize.toInt()}'),
                      ],
                    ),

                    // အရောင် နှင့် အနောက်ခံဘောင်
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Colors.white,
                            const Color(0xFFFFEA00),
                            const Color(0xFF00E5FF),
                            const Color(0xFF00E676),
                            const Color(0xFFFF5252),
                            const Color(0xFFFF4081),
                          ].map((c) {
                            final isSel = tempColor == c;
                            return GestureDetector(
                              onTap: () {
                                setModalState(() => tempColor = c);
                                if (editItem != null) {
                                  setState(() => editItem.textColor = c);
                                }
                              },
                              child: Container(
                                width: 26,
                                height: 26,
                                margin: const EdgeInsets.only(right: 8),
                                decoration: BoxDecoration(
                                  color: c,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: isSel
                                        ? Colors.white
                                        : Colors.transparent,
                                    width: 2.5,
                                  ),
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                        FilterChip(
                          label: const Text('အနောက်ခံဘောင်'),
                          selected: tempBox,
                          onSelected: (v) {
                            setModalState(() => tempBox = v);
                            if (editItem != null) {
                              setState(() => editItem.hasBackBox = v);
                            }
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    ElevatedButton(
                      onPressed: () {
                        final txt = textCtrl.text.trim();
                        if (txt.isEmpty) return;

                        _saveStateForUndo();
                        setState(() {
                          if (editItem != null) {
                            editItem.text = txt;
                            editItem.fontFamily = tempFont;
                            editItem.fontSize = tempSize;
                            editItem.textColor = tempColor;
                            editItem.strokeColor = tempStroke;
                            editItem.hasBackBox = tempBox;
                          } else {
                            // Text အသစ်ထပ်ထည့်တိုင်း အောက်က တစ်တန်းအသစ် (New Row) တွင် ချပေးခြင်း
                            final newRow = _getNextAvailableTextRow();
                            final startSec = curTime.clamp(
                              0.0,
                              (_totalActiveDuration - 0.5)
                                  .clamp(0.0, _totalActiveDuration),
                            );
                            final endSec = (startSec + 3.0)
                                .clamp(startSec + 0.5, _totalActiveDuration);

                            // အပေါ်စာသားနှင့် မထပ်စေရန် အသစ်ထည့်သော Text ကို အလယ်နားတွင် ချပေးခြင်း
                            final defaultY =
                                (0.45 + (newRow % 4) * 0.10).clamp(0.2, 0.85);

                            final created = SubtitleItem(
                              id: 'txt_${DateTime.now().microsecondsSinceEpoch}',
                              start: startSec,
                              end: endSec,
                              text: txt,
                              trackRow: newRow,
                              xRatio: 0.5,
                              yRatio: defaultY,
                              fontSize: tempSize,
                              fontFamily: tempFont,
                              textColor: tempColor,
                              strokeColor: tempStroke,
                              hasBackBox: tempBox,
                            );
                            _subtitles.add(created);
                            _selectedSubId = created.id;
                          }
                        });
                        Navigator.pop(ctx);
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00E5FF),
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 13),
                      ),
                      child: const Text(
                        '✓ အတည်ပြုမည်',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showExportSheet() {
    if (_videoPath == null || _segments.isEmpty) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '⚡ Export ရွေးချယ်ရန် (ဖိုင်ဆိုဒ်မဖောင်းပွပါ)',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              Text(
                'ဗီဒီယို (${_segments.length}) ပိုင်း • Text/SRT (${_subtitles.length}) ခု • စုစုပေါင်း ${_formatClock(_totalActiveDuration)}',
                style: const TextStyle(color: Colors.grey, fontSize: 13),
              ),
              const SizedBox(height: 16),
              if (_subtitles.isNotEmpty) ...[
                ElevatedButton.icon(
                  onPressed: () {
                    Navigator.pop(ctx);
                    _exportClips(merge: true, burnSubtitles: true);
                  },
                  icon: const Icon(Icons.subtitles),
                  label: const Text(
                    'Text / SRT နှင့် Font များကို Video ပေါ်အသေကပ်ပြီး ထုတ်မည်',
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00E676),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
                const SizedBox(height: 10),
              ],
              ElevatedButton.icon(
                onPressed: () {
                  Navigator.pop(ctx);
                  _exportClips(merge: true, burnSubtitles: false);
                },
                icon: const Icon(Icons.bolt),
                label: const Text(
                  '⚡ Lossless Cut & Merge (1 sec / မူရင်းဆိုဒ်အတိုင်း)',
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00E5FF),
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: () {
                  Navigator.pop(ctx);
                  _exportClips(merge: false, burnSubtitles: false);
                },
                icon: const Icon(Icons.content_cut, color: Colors.white),
                label: Text(
                  'တစ်ပိုင်းစီ သီးခြားထုတ်မည် (${_segments.length} ဖိုင်)',
                  style: const TextStyle(color: Colors.white),
                ),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  side: const BorderSide(color: Colors.white38),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // Video ပေါ်တွင် လက်ဖြင့်ဆွဲထားသော နေရာ (xRatio, yRatio) အတိုင်း Text အားလုံးကို PNG ဆွဲပေးခြင်း
  Future<void> _renderMultiLayerSubtitlePng({
    required List<SubtitleItem> activeSubs,
    required int width,
    required int height,
    required String outPath,
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(
      recorder,
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    );

    final scaleFactor = (width / 360.0).clamp(1.0, 4.5);

    for (final sub in activeSubs) {
      if (sub.text.trim().isEmpty) continue;
      final scaledFontSize = sub.fontSize * scaleFactor;
      final fontFam = sub.fontFamily == 'Default' ? null : sub.fontFamily;

      final strokeSpan = TextSpan(
        text: sub.text,
        style: TextStyle(
          fontFamily: fontFam,
          fontSize: scaledFontSize,
          fontWeight: FontWeight.w700,
          height: 1.3,
          foreground: Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3.5 * scaleFactor
            ..color = sub.strokeColor,
        ),
      );
      final strokePainter = TextPainter(
        text: strokeSpan,
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: width * 0.92);

      final fillSpan = TextSpan(
        text: sub.text,
        style: TextStyle(
          fontFamily: fontFam,
          fontSize: scaledFontSize,
          fontWeight: FontWeight.w700,
          height: 1.3,
          color: sub.textColor,
        ),
      );
      final fillPainter = TextPainter(
        text: fillSpan,
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: width * 0.92);

      final centerX = sub.xRatio * width;
      final centerY = sub.yRatio * height;
      final dx = (centerX - fillPainter.width / 2.0)
          .clamp(4.0, (width - fillPainter.width - 4.0).clamp(4.0, width.toDouble()));
      final dy = (centerY - fillPainter.height / 2.0)
          .clamp(4.0, (height - fillPainter.height - 4.0).clamp(4.0, height.toDouble()));

      if (sub.hasBackBox) {
        final bgRect = RRect.fromRectAndRadius(
          Rect.fromLTWH(
            dx - 10 * scaleFactor,
            dy - 5 * scaleFactor,
            fillPainter.width + 20 * scaleFactor,
            fillPainter.height + 10 * scaleFactor,
          ),
          Radius.circular(6 * scaleFactor),
        );
        canvas.drawRRect(bgRect, Paint()..color = const Color(0x99000000));
      }

      strokePainter.paint(canvas, Offset(dx, dy));
      fillPainter.paint(canvas, Offset(dx, dy));
    }

    final picture = recorder.endRecording();
    final img = await picture.toImage(width, height);
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    await File(outPath).writeAsBytes(byteData!.buffer.asUint8List());
  }

  Future<void> _exportClips({
    required bool merge,
    required bool burnSubtitles,
  }) async {
    if (_videoPath == null || _segments.isEmpty) return;

    setState(() {
      _isProcessing = true;
      _statusMessage = burnSubtitles
          ? '⏳ Text/SRT များကို ဗီဒီယိုပေါ် ကပ်နေပါသည်...'
          : '⏳ Lossless (-c copy) ဖြင့် ဖြတ်ထုတ်နေပါသည်...';
    });

    try {
      final tempDir = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final List<String> tempOutputs = [];
      final audioFlag = _isMuted ? '-an' : '';

      for (int i = 0; i < _segments.length; i++) {
        final clip = _segments[i];
        final duration = clip.duration.toStringAsFixed(2);
        final outPath = '${tempDir.path}/cut_${timestamp}_${i + 1}.mp4';

        final cmd =
            '-y -ss ${clip.start.toStringAsFixed(2)} -i "$_videoPath" -t $duration -c copy $audioFlag -avoid_negative_ts make_zero "$outPath"';

        final session = await FFmpegKit.execute(cmd);
        final rc = await session.getReturnCode();
        if (!ReturnCode.isSuccess(rc)) {
          throw Exception('အပိုင်း ${i + 1} ဖြတ်ရာတွင် အမှားဖြစ်ပေါ်ပါသည်');
        }
        tempOutputs.add(outPath);
      }

      if (merge || burnSubtitles) {
        String baseMergedPath = tempOutputs.first;
        if (tempOutputs.length > 1) {
          final listFile = File('${tempDir.path}/concat_$timestamp.txt');
          final listContent = tempOutputs.map((p) => "file '$p'").join('\n');
          await listFile.writeAsString(listContent);

          baseMergedPath = '${tempDir.path}/merged_$timestamp.mp4';
          final mergeCmd =
              '-y -f concat -safe 0 -i "${listFile.path}" -c copy "$baseMergedPath"';

          final session = await FFmpegKit.execute(mergeCmd);
          final rc = await session.getReturnCode();
          if (!ReturnCode.isSuccess(rc)) {
            throw Exception('ဗီဒီယို ပြန်ဆက်ရာတွင် အမှားဖြစ်ပေါ်ပါသည်');
          }
        }

        String finalVideoPath = baseMergedPath;

        if (burnSubtitles && _subtitles.isNotEmpty) {
          final vidW = _controller!.value.size.width.toInt().clamp(320, 1920);
          final vidH = _controller!.value.size.height.toInt().clamp(320, 1920);

          final origBytes = await File(_videoPath!).length();
          final origBitrate =
              ((origBytes * 8) / (_maxOriginalDuration > 0 ? _maxOriginalDuration : 10))
                  .round()
                  .clamp(600000, 12000000);

          final Set<double> timePoints = {0.0, _totalActiveDuration};
          for (final s in _subtitles) {
            timePoints.add(s.start.clamp(0.0, _totalActiveDuration));
            timePoints.add(s.end.clamp(0.0, _totalActiveDuration));
          }
          final sortedPts = timePoints.toList()..sort();

          final blankPng = '${tempDir.path}/blank_$timestamp.png';
          await _renderMultiLayerSubtitlePng(
            activeSubs: const [],
            width: vidW,
            height: vidH,
            outPath: blankPng,
          );

          final StringBuffer subConcatBuf = StringBuffer();
          String lastPngPath = blankPng;

          for (int i = 0; i < sortedPts.length - 1; i++) {
            final t0 = sortedPts[i];
            final t1 = sortedPts[i + 1];
            final dur = t1 - t0;
            if (dur < 0.02) continue;

            final mid = (t0 + t1) / 2.0;
            final activeSubs = _getActiveSubtitlesAt(mid);
            String pngPath = blankPng;

            if (activeSubs.isNotEmpty) {
              pngPath = '${tempDir.path}/sub_${timestamp}_$i.png';
              await _renderMultiLayerSubtitlePng(
                activeSubs: activeSubs,
                width: vidW,
                height: vidH,
                outPath: pngPath,
              );
            }

            subConcatBuf.writeln("file '$pngPath'");
            subConcatBuf.writeln('duration ${dur.toStringAsFixed(3)}');
            lastPngPath = pngPath;
          }
          subConcatBuf.writeln("file '$lastPngPath'");

          final subConcatFile = File('${tempDir.path}/subs_$timestamp.txt');
          await subConcatFile.writeAsString(subConcatBuf.toString());

          final burnedPath = '${tempDir.path}/burned_$timestamp.mp4';
          String burnCmd =
              '-y -i "$baseMergedPath" -f concat -safe 0 -i "${subConcatFile.path}" -filter_complex "[0:v][1:v]overlay=0:0:shortest=1" -c:v h264_mediacodec -b:v $origBitrate -c:a copy "$burnedPath"';

          var session = await FFmpegKit.execute(burnCmd);
          var rc = await session.getReturnCode();

          if (!ReturnCode.isSuccess(rc)) {
            burnCmd =
                '-y -i "$baseMergedPath" -f concat -safe 0 -i "${subConcatFile.path}" -filter_complex "[0:v][1:v]overlay=0:0:shortest=1" -c:v mpeg4 -b:v $origBitrate -c:a copy "$burnedPath"';
            session = await FFmpegKit.execute(burnCmd);
            rc = await session.getReturnCode();
            if (!ReturnCode.isSuccess(rc)) {
              throw Exception('စာတန်းကပ်ရာတွင် အမှားဖြစ်ပေါ်ပါသည်');
            }
          }
          finalVideoPath = burnedPath;
        }

        await Gal.putVideo(finalVideoPath, album: 'LosslessCuts');
        final sizeMb = (await File(finalVideoPath).length()) / (1024 * 1024);
        setState(() {
          _statusMessage =
              '✅ Gallery ထဲသို့ သိမ်းပြီးပါပြီ! (${sizeMb.toStringAsFixed(2)} MB)';
        });
      } else {
        double totalMb = 0;
        for (final path in tempOutputs) {
          await Gal.putVideo(path, album: 'LosslessCuts');
          totalMb += (await File(path).length()) / (1024 * 1024);
        }
        setState(() {
          _statusMessage =
              '✅ (${tempOutputs.length}) ဖိုင် သိမ်းပြီးပါပြီ! (${totalMb.toStringAsFixed(2)} MB)';
        });
      }
    } catch (e) {
      setState(() {
        _statusMessage = '❌ Error: $e';
      });
    } finally {
      setState(() {
        _isProcessing = false;
      });
    }
  }

  String _formatClock(double sec) {
    final int mins = sec ~/ 60;
    final int secs = (sec % 60).floor();
    return '${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }

  // CapCut ပုံစံ ဘယ်/ညာ အဖြူရောင် Handle ကို ဆွဲ၍ အတို/အရှည် ညှိနိုင်သော Video Segment Block
  Widget _buildSegmentBlock(int index, VideoSegment seg) {
    final double segWidth =
        (seg.duration * _pixelsPerSecond).clamp(4.0, 100000.0);
    final bool isSelected =
        index == _selectedIndex && _selectedSubId == null;
    final int tileCount = (segWidth / 48.0).ceil().clamp(1, 80);

    return GestureDetector(
      onTap: () {
        setState(() {
          _selectedIndex = index;
          _selectedSubId = null;
        });
      },
      child: SizedBox(
        width: segWidth,
        height: 58,
        child: Stack(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(isSelected ? 5 : 2),
              child: Row(
                children: List.generate(tileCount, (tIdx) {
                  final sampleSec =
                      seg.start + ((tIdx + 0.3) / tileCount) * seg.duration;
                  final int thumbIdx = _maxOriginalDuration > 0
                      ? ((sampleSec / _maxOriginalDuration) * _thumbCount)
                          .floor()
                          .clamp(0, _thumbCount - 1)
                      : 0;
                  final thumbPath = thumbIdx < _thumbnails.length
                      ? _thumbnails[thumbIdx]
                      : null;

                  return Expanded(
                    child: Container(
                      height: 58,
                      color: const Color(0xFF222222),
                      child: thumbPath != null
                          ? Image.file(
                              File(thumbPath),
                              fit: BoxFit.cover,
                            )
                          : const SizedBox.shrink(),
                    ),
                  );
                }),
              ),
            ),

            // ရွေးထားချိန်တွင် ပေါ်လာမည့် CapCut ဘယ်/ညာ Draggable Trim Handles
            if (isSelected)
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(color: Colors.white, width: 2.0),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // ဘယ်ဘက် Trim Handle (Start ကို ဆွဲရွှေ့ရန်)
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onHorizontalDragUpdate: (details) {
                          final deltaSec = details.delta.dx / _pixelsPerSecond;
                          setState(() {
                            seg.start = (seg.start + deltaSec)
                                .clamp(0.0, seg.end - 0.3);
                          });
                        },
                        child: Container(
                          width: 14,
                          height: double.infinity,
                          decoration: const BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.horizontal(
                              left: Radius.circular(3),
                            ),
                          ),
                          child: Center(
                            child: Container(
                              width: 2,
                              height: 16,
                              color: Colors.black87,
                            ),
                          ),
                        ),
                      ),
                      // ညာဘက် Trim Handle (End ကို ဆွဲရွှေ့ရန်)
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onHorizontalDragUpdate: (details) {
                          final deltaSec = details.delta.dx / _pixelsPerSecond;
                          setState(() {
                            seg.end = (seg.end + deltaSec).clamp(
                              seg.start + 0.3,
                              _maxOriginalDuration,
                            );
                          });
                        },
                        child: Container(
                          width: 14,
                          height: double.infinity,
                          decoration: const BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.horizontal(
                              right: Radius.circular(3),
                            ),
                          ),
                          child: Center(
                            child: Container(
                              width: 2,
                              height: 16,
                              color: Colors.black87,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            if (segWidth > 36)
              Positioned(
                top: 4,
                left: isSelected ? 16 : 5,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(
                    '${seg.duration.toStringAsFixed(1)}s',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 9.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // Text တစ်ခုပြီးတိုင်း အောက်တစ်တန်းစီ ဆင်းသွားသည့် Multi-Row Text Tracks
  Widget _buildStackedTextRows(double halfScreen) {
    int maxRow = -1;
    for (final s in _subtitles) {
      if (s.trackRow > maxRow) maxRow = s.trackRow;
    }
    final int rowCount = (maxRow + 1).clamp(1, 20);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: List.generate(rowCount, (rowIdx) {
        final rowSubs =
            _subtitles.where((s) => s.trackRow == rowIdx).toList();

        return Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(
            children: [
              // ဘယ်ဘက် "T" Icon
              SizedBox(
                width: halfScreen,
                height: 32,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: GestureDetector(
                    onTap: () => _showAddOrEditTextSheet(),
                    child: Container(
                      width: 34,
                      height: 30,
                      margin: const EdgeInsets.only(right: 12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1C1C1C),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Center(
                        child: Text(
                          rowIdx == 0 ? 'T' : 'T${rowIdx + 1}',
                          style: const TextStyle(
                            color: Color(0xFF00E5FF),
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),

              // Text Track Bar
              Container(
                width: _totalTimelineWidth,
                height: 32,
                decoration: BoxDecoration(
                  color: const Color(0xFF171717),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    if (rowSubs.isEmpty && rowIdx == 0)
                      Positioned.fill(
                        child: GestureDetector(
                          onTap: () => _showAddOrEditTextSheet(),
                          child: const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 10),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                '+ Add text (နှိပ်လိုက်တိုင်း အောက်တစ်တန်းစီ ဆင်းသွားပါမည်)',
                                style: TextStyle(
                                  color: Colors.white54,
                                  fontSize: 11,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ...rowSubs.map((sub) {
                      final leftPx = (sub.start * _pixelsPerSecond)
                          .clamp(0.0, _totalTimelineWidth);
                      final widthPx = (sub.duration * _pixelsPerSecond)
                          .clamp(24.0, _totalTimelineWidth);
                      final isSubSel = _selectedSubId == sub.id;

                      return Positioned(
                        left: leftPx,
                        top: 1,
                        bottom: 1,
                        width: widthPx,
                        child: GestureDetector(
                          onTap: () {
                            setState(() {
                              _selectedSubId = sub.id;
                            });
                          },
                          onDoubleTap: () {
                            setState(() {
                              _selectedSubId = sub.id;
                            });
                            _showAddOrEditTextSheet(editItem: sub);
                          },
                          onHorizontalDragUpdate: (details) {
                            // Text တုံးကို Timeline ပေါ် လက်ဖြင့် ဘယ်/ညာ ရွှေ့ခြင်း
                            final deltaSec =
                                details.delta.dx / _pixelsPerSecond;
                            final dur = sub.duration;
                            final newStart = (sub.start + deltaSec).clamp(
                              0.0,
                              (_totalActiveDuration - dur)
                                  .clamp(0.0, _totalActiveDuration),
                            );
                            setState(() {
                              _selectedSubId = sub.id;
                              sub.start = newStart;
                              sub.end = newStart + dur;
                            });
                          },
                          child: Container(
                            decoration: BoxDecoration(
                              color: isSubSel
                                  ? const Color(0xFFE65100)
                                  : const Color(0xFFBF360C),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                color:
                                    isSubSel ? Colors.white : Colors.white38,
                                width: isSubSel ? 1.6 : 0.7,
                              ),
                            ),
                            child: Row(
                              children: [
                                // ဘယ်ဘက် Text Trim Handle
                                if (isSubSel)
                                  GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onHorizontalDragUpdate: (d) {
                                      final dSec = d.delta.dx / _pixelsPerSecond;
                                      setState(() {
                                        sub.start = (sub.start + dSec)
                                            .clamp(0.0, sub.end - 0.3);
                                      });
                                    },
                                    child: Container(
                                      width: 8,
                                      color: Colors.white,
                                    ),
                                  ),
                                Expanded(
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 5,
                                    ),
                                    child: Text(
                                      sub.text.replaceAll('\n', ' '),
                                      style: TextStyle(
                                        fontFamily:
                                            sub.fontFamily == 'Default'
                                                ? null
                                                : sub.fontFamily,
                                        color: Colors.white,
                                        fontSize: 10.5,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                                // ညာဘက် Text Trim Handle
                                if (isSubSel)
                                  GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onHorizontalDragUpdate: (d) {
                                      final dSec = d.delta.dx / _pixelsPerSecond;
                                      setState(() {
                                        sub.end = (sub.end + dSec).clamp(
                                          sub.start + 0.3,
                                          _totalActiveDuration,
                                        );
                                      });
                                    },
                                    child: Container(
                                      width: 8,
                                      color: Colors.white,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      );
                    }),
                  ],
                ),
              ),

              SizedBox(width: halfScreen),
            ],
          ),
        );
      }),
    );
  }

  // CapCut အတိုင်း Pinch-to-Zoom ပါဝင်သော အလယ်ပိုင်း Multi-Track Timeline Area
  Widget _buildCapCutTimelineArea() {
    // Zoom အနီး/အဝေးပေါ် မူတည်၍ အချိန်ပေတံ (Ruler) ကြားကာလကို အလိုအလျောက် ပြောင်းလဲခြင်း
    int stepSec = 1;
    if (_pixelsPerSecond < 25) {
      stepSec = 5;
    } else if (_pixelsPerSecond < 45) {
      stepSec = 2;
    }
    final int tickCount = (_totalActiveDuration / stepSec).ceil().clamp(1, 2000);

    return Expanded(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final halfScreen = constraints.maxWidth / 2.0;

          return Listener(
            onPointerDown: _handlePointerDown,
            onPointerMove: _handlePointerMove,
            onPointerUp: _handlePointerUpOrCancel,
            onPointerCancel: _handlePointerUpOrCancel,
            child: Stack(
              alignment: Alignment.topCenter,
              children: [
                NotificationListener<ScrollNotification>(
                  onNotification: (notification) {
                    if (_isPinching) return false;
                    if (notification is ScrollStartNotification &&
                        notification.dragDetails != null) {
                      _isUserScrolling = true;
                      if (_controller!.value.isPlaying) {
                        _controller!.pause();
                      }
                    } else if (notification is ScrollUpdateNotification &&
                        _isUserScrolling) {
                      final targetVideoSec = _offsetToVideoSeconds(
                        _timelineScrollController.offset,
                      );
                      _seekToVideoSec(targetVideoSec);
                    } else if (notification is ScrollEndNotification) {
                      _isUserScrolling = false;
                    }
                    return false;
                  },
                  child: SingleChildScrollView(
                    controller: _timelineScrollController,
                    scrollDirection: Axis.horizontal,
                    physics: _isPinching
                        ? const NeverScrollableScrollPhysics()
                        : const ClampingScrollPhysics(),
                    child: SizedBox(
                      width: halfScreen + _totalTimelineWidth + halfScreen,
                      child: SingleChildScrollView(
                        controller: _verticalTrackScrollController,
                        scrollDirection: Axis.vertical,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // 1. Dynamic Time Ruler (00:00 • 00:01 • 00:02)
                            Row(
                              children: [
                                SizedBox(width: halfScreen),
                                ClipRect(
                                  child: SizedBox(
                                    width: _totalTimelineWidth,
                                    height: 24,
                                    child: OverflowBox(
                                      alignment: Alignment.centerLeft,
                                      maxWidth: (tickCount + 2) *
                                          stepSec *
                                          _pixelsPerSecond,
                                      child: Row(
                                        children: List.generate(
                                            tickCount + 1, (idx) {
                                          final sec = idx * stepSec;
                                          return SizedBox(
                                            width: stepSec * _pixelsPerSecond,
                                            child: Row(
                                              mainAxisAlignment:
                                                  MainAxisAlignment
                                                      .spaceBetween,
                                              children: [
                                                Text(
                                                  _formatClock(sec.toDouble()),
                                                  style: const TextStyle(
                                                    color: Colors.white54,
                                                    fontSize: 10,
                                                  ),
                                                ),
                                                const Text(
                                                  '•',
                                                  style: TextStyle(
                                                    color: Colors.white38,
                                                    fontSize: 10,
                                                  ),
                                                ),
                                                const SizedBox(width: 4),
                                              ],
                                            ),
                                          );
                                        }),
                                      ),
                                    ),
                                  ),
                                ),
                                SizedBox(width: halfScreen),
                              ],
                            ),

                            const SizedBox(height: 4),

                            // 2. Cover + Video Filmstrip + "+" Button
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                SizedBox(
                                  width: halfScreen,
                                  height: 58,
                                  child: Align(
                                    alignment: Alignment.centerRight,
                                    child: Container(
                                      width: 46,
                                      height: 58,
                                      margin: const EdgeInsets.only(right: 8),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF1F1F1F),
                                        borderRadius: BorderRadius.circular(6),
                                        image: _thumbnails.isNotEmpty &&
                                                _thumbnails.first != null
                                            ? DecorationImage(
                                                image: FileImage(
                                                  File(_thumbnails.first!),
                                                ),
                                                fit: BoxFit.cover,
                                                colorFilter:
                                                    const ColorFilter.mode(
                                                  Colors.black45,
                                                  BlendMode.darken,
                                                ),
                                              )
                                            : null,
                                      ),
                                      child: const Column(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          Icon(
                                            Icons.edit_outlined,
                                            size: 15,
                                            color: Colors.white,
                                          ),
                                          SizedBox(height: 2),
                                          Text(
                                            'Cover',
                                            style: TextStyle(
                                              fontSize: 9.5,
                                              color: Colors.white,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                                SizedBox(
                                  width: _totalTimelineWidth,
                                  height: 58,
                                  child: Row(
                                    children: _segments
                                        .asMap()
                                        .entries
                                        .map((e) =>
                                            _buildSegmentBlock(e.key, e.value))
                                        .toList(),
                                  ),
                                ),
                                SizedBox(
                                  width: halfScreen,
                                  height: 58,
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: Padding(
                                      padding: const EdgeInsets.only(left: 8),
                                      child: GestureDetector(
                                        onTap: _pickVideo,
                                        child: Container(
                                          width: 36,
                                          height: 36,
                                          decoration: BoxDecoration(
                                            color: Colors.white,
                                            borderRadius:
                                                BorderRadius.circular(6),
                                          ),
                                          child: const Icon(
                                            Icons.add,
                                            color: Colors.black,
                                            size: 22,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),

                            const SizedBox(height: 8),

                            // 3. Audio Track Row
                            Row(
                              children: [
                                SizedBox(
                                  width: halfScreen,
                                  height: 30,
                                  child: Align(
                                    alignment: Alignment.centerRight,
                                    child: Container(
                                      width: 34,
                                      height: 30,
                                      margin: const EdgeInsets.only(right: 12),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF1C1C1C),
                                        borderRadius: BorderRadius.circular(5),
                                      ),
                                      child: Icon(
                                        _isMuted
                                            ? Icons.music_off
                                            : Icons.music_note,
                                        size: 15,
                                        color: _isMuted
                                            ? Colors.redAccent
                                            : Colors.white54,
                                      ),
                                    ),
                                  ),
                                ),
                                GestureDetector(
                                  onTap: _toggleMute,
                                  child: Container(
                                    width: _totalTimelineWidth,
                                    height: 30,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                    ),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF1C1C1C),
                                      borderRadius: BorderRadius.circular(5),
                                    ),
                                    alignment: Alignment.centerLeft,
                                    child: Text(
                                      _isMuted
                                          ? '🔇 Audio Muted (ပြန်ဖွင့်ရန် နှိပ်ပါ)'
                                          : '+ Add audio (အသံ ပိတ်/ဖွင့်ရန် နှိပ်ပါ)',
                                      style: const TextStyle(
                                        color: Colors.white54,
                                        fontSize: 11,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                                SizedBox(width: halfScreen),
                              ],
                            ),

                            const SizedBox(height: 6),

                            // 4. Multi-Row Stacked Text Tracks (Text အသစ်တိုင်း အောက်တစ်တန်းစီ ဆင်းသည်)
                            _buildStackedTextRows(halfScreen),

                            const SizedBox(height: 20),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),

                // ဘယ်ဘက်အပေါ်ထောင့်ရှိ အချိန်ပြ Badge ("00:02 / 01:06")
                Positioned(
                  top: 2,
                  left: 10,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    color: const Color(0xFF0E0E0E),
                    child: RichText(
                      text: TextSpan(
                        style: const TextStyle(fontSize: 11),
                        children: [
                          TextSpan(
                            text: _formatClock(_currentTimelinePosition()),
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          TextSpan(
                            text: ' / ${_formatClock(_totalActiveDuration)}',
                            style: const TextStyle(color: Colors.white54),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

                // ညာဘက်အပေါ်ထောင့်ရှိ အမြန် Zoom (- / +) ခလုတ်ငယ်
                Positioned(
                  top: 0,
                  right: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xDD181818),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        InkWell(
                          onTap: () => _stepZoom(0.75),
                          child: const Padding(
                            padding: EdgeInsets.all(4),
                            child: Icon(Icons.remove, size: 15, color: Colors.white70),
                          ),
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 3),
                          child: Icon(Icons.pinch, size: 13, color: Color(0xFF00E5FF)),
                        ),
                        InkWell(
                          onTap: () => _stepZoom(1.35),
                          child: const Padding(
                            padding: EdgeInsets.all(4),
                            child: Icon(Icons.add, size: 15, color: Colors.white70),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // အလယ်ဗဟိုရှိ အဖြူရောင် ဒေါင်လိုက် Playhead မျဉ်းကြောင်း
                Positioned(
                  top: 22,
                  bottom: 0,
                  child: IgnorePointer(
                    child: Container(
                      width: 2.2,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // Video Preview ပေါ်တွင် လက်ဖြင့် စိတ်ကြိုက် ဆွဲရွှေ့ / အကြီးအသေးချဲ့နိုင်သော Interactive Text Layer
  Widget _buildInteractiveVideoTexts() {
    final activeSubs = _getActiveSubtitlesAt(_currentTimelinePosition());
    if (activeSubs.isEmpty) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        final canvasW = constraints.maxWidth;
        final canvasH = constraints.maxHeight;

        return Stack(
          clipBehavior: Clip.none,
          children: activeSubs.map((sub) {
            final isSelected = _selectedSubId == sub.id;
            final fontFam = sub.fontFamily == 'Default' ? null : sub.fontFamily;
            final leftPos = (sub.xRatio * canvasW).clamp(10.0, canvasW - 10.0);
            final topPos = (sub.yRatio * canvasH).clamp(10.0, canvasH - 10.0);

            return Positioned(
              left: leftPos,
              top: topPos,
              child: FractionalTranslation(
                translation: const Offset(-0.5, -0.5),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    setState(() {
                      _selectedSubId = sub.id;
                    });
                  },
                  onDoubleTap: () {
                    setState(() {
                      _selectedSubId = sub.id;
                    });
                    _showAddOrEditTextSheet(editItem: sub);
                  },
                  onPanUpdate: (details) {
                    // Video ပေါ်တွင် လက်ဖြင့် စိတ်ကြိုက်နေရာ ဆွဲရွှေ့ခြင်း
                    setState(() {
                      _selectedSubId = sub.id;
                      sub.xRatio = (sub.xRatio + details.delta.dx / canvasW)
                          .clamp(0.06, 0.94);
                      sub.yRatio = (sub.yRatio + details.delta.dy / canvasH)
                          .clamp(0.06, 0.94);
                    });
                  },
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Container(
                        constraints: BoxConstraints(maxWidth: canvasW * 0.9),
                        margin: const EdgeInsets.all(10),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: sub.hasBackBox
                              ? Colors.black54
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(5),
                          border: isSelected
                              ? Border.all(color: Colors.white, width: 1.6)
                              : null,
                        ),
                        child: Stack(
                          children: [
                            Text(
                              sub.text,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontFamily: fontFam,
                                fontSize: sub.fontSize,
                                fontWeight: FontWeight.w700,
                                height: 1.3,
                                foreground: Paint()
                                  ..style = PaintingStyle.stroke
                                  ..strokeWidth = 3.0
                                  ..color = sub.strokeColor,
                              ),
                            ),
                            Text(
                              sub.text,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontFamily: fontFam,
                                fontSize: sub.fontSize,
                                fontWeight: FontWeight.w700,
                                height: 1.3,
                                color: sub.textColor,
                              ),
                            ),
                          ],
                        ),
                      ),

                      // CapCut ပုံစံ ထောင့်စွန်း ခလုတ်များ (✕ ဖျက်ရန်, ✎ ပြင်ရန်, ⤡ ဆွဲချဲ့ရန်)
                      if (isSelected) ...[
                        // ဘယ်အပေါ်ထောင့် (✕ Delete)
                        Positioned(
                          left: 0,
                          top: 0,
                          child: GestureDetector(
                            onTap: _deleteSelectedItem,
                            child: Container(
                              width: 22,
                              height: 22,
                              decoration: const BoxDecoration(
                                color: Colors.white,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.close,
                                size: 15,
                                color: Colors.black,
                              ),
                            ),
                          ),
                        ),

                        // ညာအပေါ်ထောင့် (✎ Edit)
                        Positioned(
                          right: 0,
                          top: 0,
                          child: GestureDetector(
                            onTap: () => _showAddOrEditTextSheet(editItem: sub),
                            child: Container(
                              width: 22,
                              height: 22,
                              decoration: const BoxDecoration(
                                color: Colors.white,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.edit,
                                size: 14,
                                color: Colors.black,
                              ),
                            ),
                          ),
                        ),

                        // ညာအောက်ထောင့် (⤡ လက်ဖြင့်ဆွဲ၍ စာလုံး အကြီး/အသေး ချဲ့ရန်)
                        Positioned(
                          right: 0,
                          bottom: 0,
                          child: GestureDetector(
                            onPanUpdate: (d) {
                              setState(() {
                                sub.fontSize =
                                    (sub.fontSize + (d.delta.dx + d.delta.dy) * 0.25)
                                        .clamp(10.0, 64.0);
                              });
                            },
                            child: Container(
                              width: 22,
                              height: 22,
                              decoration: const BoxDecoration(
                                color: Color(0xFF00E5FF),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.open_in_full,
                                size: 13,
                                color: Colors.black,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            );
          }).toList(),
        );
      },
    );
  }

  Widget _buildBottomCapCutBar() {
    return Container(
      height: 66,
      decoration: const BoxDecoration(
        color: Color(0xFF141414),
        border: Border(
          top: BorderSide(color: Colors.white10, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 44,
            margin: const EdgeInsets.only(left: 6, right: 2),
            decoration: BoxDecoration(
              color: const Color(0xFF222222),
              borderRadius: BorderRadius.circular(6),
            ),
            child: IconButton(
              padding: EdgeInsets.zero,
              icon: const Icon(Icons.chevron_left, color: Colors.white70),
              onPressed: _pickVideo,
            ),
          ),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _buildToolItem(
                  icon: Icons.vertical_split,
                  label: 'Split',
                  onTap: _splitAtPlayhead,
                ),
                _buildToolItem(
                  icon: _isMuted ? Icons.volume_off : Icons.volume_up_outlined,
                  label: 'Volume',
                  onTap: _toggleMute,
                ),
                _buildToolItem(
                  icon: Icons.text_fields,
                  label: 'Add Text',
                  onTap: () => _showAddOrEditTextSheet(),
                ),
                _buildToolItem(
                  icon: Icons.subtitles_outlined,
                  label: 'SRT ဖိုင်',
                  onTap: _importSrtFile,
                ),
                _buildToolItem(
                  icon: Icons.font_download_outlined,
                  label: 'Font',
                  onTap: _importCustomFont,
                ),
                _buildToolItem(
                  icon: Icons.delete_outline,
                  label: 'Delete',
                  onTap: _deleteSelectedItem,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToolItem({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 21),
            const SizedBox(height: 4),
            Text(
              label,
              style: const TextStyle(color: Colors.white70, fontSize: 10.5),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(46),
        child: AppBar(
          backgroundColor: const Color(0xFF0E0E0E),
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.close, color: Colors.white, size: 22),
            onPressed: _pickVideo,
          ),
          title: _statusMessage.isNotEmpty
              ? Text(
                  _statusMessage,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF00E5FF),
                  ),
                  overflow: TextOverflow.ellipsis,
                )
              : Text(
                  'Lossless • Font: $_defaultFont',
                  style: const TextStyle(fontSize: 12.5, color: Colors.white70),
                ),
          centerTitle: true,
          actions: [
            if (_controller != null)
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: ElevatedButton(
                  onPressed: _isProcessing ? null : _showExportSheet,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00E5FF),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                  child: const Text(
                    'Export',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
      body: _controller == null
          ? Center(
              child: ElevatedButton.icon(
                onPressed: _pickVideo,
                icon: const Icon(Icons.add_circle_outline, color: Colors.black),
                label: const Text(
                  'New Project (ဗီဒီယို ရွေးမည်)',
                  style: TextStyle(
                    color: Colors.black,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00E5FF),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 28,
                    vertical: 16,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            )
          : Column(
              children: [
                // 1. Video Preview + CapCut Draggable/Resizable Text Box
                Expanded(
                  flex: 5,
                  child: GestureDetector(
                    onTap: () {
                      // ဗီဒီယို လွတ်နေသောနေရာကို နှိပ်ပါက Text ရွေးထားခြင်းကို ဖြုတ်ပေးရန်
                      setState(() {
                        _selectedSubId = null;
                      });
                    },
                    child: Container(
                      width: double.infinity,
                      color: Colors.black,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      child: Center(
                        child: AspectRatio(
                          aspectRatio: _controller!.value.aspectRatio,
                          child: Container(
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: const Color(0xFF00BCD4),
                                width: 1.2,
                              ),
                            ),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                VideoPlayer(_controller!),
                                _buildInteractiveVideoTexts(),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),

                // 2. Play/Pause နှင့် Undo / Redo Control Bar
                Container(
                  height: 42,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  color: const Color(0xFF0E0E0E),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      IconButton(
                        icon: const Icon(
                          Icons.fullscreen,
                          color: Colors.white70,
                          size: 22,
                        ),
                        onPressed: () {},
                      ),
                      IconButton(
                        iconSize: 28,
                        icon: Icon(
                          _controller!.value.isPlaying
                              ? Icons.pause
                              : Icons.play_arrow_outlined,
                          color: Colors.white,
                        ),
                        onPressed: () {
                          setState(() {
                            _controller!.value.isPlaying
                                ? _controller!.pause()
                                : _controller!.play();
                          });
                        },
                      ),
                      Row(
                        children: [
                          const Icon(
                            Icons.diamond_outlined,
                            color: Colors.white60,
                            size: 18,
                          ),
                          const SizedBox(width: 6),
                          IconButton(
                            icon: Icon(
                              Icons.undo,
                              color: _undoStack.isNotEmpty
                                  ? Colors.white
                                  : Colors.white24,
                              size: 20,
                            ),
                            onPressed: _undoStack.isNotEmpty ? _undo : null,
                          ),
                          IconButton(
                            icon: Icon(
                              Icons.redo,
                              color: _redoStack.isNotEmpty
                                  ? Colors.white
                                  : Colors.white24,
                              size: 20,
                            ),
                            onPressed: _redoStack.isNotEmpty ? _redo : null,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                // 3. Multi-Track Timeline (Pinch Zoom + Multi-Row Text)
                Expanded(
                  flex: 4,
                  child: Column(
                    children: [
                      _buildCapCutTimelineArea(),
                      _buildBottomCapCutBar(),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}
