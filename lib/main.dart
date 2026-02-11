import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

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
    if (!Platform.isWindows) {
      setState(() {
        _message = '当前环境不是 Windows，请手动输入文件路径。';
      });
      return;
    }

    const String script = r'''
Add-Type -AssemblyName System.Windows.Forms
$dlg = New-Object System.Windows.Forms.OpenFileDialog
$dlg.Multiselect = $false
if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
  Write-Output $dlg.FileName
}
''';
    final ProcessResult result = await Process.run('powershell', <String>[
      '-NoProfile',
      '-Command',
      script,
    ], runInShell: true);
    final String picked = (result.stdout ?? '').toString().trim();
    if (picked.isNotEmpty) {
      setState(() {
        _filePathController.text = picked;
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
  String _status = '空闲';
  String _lastPacketInfo = '-';
  String _ffmpegLog = '';
  String _savedFilePath = '';

  @override
  void initState() {
    super.initState();
    _ffmpegController = TextEditingController(text: _defaultFfmpegPath());
    _outputDirController.text = Directory.current.path;
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

  Future<void> _scanDevices() async {
    final String ffmpegPath = _ffmpegController.text.trim();
    if (ffmpegPath.isEmpty) {
      setState(() {
        _status = '请先填写 ffmpeg 路径。';
      });
      return;
    }
    try {
      final ProcessResult result = await Process.run(ffmpegPath, <String>[
        '-hide_banner',
        '-list_devices',
        'true',
        '-f',
        'dshow',
        '-i',
        'dummy',
      ], runInShell: true);
      final String merged = '${result.stderr}\n${result.stdout}';
      final List<String> devices = _parseDshowDevices(merged);
      setState(() {
        if (devices.isEmpty) {
          _status = '未解析到采集设备，请确认系统识别到了采集卡。';
        } else {
          _deviceController.text = devices.first;
          _status = '扫描到 ${devices.length} 个视频设备。';
        }
        _ffmpegLog = merged;
      });
    } catch (e) {
      setState(() {
        _status = '扫描设备失败: $e';
      });
    }
  }

  Future<void> _pickOutputDir() async {
    if (!Platform.isWindows) {
      setState(() {
        _status = '当前环境不是 Windows，请手动输入输出目录。';
      });
      return;
    }
    const String script = r'''
Add-Type -AssemblyName System.Windows.Forms
$dlg = New-Object System.Windows.Forms.FolderBrowserDialog
if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
  Write-Output $dlg.SelectedPath
}
''';
    final ProcessResult result = await Process.run('powershell', <String>[
      '-NoProfile',
      '-Command',
      script,
    ], runInShell: true);
    final String selected = (result.stdout ?? '').toString().trim();
    if (selected.isNotEmpty) {
      setState(() {
        _outputDirController.text = selected;
      });
    }
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

      _captureProcess!.stderr.transform(utf8.decoder).listen((String data) {
        setState(() {
          _ffmpegLog = (_ffmpegLog + data);
          if (_ffmpegLog.length > 5000) {
            _ffmpegLog = _ffmpegLog.substring(_ffmpegLog.length - 5000);
          }
        });
      });

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
      _decodedFrames++;
      final List<double>? lumaSamples = await VisualFrameSampler.sampleLuma(
        bytes,
      );
      if (lumaSamples == null) {
        return;
      }
      final DecodedVisualFrame? decoded = VisualFrameDecoder.decodeLumaSamples(
        lumaSamples,
      );
      if (decoded == null) {
        return;
      }
      _validFrames++;
      _handlePacket(decoded.packet);
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
    _lastPacketInfo = '-';
    _savedFilePath = '';
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
          final Widget right = _buildReceiverStatus(progress);
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
            TextField(
              controller: _deviceController,
              enabled: !_running,
              decoration: InputDecoration(
                labelText: '采集卡视频设备名 (dshow)',
                suffixIcon: IconButton(
                  onPressed: _running ? null : _scanDevices,
                  icon: const Icon(Icons.search),
                ),
              ),
            ),
            const SizedBox(height: 10),
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

  Widget _buildReceiverStatus(double progress) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  '接收日志',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                SelectableText(
                  _ffmpegLog.isEmpty ? '暂无日志' : _ffmpegLog,
                  style: const TextStyle(fontFamily: 'Consolas', fontSize: 12),
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

List<String> _parseDshowDevices(String text) {
  final List<String> devices = <String>[];
  bool inVideoSection = false;
  final RegExp quoted = RegExp(r'"([^"]+)"');
  for (final String line in text.split('\n')) {
    if (line.contains('DirectShow video devices')) {
      inVideoSection = true;
      continue;
    }
    if (line.contains('DirectShow audio devices')) {
      inVideoSection = false;
      continue;
    }
    if (!inVideoSection) {
      continue;
    }
    final Match? match = quoted.firstMatch(line);
    if (match != null) {
      devices.add(match.group(1)!);
    }
  }
  return devices;
}
