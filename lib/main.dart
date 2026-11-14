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
  final double start;
  final double end;

  VideoSegment({required this.start, required this.end});

  double get duration => end - start;

  VideoSegment copy() => VideoSegment(start: start, end: end);
}

class SubtitleItem {
  double start; // Timeline (active) start time in seconds
  double end;   // Timeline (active) end time in seconds
  String text;

  SubtitleItem({
    required this.start,
    required this.end,
    required this.text,
  });

  double get duration => (end - start).clamp(0.1, 36000.0);

  SubtitleItem copy() => SubtitleItem(start: start, end: end, text: text);
}

class EditorSnapshot {
  final List<VideoSegment> segments;
  final List<SubtitleItem> subtitles;
  final int selectedIndex;

  EditorSnapshot({
    required this.segments,
    required this.subtitles,
    required this.selectedIndex,
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

  String? _videoPath;
  bool _isProcessing = false;
  bool _isUserScrolling = false;
  bool _isMuted = false;
  String _statusMessage = '';

  final List<String?> _thumbnails = [];
  List<VideoSegment> _segments = [];
  List<SubtitleItem> _subtitles = [];
  int _selectedIndex = 0;
  int? _selectedSubIndex;

  // Text & Font Styling
  final List<String> _loadedFonts = ['Default'];
  String _selectedFont = 'Default';
  double _fontSize = 20.0;
  Color _textColor = Colors.white;
  Color _strokeColor = Colors.black;
  bool _hasBackBox = true;
  double _verticalPosRatio = 0.85; // 0.1 (Top) to 0.9 (Bottom)

  // Undo / Redo Stacks
  final List<EditorSnapshot> _undoStack = [];
  final List<EditorSnapshot> _redoStack = [];

  static const int _thumbCount = 18;
  double _pixelsPerSecond = 55.0;

  double get _maxOriginalDuration => _controller != null
      ? _controller!.value.duration.inMilliseconds / 1000.0
      : 1.0;

  double get _totalActiveDuration =>
      _segments.fold(0.0, (sum, seg) => sum + seg.duration);

  // Segments အားလုံး၏ စုစုပေါင်းအကျယ်နှင့် တစ်ထပ်တည်းကျစေရန် တွက်ချက်ခြင်း
  double get _totalTimelineWidth {
    if (_segments.isEmpty) return 300.0;
    return _segments.fold(
      0.0,
      (sum, seg) => sum + (seg.duration * _pixelsPerSecond).clamp(32.0, 20000.0),
    );
  }

  @override
  void dispose() {
    _controller?.dispose();
    _timelineScrollController.dispose();
    super.dispose();
  }

  void _saveStateForUndo() {
    _undoStack.add(
      EditorSnapshot(
        segments: _segments.map((s) => s.copy()).toList(),
        subtitles: _subtitles.map((s) => s.copy()).toList(),
        selectedIndex: _selectedIndex,
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
      ),
    );
    final prev = _undoStack.removeLast();
    setState(() {
      _segments = prev.segments;
      _subtitles = prev.subtitles;
      _selectedIndex = prev.selectedIndex.clamp(0, _segments.length - 1);
      _selectedSubIndex = null;
    });
  }

  void _redo() {
    if (_redoStack.isEmpty) return;
    _undoStack.add(
      EditorSnapshot(
        segments: _segments.map((s) => s.copy()).toList(),
        subtitles: _subtitles.map((s) => s.copy()).toList(),
        selectedIndex: _selectedIndex,
      ),
    );
    final next = _redoStack.removeLast();
    setState(() {
      _segments = next.segments;
      _subtitles = next.subtitles;
      _selectedIndex = next.selectedIndex.clamp(0, _segments.length - 1);
      _selectedSubIndex = null;
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

      final autoPps = (850.0 / (maxDur > 0 ? maxDur : 10.0)).clamp(24.0, 90.0);

      controller.addListener(_onVideoTick);

      setState(() {
        _videoPath = path;
        _controller = controller;
        _pixelsPerSecond = autoPps;
        _isMuted = false;
        _segments = [VideoSegment(start: 0.0, end: maxDur)];
        _subtitles.clear();
        _selectedIndex = 0;
        _selectedSubIndex = null;
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

  // .srt ဖိုင် ရွေးချယ်ဖတ်ရှုခြင်း
  Future<void> _importSrtFile() async {
    if (_controller == null) return;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
    );
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
      if (parsed.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('SRT ဖိုင်ထဲတွင် စာတန်းများ မတွေ့ရှိပါ')),
          );
        }
        return;
      }

      _saveStateForUndo();
      setState(() {
        _subtitles.addAll(parsed);
        _subtitles.sort((a, b) => a.start.compareTo(b.start));
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
          items.add(
            SubtitleItem(start: startSec, end: endSec, text: cleanText),
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
        _selectedFont = fontName;
        _statusMessage = '🔤 Font "$fontName" ကို အသုံးပြုထားပါသည်';
      });
    }
  }

  void _onVideoTick() {
    if (!mounted || _controller == null || _segments.isEmpty) return;
    final posSec = _controller!.value.position.inMilliseconds / 1000.0;

    if (_controller!.value.isPlaying && !_isUserScrolling) {
      int foundIdx = -1;
      double pixelOffsetBefore = 0.0;

      for (int i = 0; i < _segments.length; i++) {
        final s = _segments[i];
        final segW = (s.duration * _pixelsPerSecond).clamp(32.0, 20000.0);
        if (posSec >= s.start - 0.05 && posSec <= s.end + 0.05) {
          foundIdx = i;
          final localRatio = s.duration > 0
              ? ((posSec - s.start) / s.duration).clamp(0.0, 1.0)
              : 0.0;
          final targetScroll = (pixelOffsetBefore + localRatio * segW)
              .clamp(0.0, _totalTimelineWidth);
          if (_timelineScrollController.hasClients) {
            _timelineScrollController.jumpTo(targetScroll);
          }
          break;
        }
        pixelOffsetBefore += segW;
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

  void _seekToVideoSec(double sec) {
    if (_controller == null) return;
    final clamped = sec.clamp(0.0, _maxOriginalDuration);
    _controller!.seekTo(Duration(milliseconds: (clamped * 1000).toInt()));
  }

  // Scroll Offset မှ ဗီဒီယို၏ အချိန်အမှန်သို့ အတိအကျ တွက်ချက်ပေးခြင်း
  double _offsetToVideoSeconds(double scrollOffset) {
    if (_segments.isEmpty || _totalTimelineWidth <= 0) return 0.0;
    final clampedOffset = scrollOffset.clamp(0.0, _totalTimelineWidth);

    double accWidth = 0.0;
    for (int i = 0; i < _segments.length; i++) {
      final seg = _segments[i];
      final segW = (seg.duration * _pixelsPerSecond).clamp(32.0, 20000.0);
      if (clampedOffset <= accWidth + segW || i == _segments.length - 1) {
        _selectedIndex = i;
        final localRatio =
            segW > 0 ? ((clampedOffset - accWidth) / segW).clamp(0.0, 1.0) : 0.0;
        return seg.start + localRatio * seg.duration;
      }
      accWidth += segW;
    }
    return _segments.last.end;
  }

  // လက်ရှိ Playhead ရောက်နေသော Active Timeline အချိန် (စက္ကန့်)
  double _currentTimelinePosition() {
    if (_controller == null || _segments.isEmpty) return 0.0;
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

  // လက်ရှိအချိန်တွင် ပေါ်နေရမည့် Subtitle / Text များကို ရယူခြင်း
  List<SubtitleItem> _getActiveSubtitlesAt(double timelineSec) {
    return _subtitles
        .where((s) => timelineSec >= s.start && timelineSec <= s.end)
        .toList();
  }

  void _splitAtPlayhead() {
    if (_controller == null || _segments.isEmpty) return;
    final posSec = _controller!.value.position.inMilliseconds / 1000.0;

    for (int i = 0; i < _segments.length; i++) {
      final seg = _segments[i];
      if (posSec > seg.start + 0.2 && posSec < seg.end - 0.2) {
        _saveStateForUndo();
        setState(() {
          final first = VideoSegment(start: seg.start, end: posSec);
          final second = VideoSegment(start: posSec, end: seg.end);
          _segments[i] = first;
          _segments.insert(i + 1, second);
          _selectedIndex = i + 1;
        });
        return;
      }
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('ဖြတ်မည့်နေရာသည် အပိုင်းအစ/အဆုံးနှင့် အနည်းငယ် ကွာရပါမည်'),
        duration: Duration(milliseconds: 900),
      ),
    );
  }

  void _deleteSelectedItem() {
    // အကယ်၍ Subtitle / Text ရွေးထားပါက ထိုစာသားကို အရင်ဖျက်ပေးမည်
    if (_selectedSubIndex != null &&
        _selectedSubIndex! >= 0 &&
        _selectedSubIndex! < _subtitles.length) {
      _saveStateForUndo();
      setState(() {
        _subtitles.removeAt(_selectedSubIndex!);
        _selectedSubIndex = null;
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

      // ဖျက်လိုက်သော အပိုင်းနောက်ရှိ Subtitle အချိန်များကို အလိုအလျောက် ရွှေ့ပေးခြင်း
      final List<SubtitleItem> updatedSubs = [];
      for (final s in _subtitles) {
        if (s.end <= removedTimelineStart) {
          updatedSubs.add(s);
        } else if (s.start >= removedTimelineEnd) {
          updatedSubs.add(
            SubtitleItem(
              start: s.start - removedDuration,
              end: s.end - removedDuration,
              text: s.text,
            ),
          );
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          _isMuted
              ? '🔇 ဗီဒီယိုအသံ ပိတ်ထားပါသည်'
              : '🔊 ဗီဒီယိုအသံ ပြန်ဖွင့်ထားပါသည်',
        ),
        duration: const Duration(milliseconds: 900),
      ),
    );
  }

  // စိတ်ကြိုက် Text ရေးသားခြင်း / ပြင်ဆင်ခြင်းနှင့် Font ရွေးချယ်ခြင်း Dialog
  void _showAddOrEditTextSheet({int? editIndex}) {
    if (_controller == null) return;
    final curTime = _currentTimelinePosition();
    final existing = editIndex != null ? _subtitles[editIndex] : null;

    final textCtrl = TextEditingController(text: existing?.text ?? '');
    final startCtrl = TextEditingController(
      text: (existing?.start ?? curTime).toStringAsFixed(2),
    );
    final endCtrl = TextEditingController(
      text: (existing?.end ??
              (curTime + 3.0).clamp(0.5, _totalActiveDuration))
          .toStringAsFixed(2),
    );

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
                top: 16,
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
                          editIndex != null
                              ? '✏️ စာသား ပြင်ဆင်ရန်'
                              : '➕ စိတ်ကြိုက် Text အသစ်ထည့်ရန်',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        TextButton.icon(
                          onPressed: () async {
                            await _importCustomFont();
                            setModalState(() {});
                          },
                          icon: const Icon(
                            Icons.font_download,
                            color: Color(0xFF00E5FF),
                            size: 18,
                          ),
                          label: const Text(
                            '+ Font (.ttf/.otf) ထည့်မည်',
                            style: TextStyle(color: Color(0xFF00E5FF)),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: textCtrl,
                      maxLines: 2,
                      style: TextStyle(
                        fontFamily:
                            _selectedFont == 'Default' ? null : _selectedFont,
                      ),
                      decoration: InputDecoration(
                        hintText: 'ပေါ်စေချင်သော စာသားကို ရိုက်ထည့်ပါ...',
                        filled: true,
                        fillColor: const Color(0xFF262626),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: startCtrl,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: const InputDecoration(
                              labelText: 'Start (စက္ကန့်)',
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            controller: endCtrl,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: const InputDecoration(
                              labelText: 'End (စက္ကန့်)',
                              isDense: true,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // Font ရွေးချယ်ရန် Chips
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: _loadedFonts.map((f) {
                          final selected = f == _selectedFont;
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
                                setModalState(() => _selectedFont = f);
                                setState(() => _selectedFont = f);
                              },
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                    const SizedBox(height: 8),

                    // စာလုံး အရွယ်အစားနှင့် အပေါ်/အောက် နေရာချိန်ညှိရန်
                    Row(
                      children: [
                        const Text('Size:', style: TextStyle(fontSize: 12)),
                        Expanded(
                          child: Slider(
                            value: _fontSize,
                            min: 12.0,
                            max: 38.0,
                            activeColor: const Color(0xFF00E5FF),
                            onChanged: (v) {
                              setModalState(() => _fontSize = v);
                              setState(() => _fontSize = v);
                            },
                          ),
                        ),
                        const Text('နေရာ:', style: TextStyle(fontSize: 12)),
                        Expanded(
                          child: Slider(
                            value: _verticalPosRatio,
                            min: 0.10,
                            max: 0.92,
                            activeColor: const Color(0xFF00E5FF),
                            onChanged: (v) {
                              setModalState(() => _verticalPosRatio = v);
                              setState(() => _verticalPosRatio = v);
                            },
                          ),
                        ),
                      ],
                    ),

                    // အရောင်ရွေးချယ်ရန်
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
                          ].map((c) {
                            final isSel = _textColor.value == c.value;
                            return GestureDetector(
                              onTap: () {
                                setModalState(() => _textColor = c);
                                setState(() => _textColor = c);
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
                          selected: _hasBackBox,
                          onSelected: (v) {
                            setModalState(() => _hasBackBox = v);
                            setState(() => _hasBackBox = v);
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        if (editIndex != null) ...[
                          OutlinedButton.icon(
                            onPressed: () {
                              _saveStateForUndo();
                              setState(() {
                                _subtitles.removeAt(editIndex);
                                _selectedSubIndex = null;
                              });
                              Navigator.pop(ctx);
                            },
                            icon: const Icon(
                              Icons.delete,
                              color: Colors.redAccent,
                            ),
                            label: const Text(
                              'ဖျက်မည်',
                              style: TextStyle(color: Colors.redAccent),
                            ),
                          ),
                          const SizedBox(width: 10),
                        ],
                        Expanded(
                          child: ElevatedButton(
                            onPressed: () {
                              final txt = textCtrl.text.trim();
                              final st = double.tryParse(startCtrl.text) ?? 0.0;
                              final en =
                                  double.tryParse(endCtrl.text) ?? (st + 3.0);
                              if (txt.isEmpty || en <= st) return;

                              _saveStateForUndo();
                              setState(() {
                                if (editIndex != null) {
                                  _subtitles[editIndex] = SubtitleItem(
                                    start: st,
                                    end: en,
                                    text: txt,
                                  );
                                } else {
                                  _subtitles.add(
                                    SubtitleItem(
                                      start: st,
                                      end: en,
                                      text: txt,
                                    ),
                                  );
                                  _subtitles.sort(
                                    (a, b) => a.start.compareTo(b.start),
                                  );
                                }
                              });
                              Navigator.pop(ctx);
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF00E5FF),
                              foregroundColor: Colors.black,
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                            child: Text(
                              editIndex != null ? 'သိမ်းမည်' : 'ထည့်မည်',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ],
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

  void _showZoomSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Timeline အကျယ် ချိန်ညှိရန် (Zoom)',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                  ),
                  Slider(
                    value: _pixelsPerSecond,
                    min: 20.0,
                    max: 160.0,
                    activeColor: const Color(0xFF00E5FF),
                    onChanged: (val) {
                      setModalState(() => _pixelsPerSecond = val);
                      setState(() => _pixelsPerSecond = val);
                    },
                  ),
                ],
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
                'အပိုင်း (${_segments.length}) ပိုင်း • စာတန်း (${_subtitles.length}) ခု • စုစုပေါင်း ${_formatClock(_totalActiveDuration)}',
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
                    'စာတန်း/Font များကို Video ပေါ်အသေကပ်ပြီး ထုတ်မည်',
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

  // Flutter TextPainter ဖြင့် မြန်မာစာနှင့် Custom Font ကို PNG ပုံရိပ်အဖြစ် ဖန်တီးခြင်း
  Future<void> _renderSubtitlePng({
    required String text,
    required int width,
    required int height,
    required String outPath,
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(
      recorder,
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    );

    if (text.trim().isNotEmpty) {
      final scaleFactor = (width / 360.0).clamp(1.0, 4.0);
      final scaledFontSize = _fontSize * scaleFactor;
      final fontFam = _selectedFont == 'Default' ? null : _selectedFont;

      // Outline Text Painter
      final strokeSpan = TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: fontFam,
          fontSize: scaledFontSize,
          fontWeight: FontWeight.w700,
          height: 1.3,
          foreground: Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3.5 * scaleFactor
            ..color = _strokeColor,
        ),
      );
      final strokePainter = TextPainter(
        text: strokeSpan,
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: width * 0.9);

      // Fill Text Painter
      final fillSpan = TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: fontFam,
          fontSize: scaledFontSize,
          fontWeight: FontWeight.w700,
          height: 1.3,
          color: _textColor,
        ),
      );
      final fillPainter = TextPainter(
        text: fillSpan,
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: width * 0.9);

      final dx = (width - fillPainter.width) / 2.0;
      final dy = ((height - fillPainter.height) * _verticalPosRatio)
          .clamp(8.0, (height - fillPainter.height - 8.0).clamp(8.0, height.toDouble()));

      if (_hasBackBox) {
        final bgRect = RRect.fromRectAndRadius(
          Rect.fromLTWH(
            dx - 12 * scaleFactor,
            dy - 6 * scaleFactor,
            fillPainter.width + 24 * scaleFactor,
            fillPainter.height + 12 * scaleFactor,
          ),
          Radius.circular(8 * scaleFactor),
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
          ? '⏳ စာတန်းများကို Custom Font ဖြင့် ကပ်နေပါသည်...'
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

        // စာတန်း/Text များကို ဗီဒီယိုပေါ် အသေကပ်မည်ဆိုပါက
        if (burnSubtitles && _subtitles.isNotEmpty) {
          final vidW = _controller!.value.size.width.toInt().clamp(320, 1920);
          final vidH = _controller!.value.size.height.toInt().clamp(320, 1920);

          // မူရင်း ဗီဒီယို၏ Bitrate အတိုင်း ထိန်းထားရန် တွက်ချက်ခြင်း
          final origBytes = await File(_videoPath!).length();
          final origBitrate =
              ((origBytes * 8) / (_maxOriginalDuration > 0 ? _maxOriginalDuration : 10))
                  .round()
                  .clamp(600000, 12000000);

          // အချိန်အပိုင်းအခြားအလိုက် Subtitle PNG များ ဆွဲထုတ်ခြင်း
          final Set<double> timePoints = {0.0, _totalActiveDuration};
          for (final s in _subtitles) {
            timePoints.add(s.start.clamp(0.0, _totalActiveDuration));
            timePoints.add(s.end.clamp(0.0, _totalActiveDuration));
          }
          final sortedPts = timePoints.toList()..sort();

          final blankPng = '${tempDir.path}/blank_$timestamp.png';
          await _renderSubtitlePng(
            text: '',
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
              final combinedText = activeSubs.map((e) => e.text).join('\n');
              pngPath = '${tempDir.path}/sub_${timestamp}_$i.png';
              await _renderSubtitlePng(
                text: combinedText,
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
          // Android Hardware H.264 Encoder ဖြင့် မူရင်း Bitrate အတိုင်း အမြန်ကပ်ခြင်း
          String burnCmd =
              '-y -i "$baseMergedPath" -f concat -safe 0 -i "${subConcatFile.path}" -filter_complex "[0:v][1:v]overlay=0:0:shortest=1" -c:v h264_mediacodec -b:v $origBitrate -c:a copy "$burnedPath"';

          var session = await FFmpegKit.execute(burnCmd);
          var rc = await session.getReturnCode();

          if (!ReturnCode.isSuccess(rc)) {
            // Fallback encoder
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
              '✅ Gallery (LosslessCuts) ထဲသို့ သိမ်းပြီးပါပြီ! (${sizeMb.toStringAsFixed(2)} MB)';
        });
      } else {
        double totalMb = 0;
        for (final path in tempOutputs) {
          await Gal.putVideo(path, album: 'LosslessCuts');
          totalMb += (await File(path).length()) / (1024 * 1024);
        }
        setState(() {
          _statusMessage =
              '✅ (${tempOutputs.length}) ဖိုင်ကို Gallery ထဲသို့ သိမ်းပြီးပါပြီ! (စုစုပေါင်း ${totalMb.toStringAsFixed(2)} MB)';
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

  Widget _buildSegmentBlock(int index, VideoSegment seg) {
    final double segWidth =
        (seg.duration * _pixelsPerSecond).clamp(32.0, 20000.0);
    final bool isSelected =
        index == _selectedIndex && _selectedSubIndex == null;
    final int tileCount = (segWidth / 54.0).ceil().clamp(1, 40);

    return GestureDetector(
      onTap: () {
        setState(() {
          _selectedIndex = index;
          _selectedSubIndex = null;
        });
      },
      child: SizedBox(
        width: segWidth,
        height: 62,
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
                      height: 62,
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
                      Container(
                        width: 11,
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
                            color: Colors.black54,
                          ),
                        ),
                      ),
                      Container(
                        width: 11,
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
                            color: Colors.black54,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            Positioned(
              top: 4,
              left: isSelected ? 15 : 5,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(
                  '${seg.duration.toStringAsFixed(1)}s',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
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

  // Playhead သည် ဗီဒီယိုအဆုံး (+) ခလုတ်မတိုင်ခင် အစွန်းတွင် အတိအကျ ရပ်တန့်စေသော Timeline Area
  Widget _buildCapCutTimelineArea() {
    final totalSecs = _totalActiveDuration.ceil().clamp(1, 3600);

    return Expanded(
      child: LayoutBuilder(
        builder: (context, constraints) {
          // မျက်နှာပြင်အကျယ်၏ တစ်ဝက်အတိအကျ
          final halfScreen = constraints.maxWidth / 2.0;

          return Stack(
            alignment: Alignment.topCenter,
            children: [
              NotificationListener<ScrollNotification>(
                onNotification: (notification) {
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
                  physics: const ClampingScrollPhysics(),
                  // စုစုပေါင်းအကျယ် = halfScreen + _totalTimelineWidth + halfScreen ဖြစ်သဖြင့်
                  // maxScrollExtent သည် _totalTimelineWidth နှင့် 100% တစ်ထပ်တည်း ဖြစ်ပြီး
                  // ဗီဒီယိုအဆုံးကို လုံးဝကျော်မသွားနိုင်တော့ပါ။
                  child: SizedBox(
                    width: halfScreen + _totalTimelineWidth + halfScreen,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 1. အချိန်ပြ ပေတံတန်း (Time Ruler)
                        Row(
                          children: [
                            SizedBox(width: halfScreen),
                            ClipRect(
                              child: SizedBox(
                                width: _totalTimelineWidth,
                                height: 24,
                                child: OverflowBox(
                                  alignment: Alignment.centerLeft,
                                  maxWidth: (totalSecs + 2) * _pixelsPerSecond,
                                  child: Row(
                                    children:
                                        List.generate(totalSecs + 1, (sec) {
                                      return SizedBox(
                                        width: _pixelsPerSecond,
                                        child: Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.spaceBetween,
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

                        // 2. Cover ခလုတ် + Video Filmstrip + ညာဘက် "+" ခလုတ်
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            // ဘယ်ဘက် halfScreen အတွင်းရှိ Cover ခလုတ်
                            SizedBox(
                              width: halfScreen,
                              height: 62,
                              child: Align(
                                alignment: Alignment.centerRight,
                                child: Container(
                                  width: 48,
                                  height: 62,
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
                                            colorFilter: const ColorFilter.mode(
                                              Colors.black45,
                                              BlendMode.darken,
                                            ),
                                          )
                                        : null,
                                  ),
                                  child: const Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(
                                        Icons.edit_outlined,
                                        size: 16,
                                        color: Colors.white,
                                      ),
                                      SizedBox(height: 2),
                                      Text(
                                        'Cover',
                                        style: TextStyle(
                                          fontSize: 10,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),

                            // အလယ်ရှိ Video Segments အတန်း (အကျယ် = _totalTimelineWidth အတိအကျ)
                            SizedBox(
                              width: _totalTimelineWidth,
                              height: 62,
                              child: Row(
                                children: _segments
                                    .asMap()
                                    .entries
                                    .map(
                                      (e) => _buildSegmentBlock(e.key, e.value),
                                    )
                                    .toList(),
                              ),
                            ),

                            // ညာဘက် halfScreen အတွင်းရှိ "+" ခလုတ် (Scroll အဆုံးသတ်ကို မကျော်စေပါ)
                            SizedBox(
                              width: halfScreen,
                              height: 62,
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: Padding(
                                  padding: const EdgeInsets.only(left: 8),
                                  child: GestureDetector(
                                    onTap: _pickVideo,
                                    child: Container(
                                      width: 38,
                                      height: 38,
                                      decoration: BoxDecoration(
                                        color: Colors.white,
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: const Icon(
                                        Icons.add,
                                        color: Colors.black,
                                        size: 24,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),

                        const SizedBox(height: 10),

                        // 3. Audio Track Row
                        Row(
                          children: [
                            SizedBox(
                              width: halfScreen,
                              height: 34,
                              child: Align(
                                alignment: Alignment.centerRight,
                                child: Container(
                                  width: 38,
                                  height: 34,
                                  margin: const EdgeInsets.only(right: 12),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF1C1C1C),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Icon(
                                    _isMuted
                                        ? Icons.music_off
                                        : Icons.music_note,
                                    size: 17,
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
                                height: 34,
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 12),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF1C1C1C),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  _isMuted
                                      ? '🔇 Original Audio Muted (ပြန်ဖွင့်ရန် နှိပ်ပါ)'
                                      : '+ Add audio (မူရင်းအသံ ပိတ်/ဖွင့်ရန် နှိပ်ပါ)',
                                  style: const TextStyle(
                                    color: Colors.white60,
                                    fontSize: 11.5,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                            SizedBox(width: halfScreen),
                          ],
                        ),

                        const SizedBox(height: 8),

                        // 4. Interactive Subtitle / Text Track Row
                        Row(
                          children: [
                            SizedBox(
                              width: halfScreen,
                              height: 36,
                              child: Align(
                                alignment: Alignment.centerRight,
                                child: GestureDetector(
                                  onTap: () => _showAddOrEditTextSheet(),
                                  child: Container(
                                    width: 38,
                                    height: 34,
                                    margin: const EdgeInsets.only(right: 12),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF1C1C1C),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: const Icon(
                                      Icons.text_fields,
                                      size: 17,
                                      color: Color(0xFF00E5FF),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            Container(
                              width: _totalTimelineWidth,
                              height: 36,
                              decoration: BoxDecoration(
                                color: const Color(0xFF1C1C1C),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Stack(
                                children: [
                                  if (_subtitles.isEmpty)
                                    Positioned.fill(
                                      child: GestureDetector(
                                        onTap: () => _showAddOrEditTextSheet(),
                                        child: const Padding(
                                          padding: EdgeInsets.symmetric(
                                            horizontal: 12,
                                          ),
                                          child: Align(
                                            alignment: Alignment.centerLeft,
                                            child: Text(
                                              '+ Add text / SRT (စာသားရေးရန် သို့မဟုတ် SRT ထည့်ရန် နှိပ်ပါ)',
                                              style: TextStyle(
                                                color: Colors.white60,
                                                fontSize: 11.5,
                                              ),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ..._subtitles.asMap().entries.map((entry) {
                                    final idx = entry.key;
                                    final sub = entry.value;
                                    final leftPx = (sub.start * _pixelsPerSecond)
                                        .clamp(0.0, _totalTimelineWidth - 20);
                                    final widthPx =
                                        (sub.duration * _pixelsPerSecond).clamp(
                                      28.0,
                                      _totalTimelineWidth - leftPx,
                                    );
                                    final isSubSel = _selectedSubIndex == idx;

                                    return Positioned(
                                      left: leftPx,
                                      top: 2,
                                      bottom: 2,
                                      width: widthPx,
                                      child: GestureDetector(
                                        onTap: () {
                                          setState(() {
                                            _selectedSubIndex = idx;
                                          });
                                          _showAddOrEditTextSheet(
                                            editIndex: idx,
                                          );
                                        },
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 6,
                                          ),
                                          decoration: BoxDecoration(
                                            color: isSubSel
                                                ? const Color(0xFFE65100)
                                                : const Color(0xFFBF360C),
                                            borderRadius:
                                                BorderRadius.circular(4),
                                            border: Border.all(
                                              color: isSubSel
                                                  ? Colors.white
                                                  : Colors.white38,
                                              width: isSubSel ? 1.5 : 0.8,
                                            ),
                                          ),
                                          alignment: Alignment.centerLeft,
                                          child: Text(
                                            sub.text.replaceAll('\n', ' '),
                                            style: TextStyle(
                                              fontFamily:
                                                  _selectedFont == 'Default'
                                                      ? null
                                                      : _selectedFont,
                                              color: Colors.white,
                                              fontSize: 10.5,
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
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
                      ],
                    ),
                  ),
                ),
              ),

              // ဘယ်ဘက်ထောင့်ရှိ လက်ရှိအချိန် / စုစုပေါင်းအချိန် ("00:02 / 01:06")
              Positioned(
                top: 2,
                left: 12,
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

              // အလယ်ဗဟိုရှိ အဖြူရောင် ဒေါင်လိုက် Playhead မျဉ်းကြောင်း
              Positioned(
                top: 24,
                bottom: 8,
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
          );
        },
      ),
    );
  }

  // အောက်ဆုံး CapCut Toolbar (Split, Volume, SRT, Text, Font, Delete, Zoom)
  Widget _buildBottomCapCutBar() {
    return Container(
      height: 68,
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
            height: 46,
            margin: const EdgeInsets.only(left: 6, right: 2),
            decoration: BoxDecoration(
              color: const Color(0xFF222222),
              borderRadius: BorderRadius.circular(6),
            ),
            child: IconButton(
              padding: EdgeInsets.zero,
              icon: const Icon(Icons.chevron_left, color: Colors.white70),
              onPressed: _pickVideo,
              tooltip: 'ဗီဒီယို အသစ်ရွေးရန်',
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
                  icon: Icons.subtitles_outlined,
                  label: 'SRT ဖိုင်',
                  onTap: _importSrtFile,
                ),
                _buildToolItem(
                  icon: Icons.text_fields,
                  label: 'Text ရေးရန်',
                  onTap: () => _showAddOrEditTextSheet(),
                ),
                _buildToolItem(
                  icon: Icons.font_download_outlined,
                  label: 'Font ထည့်ရန်',
                  onTap: _importCustomFont,
                ),
                _buildToolItem(
                  icon: Icons.delete_outline,
                  label: 'Delete',
                  onTap: _deleteSelectedItem,
                ),
                _buildToolItem(
                  icon: Icons.zoom_in,
                  label: 'Zoom',
                  onTap: _showZoomSheet,
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
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 21),
            const SizedBox(height: 5),
            Text(
              label,
              style: const TextStyle(color: Colors.white70, fontSize: 10.5),
            ),
          ],
        ),
      ),
    );
  }

  // Video Preview ပေါ်တွင် လက်ရှိ Subtitle / Text နှင့် Custom Font ကို တိုက်ရိုက်ပြသပေးသော Overlay
  Widget _buildLiveSubtitleOverlay() {
    final activeSubs = _getActiveSubtitlesAt(_currentTimelinePosition());
    if (activeSubs.isEmpty) return const SizedBox.shrink();

    final combinedText = activeSubs.map((e) => e.text).join('\n');
    final fontFam = _selectedFont == 'Default' ? null : _selectedFont;

    return Positioned.fill(
      child: Align(
        alignment: Alignment(0.0, (_verticalPosRatio * 2.0) - 1.0),
        child: GestureDetector(
          onTap: () {
            final idx = _subtitles.indexOf(activeSubs.first);
            if (idx != -1) {
              _showAddOrEditTextSheet(editIndex: idx);
            }
          },
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            padding: _hasBackBox
                ? const EdgeInsets.symmetric(horizontal: 10, vertical: 5)
                : EdgeInsets.zero,
            decoration: _hasBackBox
                ? BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(6),
                  )
                : null,
            child: Stack(
              children: [
                // Outline Stroke
                Text(
                  combinedText,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: fontFam,
                    fontSize: _fontSize,
                    fontWeight: FontWeight.w700,
                    height: 1.3,
                    foreground: Paint()
                      ..style = PaintingStyle.stroke
                      ..strokeWidth = 3.0
                      ..color = _strokeColor,
                  ),
                ),
                // Main Fill
                Text(
                  combinedText,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: fontFam,
                    fontSize: _fontSize,
                    fontWeight: FontWeight.w700,
                    height: 1.3,
                    color: _textColor,
                  ),
                ),
              ],
            ),
          ),
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
                  'Lossless • Font: $_selectedFont',
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
                // 1. Video Preview + Live Subtitle/Text Overlay
                Expanded(
                  flex: 5,
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
                              _buildLiveSubtitleOverlay(),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),

                // 2. Play/Pause နှင့် Undo / Redo Control Bar
                Container(
                  height: 44,
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
                        iconSize: 30,
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
                          const SizedBox(width: 8),
                          IconButton(
                            icon: Icon(
                              Icons.undo,
                              color: _undoStack.isNotEmpty
                                  ? Colors.white
                                  : Colors.white24,
                              size: 21,
                            ),
                            onPressed: _undoStack.isNotEmpty ? _undo : null,
                            tooltip: 'Undo',
                          ),
                          IconButton(
                            icon: Icon(
                              Icons.redo,
                              color: _redoStack.isNotEmpty
                                  ? Colors.white
                                  : Colors.white24,
                              size: 21,
                            ),
                            onPressed: _redoStack.isNotEmpty ? _redo : null,
                            tooltip: 'Redo',
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                // 3. Multi-Track Timeline နှင့် Bottom Bar
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
