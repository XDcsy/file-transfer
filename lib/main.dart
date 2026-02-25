import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';

import 'src/visual_frame_codec.dart';
import 'src/frame_archive.dart';
import 'src/mjpeg_parser.dart';
import 'src/visual_protocol.dart';

void main() {
  runApp(const CaptureVisionApp());
}

class CaptureVisionApp extends StatelessWidget {
  const CaptureVisionApp({super.key});

  @override
  Widget build(BuildContext context) {
    const Color seed = Color(0xFF0F766E);
    final ThemeData base = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: seed,
        brightness: Brightness.light,
      ),
      fontFamily: 'Segoe UI',
    );
    return MaterialApp(
      title: 'Capture Vision Transfer',
      debugShowCheckedModeBanner: false,
      theme: base.copyWith(
        scaffoldBackgroundColor: const Color(0xFFF3F5F7),
        cardTheme: const CardThemeData(
          elevation: 1.5,
          margin: EdgeInsets.zero,
          color: Colors.white,
        ),
      ),
      home: const WorkbenchPage(),
    );
  }
}

class WorkbenchPage extends StatefulWidget {
  const WorkbenchPage({super.key});

  @override
  State<WorkbenchPage> createState() => _WorkbenchPageState();
}

class _WorkbenchPageState extends State<WorkbenchPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Capture Vision Transfer'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const <Tab>[
            Tab(icon: Icon(Icons.send), text: '发送端'),
            Tab(icon: Icon(Icons.download), text: '接收端'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: const <Widget>[SenderPanel(), ReceiverPanel()],
      ),
    );
  }
}

enum _SenderDisplayPreset { immersive, floating }

class SenderPanel extends StatefulWidget {
  const SenderPanel({super.key});

  @override
  State<SenderPanel> createState() => _SenderPanelState();
}

class _SenderPanelState extends State<SenderPanel> {
  final TextEditingController _filePathController = TextEditingController();
  final TextEditingController _fpsController = TextEditingController(
    text: '12',
  );
  final TextEditingController _repeatController = TextEditingController(
    text: '1',
  );

  TransferSession? _session;
  Timer? _timer;
  Uint8List _currentFrame = Uint8List(VisualProtocol.frameBytes);
  String _subtitle = '等待开始';
  _SenderDisplayPreset _displayPreset = _SenderDisplayPreset.immersive;
  SenderVisualStyle _visualStyle = SenderVisualStyle.reliableMono;
  SenderVisualLayout _visualLayout = SenderVisualLayout.centered;
  double _visualWidthFraction = 0.97;
  int _scheduleIndex = 0;
  int _sentFrames = 0;
  DateTime? _startedAt;
  String _message = '';
  bool _running = false;

  @override
  void dispose() {
    _stopSending();
    _filePathController.dispose();
    _fpsController.dispose();
    _repeatController.dispose();
    super.dispose();
  }

  Future<void> _browseInputFile() async {
    try {
      final XFile? picked = await openFile();
      if (picked != null) {
        setState(() {
          _filePathController.text = picked.path;
          _message = '';
        });
      }
    } catch (e) {
      setState(() {
        _message = '打开文件选择器失败: $e';
      });
    }
  }

  void _applyDisplayPreset(_SenderDisplayPreset preset) {
    _displayPreset = preset;
    if (preset == _SenderDisplayPreset.immersive) {
      _visualStyle = SenderVisualStyle.reliableMono;
      _visualLayout = SenderVisualLayout.centered;
      _visualWidthFraction = 0.97;
    } else {
      _visualStyle = SenderVisualStyle.reliableMonoSoft;
      _visualLayout = SenderVisualLayout.lowerRight;
      _visualWidthFraction = 0.42;
    }
  }

  Future<void> _startSending() async {
    final String path = _filePathController.text.trim();
    if (path.isEmpty) {
      setState(() {
        _message = '请先输入待发送文件路径。';
      });
      return;
    }
    final File file = File(path);
    if (!await file.exists()) {
      setState(() {
        _message = '文件不存在: $path';
      });
      return;
    }

    final int fps = int.tryParse(_fpsController.text.trim()) ?? 12;
    final int repeat = int.tryParse(_repeatController.text.trim()) ?? 1;
    if (fps < 3 || fps > 30) {
      setState(() {
        _message = '发送帧率建议 3-30。';
      });
      return;
    }
    if (repeat < 1 || repeat > 4) {
      setState(() {
        _message = '重发系数建议 1-4。';
      });
      return;
    }

    final Uint8List bytes = await file.readAsBytes();
    final String fileName = file.uri.pathSegments.isEmpty
        ? 'payload.bin'
        : file.uri.pathSegments.last;
    final TransferSession session = VisualTransferEncoder.buildSession(
      fileName: fileName,
      fileBytes: bytes,
      repeatCount: repeat,
    );

    _timer?.cancel();
    _scheduleIndex = 0;
    _sentFrames = 0;
    _startedAt = DateTime.now();
    _running = true;
    _session = session;
    _message = '已启动发送。建议接收端至少录制 ${session.recommendedCaptureFrames} 帧后再离线解析。';

    _pushNextFrame();
    _timer = Timer.periodic(
      Duration(milliseconds: (1000 / fps).round()),
      (_) => _pushNextFrame(),
    );

    setState(() {});
  }

  void _pushNextFrame() {
    final TransferSession? session = _session;
    if (!_running || session == null || session.schedule.isEmpty) {
      return;
    }
    final VisualPacket packet =
        session.schedule[_scheduleIndex % session.schedule.length];
    _currentFrame = packet.toFrameBytes();
    _subtitle = '';
    _scheduleIndex++;
    _sentFrames++;
    setState(() {});
  }

