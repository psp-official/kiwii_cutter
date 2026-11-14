import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:video_player/video_player.dart';
import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';
import 'package:path_provider/path_provider.dart';
import 'package:gal/gal.dart';

void main() {
  runApp(const LosslessCutterApp());
}

class LosslessCutterApp extends StatelessWidget {
  const LosslessCutterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Lossless Video Cutter',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF121212),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00E676),
          secondary: Color(0xFF2979FF),
        ),
      ),
      home: const CutterHomePage(),
    );
  }
}

class VideoSegment {
  double start;
  double end;
  bool isDeleted;

  VideoSegment({
    required this.start,
    required this.end,
    this.isDeleted = false,
  });
}

class CutterHomePage extends StatefulWidget {
  const CutterHomePage({super.key});

  @override
  State<CutterHomePage> createState() => _CutterHomePageState();
}

class _CutterHomePageState extends State<CutterHomePage> {
  VideoPlayerController? _controller;
  final ScrollController _timelineScrollController = ScrollController();

  String? _videoPath;
  bool _isProcessing = false;
  bool _isUserScrolling = false;
  String _statusMessage = '';
  double _zoomLevel = 1.0;

  final List<String?> _thumbnails = [];
  final List<VideoSegment> _segments = [];
  int _selectedSegmentIndex = 0;

  static const int _thumbCount = 16;
  static const double _baseTimelineWidth = 960.0;

  double get _totalTimelineWidth => _baseTimelineWidth * _zoomLevel;

  @override
  void dispose() {
    _controller?.dispose();
    _timelineScrollController.dispose();
    super.dispose();
  }

