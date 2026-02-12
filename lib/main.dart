import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';

import 'src/visual_frame_codec.dart';
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
    _message = '已启动发送。将窗口拖到采集卡输出屏并全屏显示。';

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
    _subtitle =
        'TID ${packet.transferId.toRadixString(16)} | ${packet.isParity ? 'Parity' : 'Data'} #${packet.chunkIndex} | Group ${packet.groupIndex}';
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
    final int repeat = int.tryParse(_repeatController.text.trim()) ?? 1;
    final double throughput = session == null
        ? 0
        : session.estimatedPayloadThroughputBytesPerSecond(
            fps: fps,
            repeatCount: repeat,
          );

    final Duration elapsed = _startedAt == null
        ? Duration.zero
        : DateTime.now().difference(_startedAt!);
    final int elapsedMs = elapsed.inMilliseconds;
    final double frameRateActual = elapsedMs <= 0
        ? 0
        : (_sentFrames * 1000.0 / elapsedMs);

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
  Timer? _pollTimer;
  File? _captureFile;
  DateTime? _lastFrameTs;
  bool _decodingBusy = false;
  bool _running = false;

  TransferAssembler? _assembler;
  int? _activeTransferId;
  int _totalDataChunks = 0;
  int _decodedFrames = 0;
  int _validFrames = 0;
  int _invalidFrames = 0;
  String _status = '空闲';
  String _lastPacketInfo = '-';
  String _savedFilePath = '';
  Uint8List? _latestCaptureBytes;
  DateTime? _latestCaptureAt;
  int? _latestCaptureWidth;
  int? _latestCaptureHeight;
  Rect? _lastDetectedNormalizedRect;
  final List<_DshowDeviceEntry> _videoDevices = <_DshowDeviceEntry>[];
  bool _scanningDevices = false;
  bool _manualRegionEnabled = false;
  double _manualCenterX = 0.5;
  double _manualCenterY = 0.5;
  double _manualWidthFraction = 0.40;

  @override
  void initState() {
    super.initState();
    _ffmpegController = TextEditingController(text: _defaultFfmpegPath());
    _outputDirController.text = Directory.current.path;
    Future<void>.delayed(
      const Duration(milliseconds: 220),
      () => _scanDevices(silent: true),
    );
  }

  @override
  void dispose() {
    _stopReceiver();
    _ffmpegController.dispose();
    _deviceController.dispose();
    _captureSizeController.dispose();
    _captureFpsController.dispose();
    _decodeFpsController.dispose();
    _outputDirController.dispose();
    super.dispose();
  }

  String? get _selectedDropdownDevice {
    final String current = _deviceController.text.trim();
    if (current.isEmpty) {
      return null;
    }
    for (final _DshowDeviceEntry d in _videoDevices) {
      if (d.name == current) {
        return current;
      }
    }
    return null;
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
          _deviceController.clear();
          if (!silent) {
            _status = '未解析到采集设备，请确认系统识别到了采集卡。';
          }
        } else if (guessed != null) {
          _deviceController.text = guessed.name;
          _status =
              '扫描到 ${scanResult.videoDevices.length} 个视频设备，已自动选择：${guessed.name}';
        } else {
          _deviceController.clear();
          if (!silent) {
            _status =
                '扫描到 ${scanResult.videoDevices.length} 个视频设备，但未识别出采集卡，请手动填写。';
          }
        }
      });
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
      _deviceController.text = value;
      _status = '已选择设备：$value';
    });
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

  Future<void> _startReceiver() async {
    if (_running) {
      return;
    }
    final String ffmpegPath = _ffmpegController.text.trim();
    final String device = _deviceController.text.trim();
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
        _status = '解码帧率建议 3-30。';
      });
      return;
    }

    _resetTransferState();
    final Directory temp = Directory.systemTemp;
    final File captureFile = File(
      '${temp.path}${Platform.pathSeparator}capture_vision_latest.jpg',
    );
    _captureFile = captureFile;
    _lastFrameTs = null;

    try {
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
        '-q:v',
        '3',
        '-update',
        '1',
        '-y',
        captureFile.path,
      ], runInShell: true);

      _captureProcess!.stderr.listen((List<int> _) {});
      _captureProcess!.stdout.listen((List<int> _) {});

      _running = true;
      _status = '接收中，等待有效帧...';
      _pollTimer = Timer.periodic(
        Duration(milliseconds: (1000 / decodeFps).round()),
        (_) => _pollFrame(),
      );
      setState(() {});
    } catch (e) {
      setState(() {
        _status = '启动 ffmpeg 失败: $e';
      });
    }
  }

  Future<void> _pollFrame() async {
    if (_decodingBusy || !_running) {
      return;
    }
    final File? frameFile = _captureFile;
    if (frameFile == null || !await frameFile.exists()) {
      return;
    }
    final DateTime modifiedAt = await frameFile.lastModified();
    if (_lastFrameTs != null && !modifiedAt.isAfter(_lastFrameTs!)) {
      return;
    }
    _lastFrameTs = modifiedAt;
    _decodingBusy = true;
    try {
      final Uint8List bytes = await frameFile.readAsBytes();
      _latestCaptureBytes = bytes;
      _latestCaptureAt = modifiedAt;
      _decodedFrames++;
      DecodedFrameCandidate? decodedCandidate;
      if (_manualRegionEnabled) {
        decodedCandidate = await VisualFrameSampler.decodeAtHint(
          bytes,
          centerXFraction: _manualCenterX,
          centerYFraction: _manualCenterY,
          widthFraction: _manualWidthFraction,
        );
      }
      decodedCandidate ??= await VisualFrameSampler.decodeBestFrame(bytes);
      if (decodedCandidate == null) {
        _invalidFrames++;
        _lastDetectedNormalizedRect = _manualRegionEnabled
            ? _manualNormalizedRect()
            : null;
        return;
      }
      _latestCaptureWidth = decodedCandidate.sourceWidth;
      _latestCaptureHeight = decodedCandidate.sourceHeight;
      _lastDetectedNormalizedRect = decodedCandidate.geometry.toNormalizedRect(
        Size(
          decodedCandidate.sourceWidth.toDouble(),
          decodedCandidate.sourceHeight.toDouble(),
        ),
      );
      _validFrames++;
      _handlePacket(decodedCandidate.decoded.packet);
    } finally {
      _decodingBusy = false;
      if (mounted) {
        setState(() {});
      }
    }
  }

  Future<void> _handlePacket(VisualPacket packet) async {
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
    _lastPacketInfo =
        '${packet.isParity ? 'P' : 'D'}#${packet.chunkIndex} G${packet.groupIndex} TID=${packet.transferId.toRadixString(16)}';
    _status =
        '接收中 ${assembler.receivedChunks}/${assembler.totalDataChunks} (${(assembler.progress * 100).toStringAsFixed(1)}%)';

    if (assembler.isComplete && _savedFilePath.isEmpty) {
      final Uint8List? packed = assembler.buildPackedFile();
      if (packed == null) {
        return;
      }
      final FileEnvelope? envelope = FileEnvelope.unpack(packed);
      if (envelope == null) {
        setState(() {
          _status = '已收齐分片，但封包解析失败。';
        });
        return;
      }
      final String out = await _saveReceivedFile(envelope);
      setState(() {
        _savedFilePath = out;
        _status = '传输完成，已保存文件。';
      });
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

  void _stopReceiver() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _captureProcess?.kill(ProcessSignal.sigterm);
    _captureProcess = null;
    if (_running) {
      setState(() {
        _running = false;
        _status = '接收已停止。';
      });
    }
  }

  void _resetTransferState() {
    _assembler = null;
    _activeTransferId = null;
    _totalDataChunks = 0;
    _decodedFrames = 0;
    _validFrames = 0;
    _invalidFrames = 0;
    _lastPacketInfo = '-';
    _savedFilePath = '';
    _latestCaptureBytes = null;
    _latestCaptureAt = null;
    _latestCaptureWidth = null;
    _latestCaptureHeight = null;
    _lastDetectedNormalizedRect = null;
  }

  @override
  Widget build(BuildContext context) {
    final double progress = _assembler?.progress ?? 0;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool narrow = constraints.maxWidth < 1120;
          final Widget left = _buildReceiverControls(progress);
          final Widget right = _buildReceiverStatus(progress, narrow);
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

  Widget _buildReceiverControls(double progress) {
    final bool hasDevices = _videoDevices.isNotEmpty;
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
            if (hasDevices) ...<Widget>[
              DropdownButtonFormField<String>(
                initialValue: _selectedDropdownDevice,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '扫描结果（视频设备）'),
                items: _videoDevices
                    .map(
                      (_DshowDeviceEntry d) => DropdownMenuItem<String>(
                        value: d.name,
                        child: Text(d.name, overflow: TextOverflow.ellipsis),
                      ),
                    )
                    .toList(),
                onChanged: _running ? null : _selectDeviceFromDropdown,
              ),
              const SizedBox(height: 10),
            ],
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
              decoration: const InputDecoration(labelText: '解码 FPS'),
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
                    label: const Text('开始接收'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _running ? _stopReceiver : null,
                    icon: const Icon(Icons.stop),
                    label: const Text('停止'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _kv('状态', _status),
            _kv(
              '传输 ID',
              _activeTransferId == null
                  ? '-'
                  : _activeTransferId!.toRadixString(16),
            ),
            _kv('数据分片', _totalDataChunks == 0 ? '-' : '$_totalDataChunks'),
            _kv('解码帧', '$_decodedFrames'),
            _kv('有效帧', '$_validFrames'),
            _kv('无效帧', '$_invalidFrames'),
            _kv('已扫设备数', '${_videoDevices.length}'),
            _kv('最后包', _lastPacketInfo),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: progress == 0 ? null : progress),
            const SizedBox(height: 6),
            Text(
              '${(progress * 100).toStringAsFixed(1)}%',
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

  Widget _buildReceiverStatus(double progress, bool narrow) {
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
                      ? '手动模式已启用，黄色框为手动码区。无效帧持续增长时请微调中心与宽度。'
                      : (_lastDetectedNormalizedRect == null
                            ? '未识别到有效码区。请让发送端码图尽量充满采集画面，避免窗口边框与系统桌面占据主体。'
                            : '黄色框为本帧实际命中的解码区域。'),
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
                  progress >= 1 && _savedFilePath.isEmpty
                      ? '分片齐全，但仍在处理封包。'
                      : '',
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
  return _DshowScanResult(
    videoDevices: _parseDshowSectionEntries(text, 'DirectShow video devices'),
    audioDevices: _parseDshowSectionEntries(text, 'DirectShow audio devices'),
  );
}

List<_DshowDeviceEntry> _parseDshowSectionEntries(String text, String marker) {
  final List<_DshowDeviceEntry> devices = <_DshowDeviceEntry>[];
  bool inSection = false;
  int? pendingIndex;
  final RegExp quoted = RegExp(r'"([^"]+)"');

  for (final String line in text.split('\n')) {
    if (line.contains(marker)) {
      inSection = true;
      pendingIndex = null;
      continue;
    }
    if (!inSection) {
      continue;
    }
    if (line.contains('DirectShow') && !line.contains(marker)) {
      inSection = false;
      pendingIndex = null;
      continue;
    }
    final Match? match = quoted.firstMatch(line);
    if (match == null) {
      continue;
    }
    final String value = match.group(1)!;
    if (line.contains('Alternative name')) {
      if (pendingIndex != null) {
        final _DshowDeviceEntry prev = devices[pendingIndex];
        devices[pendingIndex] = _DshowDeviceEntry(
          name: prev.name,
          alternativeName: value,
        );
      }
      continue;
    }
    devices.add(_DshowDeviceEntry(name: value));
    pendingIndex = devices.length - 1;
  }
  return devices;
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
