import 'dart:io';
import 'package:flutter/material.dart';
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

class EditorSnapshot {
  final List<VideoSegment> segments;
  final int selectedIndex;

  EditorSnapshot({required this.segments, required this.selectedIndex});
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
  int _selectedIndex = 0;

  // Undo / Redo Stacks
  final List<EditorSnapshot> _undoStack = [];
  final List<EditorSnapshot> _redoStack = [];

  static const int _thumbCount = 18;
  double _pixelsPerSecond = 55.0; // Timeline အကျယ်

  double get _maxOriginalDuration => _controller != null
      ? _controller!.value.duration.inMilliseconds / 1000.0
      : 1.0;

  double get _totalActiveDuration =>
      _segments.fold(0.0, (sum, seg) => sum + seg.duration);

  double get _totalTimelineWidth =>
      (_totalActiveDuration * _pixelsPerSecond).clamp(280.0, 20000.0);

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
        selectedIndex: _selectedIndex,
      ),
    );
    final prev = _undoStack.removeLast();
    setState(() {
      _segments = prev.segments;
      _selectedIndex = prev.selectedIndex.clamp(0, _segments.length - 1);
    });
  }

  void _redo() {
    if (_redoStack.isEmpty) return;
    _undoStack.add(
      EditorSnapshot(
        segments: _segments.map((s) => s.copy()).toList(),
        selectedIndex: _selectedIndex,
      ),
    );
    final next = _redoStack.removeLast();
    setState(() {
      _segments = next.segments;
      _selectedIndex = next.selectedIndex.clamp(0, _segments.length - 1);
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

      // ဗီဒီယို အရှည်ပေါ်မူတည်၍ Timeline အကျယ်ကို အလိုအလျောက် ချိန်ညှိပေးရန်
      final autoPps = (900.0 / (maxDur > 0 ? maxDur : 10.0)).clamp(22.0, 90.0);

      controller.addListener(_onVideoTick);

      setState(() {
        _videoPath = path;
        _controller = controller;
        _pixelsPerSecond = autoPps;
        _isMuted = false;
        _segments = [VideoSegment(start: 0.0, end: maxDur)];
        _selectedIndex = 0;
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

  void _onVideoTick() {
    if (!mounted || _controller == null || _segments.isEmpty) return;
    final posSec = _controller!.value.position.inMilliseconds / 1000.0;

    if (_controller!.value.isPlaying && !_isUserScrolling) {
      // ဖျက်ထားသော အပိုင်းများကို ကျော်ပြီး ချန်ထားသော Segment များအတိုင်း Play ပေးရန်
      int foundIdx = -1;
      double accumulatedBefore = 0.0;

      for (int i = 0; i < _segments.length; i++) {
        final s = _segments[i];
        if (posSec >= s.start - 0.05 && posSec <= s.end + 0.05) {
          foundIdx = i;
          break;
        }
        accumulatedBefore += s.duration;
      }

      if (foundIdx != -1) {
        _selectedIndex = foundIdx;
        final seg = _segments[foundIdx];
        final activePos =
            accumulatedBefore + (posSec - seg.start).clamp(0.0, seg.duration);
        if (_timelineScrollController.hasClients && _totalActiveDuration > 0) {
          final targetOffset =
              (activePos / _totalActiveDuration) * _totalTimelineWidth;
          _timelineScrollController.jumpTo(targetOffset);
        }
      } else {
        // ဖျက်လိုက်သော အပိုင်းထဲ ရောက်သွားပါက နောက် Segment အစသို့ ချက်ချင်း ခုန်ကူးရန်
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

  // Timeline Offset မှ ဗီဒီယို၏ အချိန်အမှန်သို့ တွက်ချက်ပေးခြင်း
  double _offsetToVideoSeconds(double scrollOffset) {
    if (_segments.isEmpty || _totalTimelineWidth <= 0) return 0.0;
    final ratio = (scrollOffset / _totalTimelineWidth).clamp(0.0, 1.0);
    final targetActiveSec = ratio * _totalActiveDuration;

    double acc = 0.0;
    for (int i = 0; i < _segments.length; i++) {
      final seg = _segments[i];
      if (targetActiveSec <= acc + seg.duration || i == _segments.length - 1) {
        _selectedIndex = i;
        final localOffset = (targetActiveSec - acc).clamp(0.0, seg.duration);
        return seg.start + localOffset;
      }
      acc += seg.duration;
    }
    return _segments.last.end;
  }

  // လက်ရှိ Playhead ရောက်နေသော Timeline အချိန်
  double _currentTimelinePosition() {
    if (_controller == null || _segments.isEmpty) return 0.0;
    final posSec = _controller!.value.position.inMilliseconds / 1000.0;
    double acc = 0.0;
    for (final seg in _segments) {
      if (posSec >= seg.start && posSec <= seg.end) {
        return acc + (posSec - seg.start);
      }
      acc += seg.duration;
    }
    return acc.clamp(0.0, _totalActiveDuration);
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

  void _deleteSelectedSegment() {
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
    setState(() {
      _segments.removeAt(_selectedIndex);
      if (_selectedIndex >= _segments.length) {
        _selectedIndex = _segments.length - 1;
      }
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
              ? '🔇 ဗီဒီယိုအသံ ပိတ်ထားပါသည် (Export ထုတ်လျှင်လည်း အသံပါမည်မဟုတ်ပါ)'
              : '🔊 ဗီဒီယိုအသံ ပြန်ဖွင့်ထားပါသည်',
        ),
        duration: const Duration(milliseconds: 1000),
      ),
    );
  }

  void _showZoomAndSpeedSheet() {
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
                '⚡ Lossless Export (ဖိုင်ဆိုဒ် လုံးဝမတက်ပါ)',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              Text(
                'ကျန်ရှိသော အပိုင်း (${_segments.length}) ပိုင်း • စုစုပေါင်းကြာချိန် ${_formatClock(_totalActiveDuration)}',
                style: const TextStyle(color: Colors.grey, fontSize: 13),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: () {
                  Navigator.pop(ctx);
                  _exportClips(merge: true);
                },
                icon: const Icon(Icons.merge_type),
                label: const Text('တစ်ဆက်တည်း ပေါင်းထုတ်မည် (Cut & Merge)'),
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
                  _exportClips(merge: false);
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

  Future<void> _exportClips({required bool merge}) async {
    if (_videoPath == null || _segments.isEmpty) return;

    setState(() {
      _isProcessing = true;
      _statusMessage = '⏳ Lossless (-c copy) ဖြင့် ဖြတ်ထုတ်နေပါသည်...';
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

      if (merge && tempOutputs.length > 1) {
        final listFile = File('${tempDir.path}/concat_$timestamp.txt');
        final listContent = tempOutputs.map((p) => "file '$p'").join('\n');
        await listFile.writeAsString(listContent);

        final mergedPath = '${tempDir.path}/merged_$timestamp.mp4';
        final mergeCmd =
            '-y -f concat -safe 0 -i "${listFile.path}" -c copy "$mergedPath"';

        final session = await FFmpegKit.execute(mergeCmd);
        final rc = await session.getReturnCode();
        if (!ReturnCode.isSuccess(rc)) {
          throw Exception('ဗီဒီယို ပြန်ဆက်ရာတွင် အမှားဖြစ်ပေါ်ပါသည်');
        }

        await Gal.putVideo(mergedPath, album: 'LosslessCuts');
        final sizeMb = (await File(mergedPath).length()) / (1024 * 1024);
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

  // CapCut ပုံစံ Segment Thumbnail နှင့် အဖြူရောင် Handle ဘောင်များ
  Widget _buildSegmentBlock(int index, VideoSegment seg) {
    final double segWidth =
        (seg.duration * _pixelsPerSecond).clamp(38.0, 20000.0);
    final bool isSelected = index == _selectedIndex;
    final int tileCount = (segWidth / 54.0).ceil().clamp(1, 40);

    return GestureDetector(
      onTap: () {
        setState(() {
          _selectedIndex = index;
        });
      },
      child: Container(
        width: segWidth,
        height: 62,
        margin: const EdgeInsets.only(right: 2),
        child: Stack(
          children: [
            // Segment အတွင်းမှ ဗီဒီယို Frame များ
            ClipRRect(
              borderRadius: BorderRadius.circular(isSelected ? 5 : 3),
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

            // ရွေးထားသည့် Segment တွင် CapCut အတိုင်း အဖြူရောင် ဘယ်/ညာ Handle ပြသခြင်း
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
                      // ဘယ်ဘက် Handle အဖြူတုံး
                      Container(
                        width: 12,
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
                      // ညာဘက် Handle အဖြူတုံး
                      Container(
                        width: 12,
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

            // ကြာချိန်ပြသသော စာသား (ဥပမာ - "3.9s")
            Positioned(
              top: 4,
              left: isSelected ? 16 : 6,
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
                    fontSize: 10.5,
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

  // CapCut အလယ်ပိုင်း Multi-Track Timeline Area
  Widget _buildCapCutTimelineArea() {
    final screenWidth = MediaQuery.of(context).size.width;
    final halfScreen = screenWidth / 2;
    final totalSecs = _totalActiveDuration.ceil().clamp(1, 3600);

    return Expanded(
      child: Stack(
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
              child: Padding(
                padding: EdgeInsets.only(
                  left: halfScreen - 56,
                  right: halfScreen,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 1. အချိန်ပြ ပေတံတန်း (00:00 • 00:01 • 00:02)
                    Padding(
                      padding: const EdgeInsets.only(left: 56, bottom: 8),
                      child: SizedBox(
                        width: _totalTimelineWidth + 80,
                        height: 20,
                        child: Row(
                          children: List.generate(totalSecs + 1, (sec) {
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

                    // 2. Cover ခလုတ် + Video Filmstrip + ညာဘက် "+" ခလုတ်
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        // Cover ခလုတ်
                        Container(
                          width: 48,
                          height: 62,
                          margin: const EdgeInsets.only(right: 8),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1F1F1F),
                            borderRadius: BorderRadius.circular(6),
                            image: _thumbnails.isNotEmpty &&
                                    _thumbnails.first != null
                                ? DecorationImage(
                                    image: FileImage(File(_thumbnails.first!)),
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
                              Icon(Icons.edit_outlined,
                                  size: 16, color: Colors.white),
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

                        // Video Segments အတန်း
                        Row(
                          children: _segments
                              .asMap()
                              .entries
                              .map((e) => _buildSegmentBlock(e.key, e.value))
                              .toList(),
                        ),

                        // ညာဘက်အစွန် "+" ခလုတ်
                        const SizedBox(width: 8),
                        GestureDetector(
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
                      ],
                    ),

                    const SizedBox(height: 12),

                    // 3. "+ Add audio" Track Row
                    Row(
                      children: [
                        Container(
                          width: 40,
                          height: 36,
                          margin: const EdgeInsets.only(right: 16),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1C1C1C),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Icon(
                            _isMuted ? Icons.music_off : Icons.music_note,
                            size: 18,
                            color: _isMuted ? Colors.redAccent : Colors.white54,
                          ),
                        ),
                        GestureDetector(
                          onTap: _toggleMute,
                          child: Container(
                            width: _totalTimelineWidth,
                            height: 36,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
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
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 8),

                    // 4. "+ Add text" Track Row
                    Row(
                      children: [
                        Container(
                          width: 40,
                          height: 36,
                          margin: const EdgeInsets.only(right: 16),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1C1C1C),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Icon(
                            Icons.text_fields,
                            size: 18,
                            color: Colors.white54,
                          ),
                        ),
                        Container(
                          width: _totalTimelineWidth,
                          height: 36,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1C1C1C),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          alignment: Alignment.centerLeft,
                          child: const Text(
                            '+ Add text',
                            style: TextStyle(
                              color: Colors.white60,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),

          // ဘယ်ဘက်ထောင့်ရှိ လက်ရှိအချိန် / စုစုပေါင်းအချိန် ("00:02 / 01:06")
          Positioned(
            top: 0,
            left: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
            top: 22,
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
      ),
    );
  }

  // အောက်ဆုံး CapCut Toolbar (Split, Volume, Animations, Effects, Delete, Speed)
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
          // ဘယ်ဘက်အစွန် "<" ခလုတ်
          Container(
            width: 38,
            height: 46,
            margin: const EdgeInsets.only(left: 8, right: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF222222),
              borderRadius: BorderRadius.circular(6),
            ),
            child: IconButton(
              icon: const Icon(Icons.chevron_left, color: Colors.white70),
              onPressed: _pickVideo,
              tooltip: 'ဗီဒီယို အသစ်ရွေးရန်',
            ),
          ),

          // အဓိက Tool ခလုတ်များ
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
                  icon: Icons.slideshow_outlined,
                  label: 'Animations',
                  onTap: _showZoomAndSpeedSheet,
                ),
                _buildToolItem(
                  icon: Icons.auto_awesome_outlined,
                  label: 'Effects',
                  onTap: _showZoomAndSpeedSheet,
                ),
                _buildToolItem(
                  icon: Icons.delete_outline,
                  label: 'Delete',
                  onTap: _deleteSelectedSegment,
                ),
                _buildToolItem(
                  icon: Icons.speed,
                  label: 'Speed',
                  onTap: _showZoomAndSpeedSheet,
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
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 22),
            const SizedBox(height: 5),
            Text(
              label,
              style: const TextStyle(color: Colors.white70, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // အပေါ်ဆုံး CapCut Top Bar + Export ခလုတ်
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
              : const Text(
                  'Lossless 1080P',
                  style: TextStyle(fontSize: 13, color: Colors.white70),
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
                // 1. အပေါ်ပိုင်း Video Preview Area (Cyan ဘောင်နှင့်တကွ)
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
                          child: VideoPlayer(_controller!),
                        ),
                      ),
                    ),
                  ),
                ),

                // 2. အလယ်ပိုင်း Play/Pause နှင့် Undo / Redo Control Bar
                Container(
                  height: 46,
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
                            tooltip: 'Undo (နောက်ပြန်ဆုတ်ရန်)',
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
                            tooltip: 'Redo (ရှေ့ပြန်တိုးရန်)',
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                // 3. အောက်ပိုင်း CapCut Multi-Track Timeline
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