  Future<void> _pickVideo() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.video);
    if (result != null && result.files.single.path != null) {
      final path = result.files.single.path!;
      await _controller?.dispose();

      final controller = VideoPlayerController.file(File(path));
      await controller.initialize();

      final maxDur = controller.value.duration.inMilliseconds / 1000.0;

      controller.addListener(_onVideoTick);

      setState(() {
        _videoPath = path;
        _controller = controller;
        _segments
          ..clear()
          ..add(VideoSegment(start: 0.0, end: maxDur));
        _selectedSegmentIndex = 0;
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
    if (!mounted || _controller == null) return;
    final posSec = _controller!.value.position.inMilliseconds / 1000.0;
    final maxDur = _controller!.value.duration.inMilliseconds / 1000.0;

    if (!_isUserScrolling &&
        _controller!.value.isPlaying &&
        _timelineScrollController.hasClients &&
        maxDur > 0) {
      final targetOffset =
          (posSec / maxDur).clamp(0.0, 1.0) * _totalTimelineWidth;
      _timelineScrollController.jumpTo(targetOffset);
    }

    // လက်ရှိ Playhead ရောက်နေသော Segment ကို အလိုအလျောက် ရွေးပေးရန်
    for (int i = 0; i < _segments.length; i++) {
      if (posSec >= _segments[i].start && posSec <= _segments[i].end) {
        _selectedSegmentIndex = i;
        break;
      }
    }

    setState(() {});
  }

  Future<void> _generateThumbnails(String videoPath, double maxDur) async {
    if (maxDur <= 0) return;
    final tempDir = await getTemporaryDirectory();
    final sessionStamp = DateTime.now().millisecondsSinceEpoch;

    for (int i = 0; i < _thumbCount; i++) {
      if (!mounted || _videoPath != videoPath) return;
      final timeSec = (maxDur / _thumbCount) * i;
      final outPath = '${tempDir.path}/thumb_${sessionStamp}_$i.jpg';

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

  void _seekToSeconds(double targetSec) {
    if (_controller == null) return;
    final maxDur = _controller!.value.duration.inMilliseconds / 1000.0;
    final clamped = targetSec.clamp(0.0, maxDur);
    _controller!.seekTo(Duration(milliseconds: (clamped * 1000).toInt()));
  }

  void _seekRelative(double offsetSeconds) {
    if (_controller == null) return;
    final currentSec = _controller!.value.position.inMilliseconds / 1000.0;
    final maxDur = _controller!.value.duration.inMilliseconds / 1000.0;
    final targetSec = (currentSec + offsetSeconds).clamp(0.0, maxDur);
    _seekToSeconds(targetSec);

    if (_timelineScrollController.hasClients && maxDur > 0) {
      _timelineScrollController
          .jumpTo((targetSec / maxDur) * _totalTimelineWidth);
    }
  }

  void _splitAtPlayhead() {
    if (_controller == null) return;
    final posSec = _controller!.value.position.inMilliseconds / 1000.0;

    for (int i = 0; i < _segments.length; i++) {
      final seg = _segments[i];
      if (posSec > seg.start + 0.25 && posSec < seg.end - 0.25) {
        setState(() {
          final firstPart = VideoSegment(
            start: seg.start,
            end: posSec,
            isDeleted: seg.isDeleted,
          );
          final secondPart = VideoSegment(
            start: posSec,
            end: seg.end,
            isDeleted: seg.isDeleted,
          );
          _segments[i] = firstPart;
          _segments.insert(i + 1, secondPart);
          _selectedSegmentIndex = i + 1;
        });
        return;
      }
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('ဖြတ်မည့်နေရာသည် အစ/အဆုံးနှင့် အနည်းဆုံး 0.25s ကွာရပါမည်'),
        duration: Duration(seconds: 1),
      ),
    );
  }

  void _toggleDeleteSelectedSegment() {
    if (_segments.isEmpty) return;
    setState(() {
      final seg = _segments[_selectedSegmentIndex];
      seg.isDeleted = !seg.isDeleted;
    });
  }

  void _resetSplits() {
    if (_controller == null) return;
    final maxDur = _controller!.value.duration.inMilliseconds / 1000.0;
    setState(() {
      _segments
        ..clear()
        ..add(VideoSegment(start: 0.0, end: maxDur));
      _selectedSegmentIndex = 0;
    });
  }

  String _formatBadgeTime(double sec) {
    final int mins = sec ~/ 60;
    final int secs = (sec % 60).floor();
    return '${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }

  String _formatPreciseTime(double sec) {
    final int mins = sec ~/ 60;
    final double rem = sec % 60;
    return '${mins.toString().padLeft(2, '0')}:${rem.toStringAsFixed(2).padLeft(5, '0')}';
  }

  Future<void> _exportClips({required bool merge}) async {
    final keptSegments = _segments.where((s) => !s.isDeleted).toList();
    if (_videoPath == null || keptSegments.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ထုတ်ယူရန် ချန်ထားသော အပိုင်း မရှိပါ')),
      );
      return;
    }

    setState(() {
      _isProcessing = true;
      _statusMessage = '⏳ Lossless (-c copy) စနစ်ဖြင့် ဖြတ်ထုတ်နေပါသည်...';
    });

    try {
      final tempDir = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final List<String> tempOutputs = [];

      for (int i = 0; i < keptSegments.length; i++) {
        final clip = keptSegments[i];
        final duration = (clip.end - clip.start).toStringAsFixed(2);
        final outPath = '${tempDir.path}/cut_${timestamp}_${i + 1}.mp4';

        final cmd =
            '-y -ss ${clip.start.toStringAsFixed(2)} -i "$_videoPath" -t $duration -c copy -avoid_negative_ts make_zero "$outPath"';

        final session = await FFmpegKit.execute(cmd);
        final returnCode = await session.getReturnCode();

        if (!ReturnCode.isSuccess(returnCode)) {
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
        final returnCode = await session.getReturnCode();
        if (!ReturnCode.isSuccess(returnCode)) {
          throw Exception('ဗီဒီယို ပြန်ဆက်ရာတွင် အမှားဖြစ်ပေါ်ပါသည်');
        }

        await Gal.putVideo(mergedPath, album: 'LosslessCuts');
        final sizeMb = (await File(mergedPath).length()) / (1024 * 1024);
        setState(() {
          _statusMessage =
              '✅ ချန်ထားသော (${keptSegments.length}) ပိုင်းကို ပေါင်းပြီး Gallery (LosslessCuts) ထဲသို့ သိမ်းပြီးပါပြီ!\nFile Size: ${sizeMb.toStringAsFixed(2)} MB';
        });
      } else {
        double totalMb = 0;
        for (final path in tempOutputs) {
          await Gal.putVideo(path, album: 'LosslessCuts');
          totalMb += (await File(path).length()) / (1024 * 1024);
        }
        setState(() {
          _statusMessage =
              '✅ ဗီဒီယို (${tempOutputs.length}) ဖိုင်ကို Gallery (LosslessCuts) ထဲသို့ သိမ်းပြီးပါပြီ!\nစုစုပေါင်း File Size: ${totalMb.toStringAsFixed(2)} MB';
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

  Widget _buildCapCutTimeline(double maxDur, double currentPos) {
    final screenWidth = MediaQuery.of(context).size.width;
    final halfScreen = screenWidth / 2;

    return SizedBox(
      height: 118,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // အနောက်ခံ Scrollable Filmstrip Timeline
          NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification is ScrollStartNotification &&
                  notification.dragDetails != null) {
                _isUserScrolling = true;
                if (_controller!.value.isPlaying) {
                  _controller!.pause();
                }
              } else if (notification is ScrollUpdateNotification &&
                  _isUserScrolling &&
                  maxDur > 0) {
                final ratio = (_timelineScrollController.offset /
                        _totalTimelineWidth)
                    .clamp(0.0, 1.0);
                _seekToSeconds(ratio * maxDur);
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
                padding: EdgeInsets.symmetric(horizontal: halfScreen),
                child: Row(
                  children: [
                    SizedBox(
                      width: _totalTimelineWidth,
                      height: 82,
                      child: Stack(
                        children: [
                          // 1. ဗီဒီယို Frame Thumbnail အတန်း
                          ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: Row(
                              children: List.generate(_thumbCount, (idx) {
                                final thumbPath = idx < _thumbnails.length
                                    ? _thumbnails[idx]
                                    : null;
                                return Expanded(
                                  child: Container(
                                    height: 82,
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF262626),
                                      border: Border(
                                        right: BorderSide(
                                          color: Colors.black.withAlpha(80),
                                          width: 0.5,
                                        ),
                                      ),
                                    ),
                                    child: thumbPath != null
                                        ? Image.file(
                                            File(thumbPath),
                                            fit: BoxFit.cover,
                                          )
                                        : const Center(
                                            child: SizedBox(
                                              width: 14,
                                              height: 14,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 1.5,
                                              ),
                                            ),
                                          ),
                                  ),
                                );
                              }),
                            ),
                          ),

                          // 2. Split လုပ်ထားသော အပိုင်းများ (Segments Overlay)
                          Row(
                            children: _segments.asMap().entries.map((entry) {
                              final idx = entry.key;
                              final seg = entry.value;
                              final segRatio = maxDur > 0
                                  ? ((seg.end - seg.start) / maxDur)
                                      .clamp(0.0, 1.0)
                                  : 1.0;
                              final segWidth = segRatio * _totalTimelineWidth;
                              final isSelected = idx == _selectedSegmentIndex;

                              return GestureDetector(
                                onTap: () {
                                  setState(() {
                                    _selectedSegmentIndex = idx;
                                  });
                                },
                                child: Container(
                                  width: segWidth,
                                  height: 82,
                                  decoration: BoxDecoration(
                                    color: seg.isDeleted
                                        ? const Color(0xAAB71C1C)
                                        : Colors.transparent,
                                    border: Border(
                                      left: BorderSide(
                                        color: isSelected
                                            ? Colors.white
                                            : const Color(0xFF121212),
                                        width: isSelected ? 2.5 : 2.0,
                                      ),
                                      right: BorderSide(
                                        color: isSelected
                                            ? Colors.white
                                            : const Color(0xFF121212),
                                        width: isSelected ? 2.5 : 2.0,
                                      ),
                                      top: BorderSide(
                                        color: isSelected
                                            ? Colors.white
                                            : Colors.transparent,
                                        width: 2.0,
                                      ),
                                      bottom: BorderSide(
                                        color: isSelected
                                            ? Colors.white
                                            : Colors.transparent,
                                        width: 2.0,
                                      ),
                                    ),
                                  ),
                                  child: Stack(
                                    children: [
                                      if (idx == 0)
                                        Positioned(
                                          top: 5,
                                          left: 6,
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 6,
                                              vertical: 2,
                                            ),
                                            decoration: BoxDecoration(
                                              color: const Color(0x99000000),
                                              borderRadius:
                                                  BorderRadius.circular(4),
                                            ),
                                            child: Text(
                                              _formatBadgeTime(maxDur),
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 12,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ),
                                        ),
                                      if (seg.isDeleted)
                                        const Center(
                                          child: Icon(
                                            Icons.delete_forever,
                                            color: Colors.white,
                                            size: 26,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                        ],
                      ),
                    ),

                    // 3. ညာဘက်အစွန်မှ "+" ခလုတ်
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: _pickVideo,
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(
                          Icons.add,
                          color: Colors.black87,
                          size: 28,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // အလယ်ဗဟိုရှိ အဖြူရောင် ဒေါင်လိုက် Playhead မျဉ်းကြောင်း
          IgnorePointer(
            child: Container(
              width: 3,
              height: 112,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(2),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black54,
                    blurRadius: 4,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final currentPos = _controller != null
        ? _controller!.value.position.inMilliseconds / 1000.0
        : 0.0;
    final maxDur = _controller != null
        ? _controller!.value.duration.inMilliseconds / 1000.0
        : 1.0;

    final selectedSeg =
        _segments.isNotEmpty && _selectedSegmentIndex < _segments.length
            ? _segments[_selectedSegmentIndex]
            : null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('⚡ Lossless Split Cutter'),
        backgroundColor: const Color(0xFF1E1E1E),
        actions: [
          if (_controller != null)
            TextButton.icon(
              onPressed: _resetSplits,
              icon: const Icon(Icons.refresh, color: Colors.orangeAccent),
              label: const Text(
                'Reset',
                style: TextStyle(color: Colors.orangeAccent),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.folder_open, color: Color(0xFF00E676)),
            onPressed: _pickVideo,
            tooltip: 'Video ရွေးရန်',
          ),
        ],
      ),
      body: _controller == null
          ? Center(
              child: ElevatedButton.icon(
                onPressed: _pickVideo,
                icon: const Icon(Icons.video_library),
                label: const Text('ဖုန်းထဲမှ Video ဖိုင်ရွေးမည်'),
                style: ElevatedButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                ),
              ),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Video Preview
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: AspectRatio(
                      aspectRatio: _controller!.value.aspectRatio,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: VideoPlayer(_controller!),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),

                  // Play/Pause + အချိန်ပြတန်း
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          _formatPreciseTime(currentPos),
                          style: const TextStyle(
                            color: Color(0xFF00E676),
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Row(
                          children: [
                            TextButton(
                              onPressed: () => _seekRelative(-0.5),
                              child: const Text('-0.5s'),
                            ),
                            IconButton(
                              iconSize: 38,
                              icon: Icon(
                                _controller!.value.isPlaying
                                    ? Icons.pause_circle_filled
                                    : Icons.play_circle_filled,
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
                            TextButton(
                              onPressed: () => _seekRelative(0.5),
                              child: const Text('+0.5s'),
                            ),
                          ],
                        ),
                        Text(
                          _formatPreciseTime(maxDur),
                          style: const TextStyle(color: Colors.grey),
                        ),
                      ],
                    ),
                  ),

                  // CapCut-style Filmstrip Timeline
                  Container(
                    color: const Color(0xFF181818),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: _buildCapCutTimeline(maxDur, currentPos),
                  ),

                  // Timeline Zoom Slider
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        const Icon(Icons.zoom_in, size: 18, color: Colors.grey),
                        const SizedBox(width: 8),
                        const Text(
                          'Timeline အကျယ်ချဲ့ရန်:',
                          style: TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                        Expanded(
                          child: Slider(
                            value: _zoomLevel,
                            min: 1.0,
                            max: 4.0,
                            onChanged: (val) {
                              final ratio = maxDur > 0
                                  ? (currentPos / maxDur).clamp(0.0, 1.0)
                                  : 0.0;
                              setState(() {
                                _zoomLevel = val;
                              });
                              WidgetsBinding.instance
                                  .addPostFrameCallback((_) {
                                if (_timelineScrollController.hasClients) {
                                  _timelineScrollController
                                      .jumpTo(ratio * _totalTimelineWidth);
                                }
                              });
                            },
                          ),
                        ),
                        Text(
                          '${_zoomLevel.toStringAsFixed(1)}x',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.grey,
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Split နှင့် Delete Toolbar (CapCut Bottom Action Bar ပုံစံ)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _splitAtPlayhead,
                            icon: const Icon(Icons.content_cut),
                            label: const Text('Split (ဖြတ်မည်)'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF2979FF),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: selectedSeg == null
                                ? null
                                : _toggleDeleteSelectedSegment,
                            icon: Icon(
                              selectedSeg?.isDeleted == true
                                  ? Icons.restore_from_trash
                                  : Icons.delete_outline,
                            ),
                            label: Text(
                              selectedSeg?.isDeleted == true
                                  ? 'ပြန်ယူမည် (Restore)'
                                  : 'ရွေးထားသောအပိုင်း ဖျက်မည်',
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: selectedSeg?.isDeleted == true
                                  ? Colors.orange.shade800
                                  : Colors.redAccent.shade700,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // ဖြတ်ထားသော အပိုင်းများ စာရင်း
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 6,
                    ),
                    child: Text(
                      'ဖြတ်ထားသော အပိုင်းများ (${_segments.where((s) => !s.isDeleted).length} / ${_segments.length} ပိုင်း ချန်ထားသည်):',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                  ),

                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _segments.asMap().entries.map((entry) {
                        final idx = entry.key;
                        final seg = entry.value;
                        final isSelected = idx == _selectedSegmentIndex;
                        final dur = (seg.end - seg.start).toStringAsFixed(1);

                        return ChoiceChip(
                          label: Text(
                            'အပိုင်း ${idx + 1} (${dur}s)${seg.isDeleted ? " [ဖျက်ထား]" : ""}',
                          ),
                          selected: isSelected,
                          selectedColor: seg.isDeleted
                              ? Colors.red.shade900
                              : const Color(0xFF00C853),
                          onSelected: (_) {
                            setState(() {
                              _selectedSegmentIndex = idx;
                            });
                            _seekToSeconds(seg.start + 0.05);
                            if (_timelineScrollController.hasClients &&
                                maxDur > 0) {
                              _timelineScrollController.jumpTo(
                                (seg.start / maxDur) * _totalTimelineWidth,
                              );
                            }
                          },
                        );
                      }).toList(),
                    ),
                  ),

                  const SizedBox(height: 16),

                  // Export ခလုတ် ၂ ခု
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _isProcessing
                                ? null
                                : () => _exportClips(merge: false),
                            icon: const Icon(Icons.file_download),
                            label: const Text('သီးခြားစီ ထုတ်မည်'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF00C853),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _isProcessing
                                ? null
                                : () => _exportClips(merge: true),
                            icon: const Icon(Icons.merge_type),
                            label: const Text('တစ်ဆက်တည်း ပေါင်းထုတ်မည်'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFAA00FF),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  if (_statusMessage.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF263238),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          _statusMessage,
                          style: const TextStyle(color: Color(0xFF80D8FF)),
                        ),
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}