  void _stopSending() {
    _timer?.cancel();
    _timer = null;
    if (_running) {
      setState(() {
        _running = false;
        _message = '发送已停止。';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final TransferSession? session = _session;
    final double fps = double.tryParse(_fpsController.text.trim()) ?? 12;
    final double throughput = session == null
        ? 0
        : session.estimatedPayloadThroughputBytesPerSecond(fps: fps);

    final Duration elapsed = _startedAt == null
        ? Duration.zero
        : DateTime.now().difference(_startedAt!);
    final int elapsedMs = elapsed.inMilliseconds;
    final double frameRateActual = elapsedMs <= 0
        ? 0
        : (_sentFrames * 1000.0 / elapsedMs);

    if (_running) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: <Widget>[
            Expanded(child: _buildFramePreview(double.infinity)),
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _stopSending,
                    icon: const Icon(Icons.stop),
                    label: const Text('停止发送'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '已发送 $_sentFrames 帧，当前 ${frameRateActual.toStringAsFixed(2)} fps',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _displayPreset == _SenderDisplayPreset.immersive
                    ? '发送中建议：将该窗口最大化并置于采集输出屏。'
                    : '发送中建议：可保留悬浮模式，接收端会在离线解析阶段全量重扫。',
                style: const TextStyle(
                  color: Color(0xFF475569),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(16),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool narrow = constraints.maxWidth < 1120;
          if (narrow) {
            return ListView(
              children: <Widget>[
                _buildSenderControls(throughput, frameRateActual),
                const SizedBox(height: 12),
                _buildFramePreview(420),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SizedBox(
                width: 390,
                child: _buildSenderControls(throughput, frameRateActual),
              ),
              const SizedBox(width: 12),
              Expanded(child: _buildFramePreview(double.infinity)),
            ],
          );
        },
      ),
    );
  }

  Widget _buildSenderControls(double throughput, double frameRateActual) {
    final TransferSession? session = _session;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              '发送参数',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _filePathController,
              decoration: InputDecoration(
                labelText: '待发送文件路径',
                suffixIcon: IconButton(
                  onPressed: _running ? null : _browseInputFile,
                  icon: const Icon(Icons.folder_open),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _fpsController,
                    enabled: !_running,
                    decoration: const InputDecoration(
                      labelText: '发送帧率 FPS (3-30)',
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _repeatController,
                    enabled: !_running,
                    decoration: const InputDecoration(labelText: '重发系数 (1-4)'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<_SenderDisplayPreset>(
              initialValue: _displayPreset,
              decoration: const InputDecoration(labelText: '显示模式'),
              items: const <DropdownMenuItem<_SenderDisplayPreset>>[
                DropdownMenuItem<_SenderDisplayPreset>(
                  value: _SenderDisplayPreset.immersive,
                  child: Text('全屏高可靠'),
                ),
                DropdownMenuItem<_SenderDisplayPreset>(
                  value: _SenderDisplayPreset.floating,
                  child: Text('低打扰悬浮'),
                ),
              ],
              onChanged: _running
                  ? null
                  : (_SenderDisplayPreset? value) {
                      if (value == null) {
                        return;
                      }
                      setState(() {
                        _applyDisplayPreset(value);
                      });
                    },
            ),
            const SizedBox(height: 6),
            Text('码图宽度占屏: ${(_visualWidthFraction * 100).toStringAsFixed(0)}%'),
            Slider(
              value: _visualWidthFraction.clamp(0.22, 0.98),
              min: 0.22,
              max: 0.98,
              divisions: 38,
              onChanged: _running
                  ? null
                  : (double value) {
                      setState(() {
                        _visualWidthFraction = value;
                      });
                    },
            ),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _running ? null : _startSending,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('开始发送'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _running ? _stopSending : null,
                    icon: const Icon(Icons.stop),
                    label: const Text('停止'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            _kv('状态', _running ? '发送中' : '空闲'),
            _kv('文件名', session?.fileName ?? '-'),
            _kv(
              '文件大小',
              session == null ? '-' : _formatBytes(session.fileBytes.length),
            ),
            _kv('数据分片数', session == null ? '-' : '${session.totalDataChunks}'),
            _kv('每轮帧数', session == null ? '-' : '${session.packetsPerLoop}'),
            _kv(
              '建议录制帧',
              session == null ? '-' : '${session.recommendedCaptureFrames}',
            ),
            _kv('编码速率估算', '${_formatBytes(throughput.round())}/s'),
            _kv(
              '实际渲染帧率',
              frameRateActual == 0
                  ? '-'
                  : '${frameRateActual.toStringAsFixed(2)} fps',
            ),
            const SizedBox(height: 10),
            Text(
              _message,
              style: TextStyle(
                color: _running
                    ? const Color(0xFF0F766E)
                    : const Color(0xFF475569),
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFramePreview(double height) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height: height == double.infinity ? null : height,
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: CustomPaint(
            painter: VisualFramePainter(
              frameBytes: _currentFrame,
              subtitle: _subtitle,
              style: _visualStyle,
              layout: _visualLayout,
              widthFraction: _visualWidthFraction,
            ),
          ),
        ),
      ),
    );
  }
}

class ReceiverPanel extends StatefulWidget {
  const ReceiverPanel({super.key});

  @override
  State<ReceiverPanel> createState() => _ReceiverPanelState();
}

class _ReceiverPanelState extends State<ReceiverPanel> {
  late final TextEditingController _ffmpegController;
  final TextEditingController _deviceController = TextEditingController();
  final TextEditingController _captureSizeController = TextEditingController(
    text: '1280x720',
  );
  final TextEditingController _captureFpsController = TextEditingController(
    text: '30',
  );
  final TextEditingController _decodeFpsController = TextEditingController(
    text: '12',
  );
  final TextEditingController _outputDirController = TextEditingController();

  Process? _captureProcess;
  StreamSubscription<List<int>>? _captureStdoutSub;
  StreamSubscription<List<int>>? _captureStderrSub;
  late final MjpegFrameParser _mjpegParser;
  FrameArchiveWriter? _archiveWriter;
  File? _archiveFile;
  String _archiveFilePath = '-';
  bool _captureStopRequested = false;
  bool _manifestProbeBusy = false;
  bool _running = false;
  bool _capturing = false;
  bool _analyzing = false;
  int _consecutiveMisses = 0;
  final int _globalRescanThreshold = 8;
  DateTime? _startedAt;
  int _inputFrames = 0;
  int _probeAttempts = 0;
  int _probeHits = 0;
  int _archiveWriteErrors = 0;
  int _targetCaptureFrames = 0;
  int _packetsPerLoopHint = 0;
  final List<int> _decodeCostsMs = <int>[];

  TransferAssembler? _assembler;
  TransferManifest? _manifest;
  int? _activeTransferId;
  int _totalDataChunks = 0;
  int _decodedFrames = 0;
  int _validFrames = 0;
  int _invalidFrames = 0;
  String _status = '空闲';
  String _lastPacketInfo = '-';
  String _savedFilePath = '';
  String _runtimeLogDirPath = '-';
  Uint8List? _latestCaptureBytes;
  DateTime? _latestCaptureAt;
  int? _latestCaptureWidth;
  int? _latestCaptureHeight;
  Rect? _lastDetectedNormalizedRect;
  final List<_DshowDeviceEntry> _videoDevices = <_DshowDeviceEntry>[];
  String? _selectedVideoDeviceName;
  bool _scanningDevices = false;
  bool _manualRegionEnabled = false;
  double _manualCenterX = 0.5;
  double _manualCenterY = 0.5;
  double _manualWidthFraction = 0.40;
  Directory? _runtimeSessionDir;
  File? _runtimeIndexFile;
  int _runtimeFrameIndex = 0;

  @override
  void initState() {
    super.initState();
    _ffmpegController = TextEditingController(text: _defaultFfmpegPath());
    _mjpegParser = MjpegFrameParser(onFrame: _onMjpegFrame);
    _outputDirController.text = Directory.current.path;
    Future<void>.delayed(
      const Duration(milliseconds: 220),
      () => _scanDevices(silent: true),
    );
  }

  @override
  void dispose() {
    unawaited(_stopReceiver(analyzeAfterStop: false));
    _ffmpegController.dispose();
    _deviceController.dispose();
    _captureSizeController.dispose();
    _captureFpsController.dispose();
    _decodeFpsController.dispose();
    _outputDirController.dispose();
    super.dispose();
  }

  Future<void> _scanDevices({bool silent = false}) async {
    if (_scanningDevices) {
      return;
    }
    final String ffmpegPath = _ffmpegController.text.trim();
    if (ffmpegPath.isEmpty) {
      if (!silent) {
        setState(() {
          _status = '请先填写 ffmpeg 路径。';
        });
      }
      return;
    }
    _scanningDevices = true;
    if (!silent) {
      setState(() {
        _status = '正在扫描 dshow 设备...';
      });
    }
    try {
      final _DshowScanResult scanResult = await _scanDshowDevices(ffmpegPath);
      final _DshowDeviceEntry? guessed = _guessBestCaptureVideoDevice(
        scanResult.videoDevices,
        scanResult.audioDevices,
      );
      setState(() {
        _videoDevices
          ..clear()
          ..addAll(scanResult.videoDevices);
        if (scanResult.videoDevices.isEmpty) {
          _selectedVideoDeviceName = null;
          _deviceController.clear();
          if (!silent) {
            _status = '未解析到采集设备，请确认系统识别到了采集卡。';
          }
        } else if (guessed != null) {
          _selectedVideoDeviceName = guessed.name;
          _deviceController.text = guessed.name;
          _status =
              '扫描到 ${scanResult.videoDevices.length} 个视频设备，已自动选择：${guessed.name}';
        } else {
          final String current = _selectedVideoDeviceName ?? '';
          final bool stillExists = scanResult.videoDevices.any(
            (_DshowDeviceEntry e) => e.name == current,
          );
          _selectedVideoDeviceName = stillExists
              ? current
              : scanResult.videoDevices.first.name;
          if (_selectedVideoDeviceName == null) {
            _deviceController.clear();
          } else {
            _deviceController.text = _selectedVideoDeviceName!;
          }
          if (!silent) {
            _status =
                '扫描到 ${scanResult.videoDevices.length} 个视频设备，但未识别出采集卡，请手动填写。';
          }
        }
      });
      await _appendRuntimeLog(
        'scan devices: ${scanResult.videoDevices.length} video, ${scanResult.audioDevices.length} audio; selected=${_selectedVideoDeviceName ?? 'none'}',
      );
    } catch (e) {
      setState(() {
        if (!silent) {
          _status = '扫描设备失败: $e';
        }
      });
    } finally {
      _scanningDevices = false;
    }
  }

  Future<_DshowScanResult> _scanDshowDevices(String ffmpegPath) async {
    final String merged = await _runProcessCaptureMergedOutput(
      ffmpegPath,
      <String>[
        '-hide_banner',
        '-list_devices',
        'true',
        '-f',
        'dshow',
        '-i',
        'dummy',
      ],
    );
    return _parseDshowScanResult(merged);
  }

  Future<void> _pickOutputDir() async {
    try {
      final String? selected = await getDirectoryPath();
      if (selected != null && selected.isNotEmpty) {
        setState(() {
          _outputDirController.text = selected;
        });
      }
    } catch (e) {
      setState(() {
        _status = '打开目录选择器失败: $e';
      });
    }
  }

  void _selectDeviceFromDropdown(String? value) {
    if (value == null) {
      return;
    }
    setState(() {
      _selectedVideoDeviceName = value;
      _deviceController.text = value;
      _status = '已选择设备：$value';
    });
    _appendRuntimeLog('manual select device: $value');
  }

  Rect _manualNormalizedRect() {
    final double imageAspect =
        (_latestCaptureWidth != null && _latestCaptureHeight != null)
        ? (_latestCaptureWidth! / _latestCaptureHeight!)
        : (16 / 9);
    final double targetAspect =
        VisualProtocol.gridCols / VisualProtocol.gridRows;
    final double w = _manualWidthFraction.clamp(0.08, 0.95);
    double h = (w * imageAspect / targetAspect).clamp(0.08, 0.95);
    if (h > 0.95) {
      h = 0.95;
    }
    final double left = (_manualCenterX - w / 2).clamp(0.0, 1.0 - w);
    final double top = (_manualCenterY - h / 2).clamp(0.0, 1.0 - h);
    return Rect.fromLTWH(left, top, w, h);
  }

  Future<void> _startRuntimeLogSession() async {
    final String ts = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    final Directory root = Directory(
      '${Directory.current.path}${Platform.pathSeparator}runtime_logs',
    );
    if (!await root.exists()) {
      await root.create(recursive: true);
    }
    final Directory session = Directory(
      '${root.path}${Platform.pathSeparator}session_$ts',
    );
    if (!await session.exists()) {
      await session.create(recursive: true);
    }
    final File index = File(
      '${session.path}${Platform.pathSeparator}index.log',
    );
    await index.writeAsString(
      'session start: ${DateTime.now().toIso8601String()}\n',
      mode: FileMode.write,
      flush: true,
    );
    _runtimeSessionDir = session;
    _runtimeIndexFile = index;
    _runtimeFrameIndex = 0;
    _runtimeLogDirPath = session.path;
  }

  Future<void> _appendRuntimeLog(String text) async {
    final File? index = _runtimeIndexFile;
    if (index == null) {
      return;
    }
    final String line = '${DateTime.now().toIso8601String()} | $text\n';
    try {
      await index.writeAsString(line, mode: FileMode.append, flush: true);
    } catch (_) {
      // ignore logging failures
    }
  }

  bool _shouldPersistFrame(int index) {
    if (index <= 300) {
      return true;
    }
    return index % 10 == 0;
  }

  Future<void> _persistRuntimeFrame({
    required Uint8List bytes,
    required bool valid,
    Rect? normalizedRect,
  }) async {
    final Directory? dir = _runtimeSessionDir;
    if (dir == null) {
      return;
    }
    _runtimeFrameIndex++;
    if (!_shouldPersistFrame(_runtimeFrameIndex)) {
      return;
    }
    final String flag = valid ? 'valid' : 'invalid';
    final String fileName =
        '${_runtimeFrameIndex.toString().padLeft(6, '0')}_$flag.jpg';
    final File out = File('${dir.path}${Platform.pathSeparator}$fileName');
    try {
      await out.writeAsBytes(bytes, flush: false);
      final String rectText = normalizedRect == null
          ? 'none'
          : '${normalizedRect.left.toStringAsFixed(4)},${normalizedRect.top.toStringAsFixed(4)},${normalizedRect.width.toStringAsFixed(4)},${normalizedRect.height.toStringAsFixed(4)}';
      await _appendRuntimeLog(
        'frame=$_runtimeFrameIndex $flag saved=$fileName rect=$rectText',
      );
    } catch (_) {
      // ignore logging failures
    }
  }

  Future<void> _startReceiver() async {
    if (_running) {
      return;
    }
    final String ffmpegPath = _ffmpegController.text.trim();
    final String device = _deviceController.text.trim().isNotEmpty
        ? _deviceController.text.trim()
        : (_selectedVideoDeviceName ?? '');
    final String captureSize = _captureSizeController.text.trim();
    final int captureFps =
        int.tryParse(_captureFpsController.text.trim()) ?? 30;
    final int decodeFps = int.tryParse(_decodeFpsController.text.trim()) ?? 12;

    if (ffmpegPath.isEmpty || device.isEmpty || captureSize.isEmpty) {
      setState(() {
        _status = '请填写 ffmpeg 路径、设备名和采集分辨率。';
      });
      return;
    }
    if (decodeFps < 3 || decodeFps > 30) {
      setState(() {
        _status = '录制抽帧 FPS 建议 3-30。';
      });
      return;
    }

    _resetTransferState();
    await _startRuntimeLogSession();
    _mjpegParser.reset();
    _startedAt = DateTime.now();
    _captureStopRequested = false;

    try {
      final Directory? sessionDir = _runtimeSessionDir;
      if (sessionDir == null) {
        throw StateError('runtime session dir is null');
      }
      final File archive = File(
        '${sessionDir.path}${Platform.pathSeparator}capture_frames.cvar',
      );
      _archiveWriter = await FrameArchiveWriter.create(archive);
      _archiveFile = archive;
      _archiveFilePath = archive.path;

      _captureProcess = await Process.start(ffmpegPath, <String>[
        '-hide_banner',
        '-loglevel',
        'warning',
        '-f',
        'dshow',
        '-framerate',
        '$captureFps',
        '-video_size',
        captureSize,
        '-i',
        'video=$device',
        '-vf',
        'fps=$decodeFps',
        '-an',
        '-f',
        'image2pipe',
        '-vcodec',
        'mjpeg',
        '-q:v',
        '3',
        '-',
      ], runInShell: true);

      _captureStderrSub = _captureProcess!.stderr.listen((List<int> chunk) {
        final String text = _decodeProcessBytesAuto(chunk).trim();
        if (text.isNotEmpty) {
          _appendRuntimeLog('ffmpeg: $text');
        }
      });
      _captureStdoutSub = _captureProcess!.stdout.listen(
        (List<int> chunk) => _mjpegParser.addChunk(chunk),
        onDone: () => _appendRuntimeLog('ffmpeg stdout closed'),
      );
      unawaited(
        _captureProcess!.exitCode.then((int code) {
          _appendRuntimeLog('ffmpeg exited: $code');
          if (_captureStopRequested || !_capturing) {
            return;
          }
          unawaited(
            _stopCaptureAndAnalyze(
              reason: '采集中断：ffmpeg 已退出 ($code)',
              analyzeAfterStop: _inputFrames > 0,
            ),
          );
        }),
      );

      _running = true;
      _capturing = true;
      _analyzing = false;
      _status = '录制中，等待清单帧（manifest）...';
      await _appendRuntimeLog(
        'receiver started(capture): ffmpeg=$ffmpegPath, device=$device, capture=$captureSize@$captureFps, sampledFps=$decodeFps, archive=${archive.path}',
      );
      if (mounted) {
        setState(() {});
      }
    } catch (e) {
      await _appendRuntimeLog('start receiver failed: $e');
      await _archiveWriter?.close();
      _archiveWriter = null;
      _archiveFile = null;
      _archiveFilePath = '-';
      if (mounted) {
        setState(() {
          _status = '启动 ffmpeg 失败: $e';
          _running = false;
          _capturing = false;
          _analyzing = false;
        });
      }
    }
  }

  void _onMjpegFrame(Uint8List frameBytes) {
    if (!_capturing) {
      return;
    }
    _inputFrames++;
    _latestCaptureBytes = frameBytes;
    _latestCaptureAt = DateTime.now();

    final FrameArchiveWriter? writer = _archiveWriter;
    if (writer != null) {
      unawaited(
        writer.append(frameBytes).catchError((Object e) async {
          _archiveWriteErrors++;
          await _appendRuntimeLog('archive append failed: $e');
        }),
      );
    }

    final bool shouldProbe =
        _manifest == null &&
        !_manifestProbeBusy &&
        (_inputFrames <= 8 || _inputFrames % 6 == 0);
    if (shouldProbe) {
      unawaited(_decodeFrameForProbe(frameBytes));
    }

    if (_targetCaptureFrames > 0 &&
        _inputFrames >= _targetCaptureFrames &&
        !_captureStopRequested) {
      unawaited(
        _stopCaptureAndAnalyze(reason: '已达到目标录制帧数 $_targetCaptureFrames'),
      );
    } else if (mounted && _inputFrames % 12 == 0) {
      setState(() {});
    }
  }

  Future<void> _decodeFrameForProbe(Uint8List bytes) async {
    if (!_capturing || _manifestProbeBusy) {
      return;
    }
    _manifestProbeBusy = true;
    _probeAttempts++;
    try {
      final DecodedFrameCandidate? decodedCandidate =
          await _decodeVisualCandidate(bytes);
      if (decodedCandidate == null) {
        return;
      }
      _probeHits++;
      _consecutiveMisses = 0;
      _applyDecodedCandidateGeometry(decodedCandidate);
      final VisualPacket packet = decodedCandidate.decoded.packet;
      await _ingestManifestPacket(packet, capturePhase: true);
    } finally {
      _manifestProbeBusy = false;
      if (mounted) {
        setState(() {});
      }
    }
  }

  Future<void> _decodeAndHandleFrame(Uint8List bytes) async {
    if (!_analyzing) {
      return;
    }
    final Stopwatch sw = Stopwatch()..start();
    try {
      _decodedFrames++;
      final DecodedFrameCandidate? decodedCandidate =
          await _decodeVisualCandidate(bytes);
      if (decodedCandidate == null) {
        _invalidFrames++;
        _consecutiveMisses++;
        if (_manualRegionEnabled) {
          _lastDetectedNormalizedRect = _manualNormalizedRect();
        }
        await _persistRuntimeFrame(
          bytes: bytes,
          valid: false,
          normalizedRect: _lastDetectedNormalizedRect,
        );
        return;
      }
      _validFrames++;
      _consecutiveMisses = 0;
      _applyDecodedCandidateGeometry(decodedCandidate);
      await _persistRuntimeFrame(
        bytes: bytes,
        valid: true,
        normalizedRect: _lastDetectedNormalizedRect,
      );
      await _handlePacket(decodedCandidate.decoded.packet);
    } finally {
      sw.stop();
      _recordDecodeCost(sw.elapsedMilliseconds);
    }
  }

  Future<DecodedFrameCandidate?> _decodeVisualCandidate(Uint8List bytes) async {
    if (_manualRegionEnabled) {
      return VisualFrameSampler.decodeAtHint(
        bytes,
        centerXFraction: _manualCenterX,
        centerYFraction: _manualCenterY,
        widthFraction: _manualWidthFraction,
      );
    }
    final Rect? hint = _lastDetectedNormalizedRect;
    if (hint != null) {
      final bool allowGlobal = _consecutiveMisses >= _globalRescanThreshold;
      return VisualFrameSampler.decodeWithHint(
        bytes,
        normalizedHint: hint,
        allowGlobalSearch: allowGlobal,
      );
    }
    return VisualFrameSampler.decodeBestFrame(bytes);
  }

  void _applyDecodedCandidateGeometry(DecodedFrameCandidate decodedCandidate) {
    _latestCaptureWidth = decodedCandidate.sourceWidth;
    _latestCaptureHeight = decodedCandidate.sourceHeight;
    _lastDetectedNormalizedRect = decodedCandidate.geometry.toNormalizedRect(
      Size(
        decodedCandidate.sourceWidth.toDouble(),
        decodedCandidate.sourceHeight.toDouble(),
      ),
    );
  }

  int _fallbackPacketsPerLoop(int totalDataChunks) {
    final int parityCount =
        (totalDataChunks + VisualProtocol.dataPerGroup - 1) ~/
        VisualProtocol.dataPerGroup;
    return totalDataChunks +
        parityCount +
        VisualProtocol.manifestPacketsPerLoop;
  }

  int _fallbackCaptureFrames(int totalDataChunks) {
    const int unknownRepeatSafety = 4;
    return _fallbackPacketsPerLoop(totalDataChunks) *
        VisualProtocol.recommendedCaptureLoops *
        unknownRepeatSafety;
  }

  Future<void> _ingestManifestPacket(
    VisualPacket packet, {
    bool capturePhase = false,
  }) async {
    if (packet.isManifest) {
      final TransferManifest? manifest = TransferManifest.unpack(
        packet.payload,
        transferId: packet.transferId,
        payloadSize: packet.payloadSize,
      );
      if (manifest != null) {
        _manifest = manifest;
        _activeTransferId = manifest.transferId;
        _totalDataChunks = manifest.totalDataChunks;
        _packetsPerLoopHint = manifest.packetsPerLoop;
        _targetCaptureFrames = math.max(
          _inputFrames,
          manifest.recommendedCaptureFrames,
        );
        if (capturePhase) {
          _status = '已识别清单，目标录制 $_targetCaptureFrames 帧后自动转离线解析。';
          await _appendRuntimeLog(
            'manifest detected: transferId=${manifest.transferId}, totalChunks=${manifest.totalDataChunks}, packetsPerLoop=${manifest.packetsPerLoop}, targetFrames=${manifest.recommendedCaptureFrames}',
          );
        }
      }
      _lastPacketInfo =
          'M TID=${packet.transferId.toRadixString(16)} CH=${packet.totalDataChunks}';
      return;
    }

    _activeTransferId ??= packet.transferId;
    _totalDataChunks = packet.totalDataChunks;
    _packetsPerLoopHint = _fallbackPacketsPerLoop(packet.totalDataChunks);
    if (_targetCaptureFrames == 0) {
      _targetCaptureFrames = _fallbackCaptureFrames(packet.totalDataChunks);
      if (capturePhase) {
        _status = '已识别首个数据包，按兜底策略录制 $_targetCaptureFrames 帧。';
        await _appendRuntimeLog(
          'fallback target frames: $_targetCaptureFrames (chunks=${packet.totalDataChunks})',
        );
      }
    }
  }

  Future<void> _stopCaptureProcessOnly() async {
    await _captureStdoutSub?.cancel();
    _captureStdoutSub = null;
    await _captureStderrSub?.cancel();
    _captureStderrSub = null;

    final Process? process = _captureProcess;
    _captureProcess = null;
    if (process != null) {
      try {
        process.kill(ProcessSignal.sigterm);
      } catch (_) {
        // ignore
      }
      try {
        await process.exitCode.timeout(const Duration(seconds: 2));
      } catch (_) {
        // ignore
      }
    }
  }

  Future<void> _stopReceiver({bool analyzeAfterStop = true}) async {
    if (_capturing) {
      await _stopCaptureAndAnalyze(
        reason: '录制已停止',
        analyzeAfterStop: analyzeAfterStop,
      );
      return;
    }
    if (_analyzing) {
      _analyzing = false;
      _running = false;
      _status = '解析已停止。';
      await _appendRuntimeLog('analysis stopped by user');
      if (mounted) {
        setState(() {});
      }
      return;
    }
    await _stopCaptureProcessOnly();
    await _archiveWriter?.close();
    _archiveWriter = null;
  }

  Future<void> _stopCaptureAndAnalyze({
    required String reason,
    bool analyzeAfterStop = true,
  }) async {
    if (!_capturing) {
      return;
    }
    _captureStopRequested = true;
    _capturing = false;
    _status = '$reason，正在结束录制...';
    await _appendRuntimeLog('capture stopping: $reason');
    if (mounted) {
      setState(() {});
    }

    await _stopCaptureProcessOnly();
    await _archiveWriter?.close();
    _archiveWriter = null;
    _mjpegParser.reset();

    if (!analyzeAfterStop) {
      _running = false;
      _status = '接收已停止。';
      if (mounted) {
        setState(() {});
      }
      return;
    }

    final File? archive = _archiveFile;
    if (archive == null || !await archive.exists() || _inputFrames == 0) {
      _running = false;
      _status = '没有可解析的录制帧。';
      if (mounted) {
        setState(() {});
      }
      return;
    }

    _status = '录制完成，开始离线解析...';
    _analyzing = true;
    _decodedFrames = 0;
    _validFrames = 0;
    _invalidFrames = 0;
    _decodeCostsMs.clear();
    _runtimeFrameIndex = 0;
    _savedFilePath = '';
    _assembler = null;
    _lastPacketInfo = '-';
    _consecutiveMisses = 0;
    if (mounted) {
      setState(() {});
    }

    try {
      await for (final Uint8List frame in FrameArchiveReader.readFrames(
        archive,
      )) {
        if (!_analyzing) {
          break;
        }
        await _decodeAndHandleFrame(frame);
        if (_savedFilePath.isNotEmpty) {
          break;
        }
        if (mounted && _decodedFrames % 12 == 0) {
          setState(() {});
        }
      }
      if (_savedFilePath.isEmpty) {
        _status = '解析结束，但分片仍不完整。请提高重发系数或录制更多帧。';
      }
    } catch (e) {
      _status = '离线解析失败: $e';
      await _appendRuntimeLog('archive decode failed: $e');
    } finally {
      _analyzing = false;
      _running = false;
      if (mounted) {
        setState(() {});
      }
    }
  }

  void _recordDecodeCost(int ms) {
    _decodeCostsMs.add(ms);
    const int maxSamples = 160;
    if (_decodeCostsMs.length > maxSamples) {
      _decodeCostsMs.removeRange(0, _decodeCostsMs.length - maxSamples);
    }
  }

  double _elapsedSeconds() {
    final DateTime? started = _startedAt;
    if (started == null) {
      return 0;
    }
    final int elapsedMs = DateTime.now().difference(started).inMilliseconds;
    if (elapsedMs <= 0) {
      return 0;
    }
    return elapsedMs / 1000.0;
  }

  String _ratePerSec(int count) {
    final double sec = _elapsedSeconds();
    if (sec <= 0) {
      return '-';
    }
    return (count / sec).toStringAsFixed(2);
  }

  String _avgDecodeMs() {
    if (_decodeCostsMs.isEmpty) {
      return '-';
    }
    final int sum = _decodeCostsMs.fold<int>(0, (int p, int v) => p + v);
    return (sum / _decodeCostsMs.length).toStringAsFixed(1);
  }

  String _p95DecodeMs() {
    if (_decodeCostsMs.isEmpty) {
      return '-';
    }
    final List<int> sorted = List<int>.from(_decodeCostsMs)..sort();
    final int index = ((sorted.length - 1) * 0.95).round();
    return sorted[index].toString();
  }

  String _receiverPhaseLabel() {
    if (_capturing) {
      return '录制中';
    }
    if (_analyzing) {
      return '离线解析中';
    }
    if (_savedFilePath.isNotEmpty) {
      return '已完成';
    }
    return '空闲';
  }

  double? _progressValue() {
    if (_capturing) {
      if (_targetCaptureFrames <= 0) {
        return null;
      }
      return (_inputFrames / _targetCaptureFrames).clamp(0.0, 1.0);
    }
    if (_analyzing) {
      final double p = _assembler?.progress ?? 0;
      return p <= 0 ? null : p.clamp(0.0, 1.0);
    }
    if (_savedFilePath.isNotEmpty) {
      return 1.0;
    }
    return 0.0;
  }

  String _progressText(double? progressValue) {
    if (progressValue == null) {
      return _capturing ? '等待清单帧...' : '-';
    }
    return '${(progressValue * 100).toStringAsFixed(1)}%';
  }

  Future<void> _handlePacket(VisualPacket packet) async {
    await _ingestManifestPacket(packet);
    if (packet.isManifest) {
      return;
    }

    if (_activeTransferId == null || _activeTransferId != packet.transferId) {
      _activeTransferId = packet.transferId;
      _totalDataChunks = packet.totalDataChunks;
      _assembler = TransferAssembler(
        transferId: packet.transferId,
        totalDataChunks: packet.totalDataChunks,
      );
      _savedFilePath = '';
    }

    final TransferAssembler? assembler = _assembler;
    if (assembler == null) {
      return;
    }
    assembler.accept(packet);
    final String packetTag = packet.isParity ? 'P' : 'D';
    _lastPacketInfo =
        '$packetTag#${packet.chunkIndex} G${packet.groupIndex} TID=${packet.transferId.toRadixString(16)}';
    _status =
        '${_analyzing ? '离线解析' : '接收'} ${assembler.receivedChunks}/${assembler.totalDataChunks} (${(assembler.progress * 100).toStringAsFixed(1)}%)';

    if (assembler.isComplete && _savedFilePath.isEmpty) {
      final Uint8List? packed = assembler.buildPackedFile();
      if (packed == null) {
        return;
      }
      final FileEnvelope? envelope = FileEnvelope.unpack(packed);
      if (envelope == null) {
        _status = '已收齐分片，但封包解析失败。';
        return;
      }
      final String out = await _saveReceivedFile(envelope);
      _savedFilePath = out;
      _status = '传输完成，已保存文件。';
      await _appendRuntimeLog('file saved: $out');
    }
  }

  Future<String> _saveReceivedFile(FileEnvelope envelope) async {
    final String outputDir = _outputDirController.text.trim();
    final Directory dir = Directory(outputDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final String safeName = _sanitizeFileName(envelope.fileName);
    final String timestamp = DateTime.now().millisecondsSinceEpoch.toString();
    final String path =
        '${dir.path}${Platform.pathSeparator}${timestamp}_$safeName';
    final File file = File(path);
    await file.writeAsBytes(envelope.fileBytes, flush: true);
    return path;
  }

  void _resetTransferState() {
    _assembler = null;
    _manifest = null;
    _activeTransferId = null;
    _totalDataChunks = 0;
    _decodedFrames = 0;
    _validFrames = 0;
    _invalidFrames = 0;
    _probeAttempts = 0;
    _probeHits = 0;
    _archiveWriteErrors = 0;
    _targetCaptureFrames = 0;
    _packetsPerLoopHint = 0;
    _archiveFile = null;
    _archiveFilePath = '-';
    _captureStopRequested = false;
    _manifestProbeBusy = false;
    _running = false;
    _capturing = false;
    _analyzing = false;
    _lastPacketInfo = '-';
    _savedFilePath = '';
    _latestCaptureBytes = null;
    _latestCaptureAt = null;
    _latestCaptureWidth = null;
    _latestCaptureHeight = null;
    _lastDetectedNormalizedRect = null;
    _runtimeFrameIndex = 0;
    _consecutiveMisses = 0;
    _inputFrames = 0;
    _decodeCostsMs.clear();
    _startedAt = null;
  }

  @override
  Widget build(BuildContext context) {
    final double? progressValue = _progressValue();
    return Padding(
      padding: const EdgeInsets.all(16),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool narrow = constraints.maxWidth < 1120;
          final Widget left = _buildReceiverControls(progressValue);
          final Widget right = _buildReceiverStatus(progressValue, narrow);
          if (narrow) {
            return ListView(
              children: <Widget>[left, const SizedBox(height: 12), right],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SizedBox(width: 420, child: left),
              const SizedBox(width: 12),
              Expanded(child: right),
            ],
          );
        },
      ),
    );
  }

  Widget _buildReceiverControls(double? progressValue) {
    final bool hasDevices = _videoDevices.isNotEmpty;
    final String? selected =
        hasDevices &&
            _selectedVideoDeviceName != null &&
            _videoDevices.any((e) => e.name == _selectedVideoDeviceName)
        ? _selectedVideoDeviceName
        : null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              '接收参数',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _ffmpegController,
              enabled: !_running,
              decoration: const InputDecoration(labelText: 'ffmpeg 路径'),
            ),
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: _running ? null : () => _scanDevices(),
                    icon: const Icon(Icons.search),
                    label: Text(_scanningDevices ? '扫描中...' : '扫描采集设备'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              key: ValueKey<String>(
                'devices_${_videoDevices.length}_$selected',
              ),
              initialValue: selected,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '可用视频设备'),
              items: _videoDevices
                  .map(
                    (_DshowDeviceEntry d) => DropdownMenuItem<String>(
                      value: d.name,
                      child: Text(d.name, overflow: TextOverflow.ellipsis),
                    ),
                  )
                  .toList(),
              hint: Text(hasDevices ? '请选择视频设备' : '请先扫描设备'),
              onChanged: (!_running && hasDevices)
                  ? _selectDeviceFromDropdown
                  : null,
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _deviceController,
              enabled: !_running,
              decoration: const InputDecoration(
                labelText: '采集卡视频设备名 (dshow，可手填)',
                hintText: '如 video=LCC2003B',
              ),
            ),
            const SizedBox(height: 10),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('手动码区定位（优先）'),
              value: _manualRegionEnabled,
              onChanged: _running
                  ? null
                  : (bool value) {
                      setState(() {
                        _manualRegionEnabled = value;
                      });
                    },
            ),
            if (_manualRegionEnabled) ...<Widget>[
              _buildTuningSlider(
                label: '中心 X',
                value: _manualCenterX,
                onChanged: (double v) => setState(() => _manualCenterX = v),
              ),
              _buildTuningSlider(
                label: '中心 Y',
                value: _manualCenterY,
                onChanged: (double v) => setState(() => _manualCenterY = v),
              ),
              _buildTuningSlider(
                label: '宽度',
                value: _manualWidthFraction,
                min: 0.12,
                max: 0.90,
                onChanged: (double v) =>
                    setState(() => _manualWidthFraction = v),
              ),
              const SizedBox(height: 8),
            ],
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _captureSizeController,
                    enabled: !_running,
                    decoration: const InputDecoration(labelText: '采集分辨率'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _captureFpsController,
                    enabled: !_running,
                    decoration: const InputDecoration(labelText: '采集 FPS'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _decodeFpsController,
              enabled: !_running,
              decoration: const InputDecoration(labelText: '录制抽帧 FPS'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _outputDirController,
              decoration: InputDecoration(
                labelText: '输出目录',
                suffixIcon: IconButton(
                  onPressed: _running ? null : _pickOutputDir,
                  icon: const Icon(Icons.folder),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _running ? null : _startReceiver,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('开始录制'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _running
                        ? () => _stopReceiver(analyzeAfterStop: true)
                        : null,
                    icon: const Icon(Icons.stop),
                    label: Text(_analyzing ? '停止解析' : '停止并解析'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _kv('阶段', _receiverPhaseLabel()),
            _kv('状态', _status),
            _kv('采集链路', 'ffmpeg image2pipe + 本地帧归档'),
            _kv(
              '传输 ID',
              _activeTransferId == null
                  ? '-'
                  : _activeTransferId!.toRadixString(16),
            ),
            _kv('清单文件', _manifest?.fileName ?? '-'),
            _kv(
              '清单长度',
              _manifest == null
                  ? '-'
                  : '${_formatBytes(_manifest!.fileBytesLength)} (packed ${_formatBytes(_manifest!.packedBytesLength)})',
            ),
            _kv('数据分片', _totalDataChunks == 0 ? '-' : '$_totalDataChunks'),
            _kv(
              '目标录制帧',
              _targetCaptureFrames <= 0 ? '等待清单帧' : '$_targetCaptureFrames',
            ),
            _kv('已录制帧', '$_inputFrames (${_ratePerSec(_inputFrames)} fps)'),
            _kv('清单探测', '$_probeHits / $_probeAttempts'),
            _kv('解析帧', '$_decodedFrames'),
            _kv('有效帧', '$_validFrames'),
            _kv('无效帧', '$_invalidFrames'),
            _kv('解码耗时', '${_avgDecodeMs()} ms (P95 ${_p95DecodeMs()} ms)'),
            _kv(
              '每轮帧数',
              _packetsPerLoopHint == 0 ? '-' : '$_packetsPerLoopHint',
            ),
            _kv('归档文件', _archiveFilePath),
            _kv('归档错误', '$_archiveWriteErrors'),
            _kv('已扫设备数', '${_videoDevices.length}'),
            _kv('日志目录', _runtimeLogDirPath),
            _kv('最后包', _lastPacketInfo),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: progressValue),
            const SizedBox(height: 6),
            Text(
              _progressText(progressValue),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTuningSlider({
    required String label,
    required double value,
    required ValueChanged<double> onChanged,
    double min = 0.05,
    double max = 0.95,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('$label: ${value.toStringAsFixed(2)}'),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          onChanged: onChanged,
        ),
      ],
    );
  }

  Widget _buildReceiverStatus(double? progressValue, bool narrow) {
    final String captureTime = _latestCaptureAt == null
        ? '-'
        : _latestCaptureAt!
              .toLocal()
              .toIso8601String()
              .replaceFirst('T', ' ')
              .split('.')
              .first;
    final Widget content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  '采集预览',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                _kv('最后截图时间', captureTime),
                _kv(
                  '截图尺寸',
                  (_latestCaptureWidth == null || _latestCaptureHeight == null)
                      ? '-'
                      : '$_latestCaptureWidth x $_latestCaptureHeight',
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: narrow ? 420 : 360),
                    child: AspectRatio(
                      aspectRatio: 16 / 9,
                      child: DecoratedBox(
                        decoration: const BoxDecoration(
                          color: Color(0xFF0F172A),
                        ),
                        child: _latestCaptureBytes == null
                            ? const Center(
                                child: Text(
                                  '尚未采集到截图',
                                  style: TextStyle(color: Colors.white70),
                                ),
                              )
                            : Stack(
                                fit: StackFit.expand,
                                children: <Widget>[
                                  Image.memory(
                                    _latestCaptureBytes!,
                                    gaplessPlayback: true,
                                    fit: BoxFit.contain,
                                    filterQuality: FilterQuality.none,
                                  ),
                                  IgnorePointer(
                                    child: CustomPaint(
                                      painter: _SamplingOverlayPainter(
                                        normalizedRect: _manualRegionEnabled
                                            ? _manualNormalizedRect()
                                            : _lastDetectedNormalizedRect,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _manualRegionEnabled
                      ? '手动模式已启用，黄色框为手动码区。录制阶段探测失败时请微调中心与宽度。'
                      : (_lastDetectedNormalizedRect == null
                            ? '录制阶段只做轻量探测。即使现在未命中码区，离线解析仍会重新全量扫描。'
                            : '黄色框为最近一次命中的码区。'),
                  style: const TextStyle(
                    color: Color(0xFF475569),
                    fontSize: 12.5,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  '落盘结果',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                Text(
                  _savedFilePath.isEmpty ? '尚未完成接收' : _savedFilePath,
                  style: const TextStyle(fontFamily: 'Consolas'),
                ),
                const SizedBox(height: 8),
                Text(
                  (_analyzing && _savedFilePath.isEmpty)
                      ? '离线解析进行中：${_progressText(progressValue)}'
                      : (_capturing && _targetCaptureFrames > 0
                            ? '录制进度：${_progressText(progressValue)}'
                            : ''),
                  style: const TextStyle(color: Color(0xFFB45309)),
                ),
              ],
            ),
          ),
        ),
      ],
    );
    if (narrow) {
      return content;
    }
    return SingleChildScrollView(child: content);
  }
}

String _defaultFfmpegPath() {
  if (!Platform.isWindows) {
    return 'ffmpeg';
  }
  final String exeDir = File(Platform.resolvedExecutable).parent.path;
  final String localBundled =
      '$exeDir${Platform.pathSeparator}ffmpeg${Platform.pathSeparator}bin${Platform.pathSeparator}ffmpeg.exe';
  if (File(localBundled).existsSync()) {
    return localBundled;
  }
  final String cwdBundled =
      '${Directory.current.path}${Platform.pathSeparator}ffmpeg${Platform.pathSeparator}bin${Platform.pathSeparator}ffmpeg.exe';
  if (File(cwdBundled).existsSync()) {
    return cwdBundled;
  }
  return 'ffmpeg';
}

class _SamplingOverlayPainter extends CustomPainter {
  const _SamplingOverlayPainter({required this.normalizedRect});

  final Rect? normalizedRect;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect? n = normalizedRect;
    if (n == null) {
      return;
    }
    final Rect r = Rect.fromLTWH(
      n.left * size.width,
      n.top * size.height,
      n.width * size.width,
      n.height * size.height,
    );
    final Paint border = Paint()
      ..color = const Color(0xFFFBBF24)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawRect(r, border);
  }

  @override
  bool shouldRepaint(covariant _SamplingOverlayPainter oldDelegate) {
    return oldDelegate.normalizedRect != normalizedRect;
  }
}

Widget _kv(String key, String value) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 110,
          child: Text(
            key,
            style: const TextStyle(
              color: Color(0xFF475569),
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.w500),
          ),
        ),
      ],
    ),
  );
}

String _formatBytes(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(2)} KiB';
  }
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MiB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GiB';
}

String _sanitizeFileName(String input) {
  final String withoutBadChars = input.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  if (withoutBadChars.trim().isEmpty) {
    return 'received.bin';
  }
  return withoutBadChars;
}

class _DshowDeviceEntry {
  const _DshowDeviceEntry({required this.name, this.alternativeName});

  final String name;
  final String? alternativeName;
}

class _DshowScanResult {
  const _DshowScanResult({
    required this.videoDevices,
    required this.audioDevices,
  });

  final List<_DshowDeviceEntry> videoDevices;
  final List<_DshowDeviceEntry> audioDevices;
}

_DshowScanResult _parseDshowScanResult(String text) {
  final List<_DshowDeviceEntry> videos = <_DshowDeviceEntry>[];
  final List<_DshowDeviceEntry> audios = <_DshowDeviceEntry>[];
  final RegExp devicePattern = RegExp(r'"([^"]+)"\s+\((video|audio)\)');
  final RegExp altPattern = RegExp(r'Alternative name\s+"([^"]+)"');
  String? pendingKind;
  int? pendingIndex;

  for (final String rawLine in text.split('\n')) {
    final String line = rawLine.trim();
    if (line.isEmpty) {
      continue;
    }
    final Match? deviceMatch = devicePattern.firstMatch(line);
    if (deviceMatch != null) {
      final String name = deviceMatch.group(1)!.trim();
      final String kind = deviceMatch.group(2)!.toLowerCase();
      if (kind == 'video') {
        videos.add(_DshowDeviceEntry(name: name));
        pendingKind = 'video';
        pendingIndex = videos.length - 1;
      } else {
        audios.add(_DshowDeviceEntry(name: name));
        pendingKind = 'audio';
        pendingIndex = audios.length - 1;
      }
      continue;
    }

    final Match? altMatch = altPattern.firstMatch(line);
    if (altMatch != null && pendingKind != null && pendingIndex != null) {
      final String alt = altMatch.group(1)!.trim();
      if (pendingKind == 'video' && pendingIndex < videos.length) {
        final _DshowDeviceEntry prev = videos[pendingIndex];
        videos[pendingIndex] = _DshowDeviceEntry(
          name: prev.name,
          alternativeName: alt,
        );
      } else if (pendingKind == 'audio' && pendingIndex < audios.length) {
        final _DshowDeviceEntry prev = audios[pendingIndex];
        audios[pendingIndex] = _DshowDeviceEntry(
          name: prev.name,
          alternativeName: alt,
        );
      }
    }
  }

  return _DshowScanResult(videoDevices: videos, audioDevices: audios);
}

_DshowDeviceEntry? _guessBestCaptureVideoDevice(
  List<_DshowDeviceEntry> videos,
  List<_DshowDeviceEntry> audios,
) {
  if (videos.isEmpty) {
    return null;
  }
  _DshowDeviceEntry? best;
  int bestScore = -999;
  for (final _DshowDeviceEntry video in videos) {
    final int score = _scoreCaptureDevice(video, audios);
    if (score > bestScore) {
      bestScore = score;
      best = video;
    }
  }
  if (best == null || bestScore < 7) {
    return null;
  }
  return best;
}

int _scoreCaptureDevice(
  _DshowDeviceEntry video,
  List<_DshowDeviceEntry> audios,
) {
  final String name = video.name.toLowerCase();
  final String alt = (video.alternativeName ?? '').toLowerCase();
  int score = 0;

  const List<String> positiveKeywords = <String>[
    'capture',
    'camlink',
    'cam link',
    'hdmi',
    'grabber',
    'uvc',
    'usb video',
    '采集',
    'lcc',
    'ezcap',
    'av to usb',
    'video converter',
  ];
  for (final String keyword in positiveKeywords) {
    if (name.contains(keyword) || alt.contains(keyword)) {
      score += 5;
    }
  }
  if (RegExp(r'^[a-z]{2,}[0-9]{2,}[a-z0-9]*$').hasMatch(name)) {
    score += 4;
  }
  if (name.contains('camera')) {
    score += 1;
  }
  if (alt.contains('usb#vid_')) {
    score += 3;
  }
  if (name == 'hd camera') {
    score -= 2;
  }

  const List<String> negativeKeywords = <String>[
    'integrated',
    'builtin',
    'built-in',
    'facetime',
    'virtual camera',
    'obs',
    'droidcam',
    'epoccam',
    'ir camera',
    'webcam',
    '内置',
  ];
  for (final String keyword in negativeKeywords) {
    if (name.contains(keyword)) {
      score -= 5;
    }
  }

  final String compactVideoName = _compactDeviceName(name);
  final String? modelToken = _extractModelToken(name);
  for (final _DshowDeviceEntry audio in audios) {
    final String audioName = audio.name.toLowerCase();
    final String compactAudioName = _compactDeviceName(audioName);
    if (compactVideoName.isNotEmpty &&
        compactAudioName.contains(compactVideoName)) {
      score += 6;
    }
    if (modelToken != null && audioName.contains(modelToken)) {
      score += 14;
    }
  }
  return score;
}

String _compactDeviceName(String input) {
  return input.replaceAll(RegExp(r'[^a-z0-9\u4e00-\u9fa5]+'), '');
}

String? _extractModelToken(String input) {
  final RegExp tokenPattern = RegExp(r'[a-z]{2,}[0-9]{2,}[a-z0-9]*');
  final Match? match = tokenPattern.firstMatch(input);
  return match?.group(0);
}

Future<String> _runProcessCaptureMergedOutput(
  String executable,
  List<String> args,
) async {
  final Process process = await Process.start(
    executable,
    args,
    runInShell: true,
  );
  final List<int> stderrBytes = <int>[];
  final List<int> stdoutBytes = <int>[];
  final Completer<void> stderrDone = Completer<void>();
  final Completer<void> stdoutDone = Completer<void>();

  process.stderr.listen(
    stderrBytes.addAll,
    onDone: () => stderrDone.complete(),
  );
  process.stdout.listen(
    stdoutBytes.addAll,
    onDone: () => stdoutDone.complete(),
  );

  await process.exitCode;
  await Future.wait(<Future<void>>[stderrDone.future, stdoutDone.future]);

  final String stderrText = _decodeProcessBytesAuto(stderrBytes);
  final String stdoutText = _decodeProcessBytesAuto(stdoutBytes);
  return '$stderrText\n$stdoutText';
}

String _decodeProcessBytesAuto(List<int> bytes) {
  if (bytes.isEmpty) {
    return '';
  }
  final String utf8Text = const Utf8Decoder(
    allowMalformed: true,
  ).convert(bytes);
  String systemText;
  try {
    systemText = systemEncoding.decode(bytes);
  } catch (_) {
    systemText = utf8Text;
  }

  final int utf8Score = _mojibakeScore(utf8Text);
  final int systemScore = _mojibakeScore(systemText);
  if (utf8Score < systemScore) {
    return utf8Text;
  }
  if (systemScore < utf8Score) {
    return systemText;
  }

  final bool utf8HasReplacement = utf8Text.contains('\uFFFD');
  final bool systemHasReplacement = systemText.contains('\uFFFD');
  if (utf8HasReplacement && !systemHasReplacement) {
    return systemText;
  }
  if (systemHasReplacement && !utf8HasReplacement) {
    return utf8Text;
  }
  return utf8Text;
}

int _mojibakeScore(String text) {
  int score = 0;
  score += '\uFFFD'.allMatches(text).length * 8;
  const List<String> markers = <String>[
    '锟',
    '鏁',
    '闊',
    '鏈',
    '鍙',
    '鎺',
    '楹',
    '閫',
    '鑻',
    '鐗',
    '鎶',
  ];
  for (final String m in markers) {
    score += m.allMatches(text).length;
  }
  return score;
}
