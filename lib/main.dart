import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:video_player/video_player.dart';
import 'package:ffmpeg_kit_flutter_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_min/return_code.dart';
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

class ClipSegment {
  final double start;
  final double end;
  final String label;

  ClipSegment({required this.start, required this.end, required this.label});
}

class CutterHomePage extends StatefulWidget {
  const CutterHomePage({super.key});

  @override
  State<CutterHomePage> createState() => _CutterHomePageState();
}

class _CutterHomePageState extends State<CutterHomePage> {
  VideoPlayerController? _controller;
  String? _videoPath;
  double _startSec = 0.0;
  double _endSec = 10.0;
  bool _isProcessing = false;
  String _statusMessage = '';
  final List<ClipSegment> _clips = [];

  Future<void> _pickVideo() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.video);
    if (result != null && result.files.single.path != null) {
      final path = result.files.single.path!;
      await _controller?.dispose();
      final controller = VideoPlayerController.file(File(path));
      await controller.initialize();
      controller.addListener(() {
        if (mounted) setState(() {});
      });

      setState(() {
        _videoPath = path;
        _controller = controller;
        _startSec = 0.0;
        _endSec = controller.value.duration.inMilliseconds / 1000.0;
        _clips.clear();
        _statusMessage = '';
      });
    }
  }

  void _seekRelative(double offsetSeconds) {
    if (_controller == null) return;
    final currentMs = _controller!.value.position.inMilliseconds;
    final maxMs = _controller!.value.duration.inMilliseconds;
    final targetMs = (currentMs + (offsetSeconds * 1000)).clamp(0, maxMs).toInt();
    _controller!.seekTo(Duration(milliseconds: targetMs));
  }

  void _setStart() {
    if (_controller == null) return;
    setState(() {
      _startSec = _controller!.value.position.inMilliseconds / 1000.0;
    });
  }

  void _setEnd() {
    if (_controller == null) return;
    setState(() {
      _endSec = _controller!.value.position.inMilliseconds / 1000.0;
    });
  }

  void _addClip() {
    if (_endSec <= _startSec) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('End Time သည် Start Time ထက် ကြီးရပါမည်')),
      );
      return;
    }
    setState(() {
      _clips.add(ClipSegment(
        start: double.parse(_startSec.toStringAsFixed(2)),
        end: double.parse(_endSec.toStringAsFixed(2)),
        label: 'Clip ${_clips.length + 1}',
      ));
    });
  }

  String _formatSec(double sec) {
    final int mins = sec ~/ 60;
    final double rem = sec % 60;
    return '${mins.toString().padLeft(2, '0')}:${rem.toStringAsFixed(2).padLeft(5, '0')}';
  }

  Future<void> _exportClips({required bool merge}) async {
    if (_videoPath == null || _clips.isEmpty) return;

    setState(() {
      _isProcessing = true;
      _statusMessage = '⏳ Lossless စနစ်ဖြင့် ဖြတ်ထုတ်နေပါသည်...';
    });

    try {
      final tempDir = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final List<String> tempOutputs = [];

      for (int i = 0; i < _clips.length; i++) {
        final clip = _clips[i];
        final duration = (clip.end - clip.start).toStringAsFixed(2);
        final outPath = '${tempDir.path}/cut_${timestamp}_${i + 1}.mp4';

        final cmd =
            '-y -ss ${clip.start} -i "$_videoPath" -t $duration -c copy -avoid_negative_ts make_zero "$outPath"';

        final session = await FFmpegKit.execute(cmd);
        final returnCode = await session.getReturnCode();

        if (!ReturnCode.isSuccess(returnCode)) {
          throw Exception('Clip ${i + 1} ဖြတ်ရာတွင် အမှားဖြစ်ပေါ်ပါသည်');
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
              '✅ ပေါင်းစည်းပြီး Gallery (LosslessCuts) ထဲသို့ သိမ်းပြီးပါပြီ!\nFile Size: ${sizeMb.toStringAsFixed(2)} MB';
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

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currentPos = _controller != null
        ? _controller!.value.position.inMilliseconds / 1000.0
        : 0.0;
    final maxDur = _controller != null
        ? _controller!.value.duration.inMilliseconds / 1000.0
        : 1.0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('⚡ Offline Lossless Cutter'),
        backgroundColor: const Color(0xFF1E1E1E),
        actions: [
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
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                ),
              ),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AspectRatio(
                    aspectRatio: _controller!.value.aspectRatio,
                    child: Stack(
                      alignment: Alignment.bottomCenter,
                      children: [
                        VideoPlayer(_controller!),
                        VideoProgressIndicator(_controller!, allowScrubbing: true),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),

                  // လက်ရှိအချိန် နှင့် Play/Pause + Fine Tune ခလုတ်များ
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      TextButton(onPressed: () => _seekRelative(-1.0), child: const Text('-1s')),
                      TextButton(onPressed: () => _seekRelative(-0.1), child: const Text('-0.1s')),
                      IconButton(
                        iconSize: 36,
                        icon: Icon(
                          _controller!.value.isPlaying ? Icons.pause_circle : Icons.play_circle,
                          color: const Color(0xFF00E676),
                        ),
                        onPressed: () {
                          setState(() {
                            _controller!.value.isPlaying
                                ? _controller!.pause()
                                : _controller!.play();
                          });
                        },
                      ),
                      TextButton(onPressed: () => _seekRelative(0.1), child: const Text('+0.1s')),
                      TextButton(onPressed: () => _seekRelative(1.0), child: const Text('+1s')),
                    ],
                  ),

                  Center(
                    child: Text(
                      'လက်ရှိနေရာ: ${_formatSec(currentPos)} / ${_formatSec(maxDur)}',
                      style: const TextStyle(color: Colors.grey),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Start / End သတ်မှတ်သည့် ခလုတ်များ
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _setStart,
                          child: Text('Start: ${_formatSec(_startSec)}'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _setEnd,
                          child: Text('End: ${_formatSec(_endSec)}'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: _addClip,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF2979FF),
                          foregroundColor: Colors.white,
                        ),
                        child: const Text('+ ထည့်မည်'),
                      ),
                    ],
                  ),
                  const Divider(height: 24),

                  // ဖြတ်မည့် Clip စာရင်း
                  const Text(
                    'ဖြတ်ထုတ်မည့် အပိုင်းများ (Clips Queue):',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                  const SizedBox(height: 8),
                  if (_clips.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(16.0),
                      child: Text(
                        'Start နှင့် End ရွေးပြီး "+ ထည့်မည်" ကို နှိပ်ပါ။',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey),
                      ),
                    )
                  else
                    ..._clips.asMap().entries.map((entry) {
                      final idx = entry.key;
                      final c = entry.value;
                      final dur = (c.end - c.start).toStringAsFixed(2);
                      return Card(
                        color: const Color(0xFF1E1E1E),
                        child: ListTile(
                          dense: true,
                          title: Text('${c.label}: ${_formatSec(c.start)} → ${_formatSec(c.end)}'),
                          subtitle: Text('ကြာချိန်: ${dur}s (Lossless Copy)'),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete, color: Colors.redAccent),
                            onPressed: () => setState(() => _clips.removeAt(idx)),
                          ),
                        ),
                      );
                    }),

                  const SizedBox(height: 12),

                  // Export ခလုတ် ၂ ခု
                  if (_clips.isNotEmpty)
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _isProcessing ? null : () => _exportClips(merge: false),
                            icon: const Icon(Icons.content_cut),
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
                            onPressed: _isProcessing ? null : () => _exportClips(merge: true),
                            icon: const Icon(Icons.merge_type),
                            label: const Text('ပေါင်းပြီး ထုတ်မည်'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFAA00FF),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                          ),
                        ),
                      ],
                    ),

                  if (_statusMessage.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Container(
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
                  ],
                ],
              ),
            ),
    );
  }
}
