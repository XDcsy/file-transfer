import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

class VisualProtocol {
  static const int gridCols = 120;
  static const int gridRows = 68;
  static const int frameBytes = gridCols * gridRows ~/ 8;
  static const int headerBytes = 40;
  static const int maxPayloadBytes = frameBytes - headerBytes;
  static const int chunkPayloadBytes = 864;
  static const int dataPerGroup = 5;

  static const int version = 1;
  static const int flagParity = 0x01;

  static const List<int> preamble = <int>[
    0xAA,
    0x55,
    0xAA,
    0x55,
    0xAA,
    0x55,
    0xAA,
    0x55,
  ];

  static const List<int> frameMagic = <int>[0x43, 0x56, 0x54, 0x31]; // CVT1
  static const List<int> envelopeMagic = <int>[0x46, 0x49, 0x4C, 0x45]; // FILE
}

class Crc32 {
  static final List<int> _table = _buildTable();

  static int of(Uint8List data, {int offset = 0, int? length}) {
    final int end = offset + (length ?? (data.length - offset));
    int crc = 0xFFFFFFFF;
    for (int i = offset; i < end; i++) {
      final int index = (crc ^ data[i]) & 0xFF;
      crc = (crc >>> 8) ^ _table[index];
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }

  static List<int> _buildTable() {
    final List<int> table = List<int>.filled(256, 0);
    for (int i = 0; i < 256; i++) {
      int c = i;
      for (int j = 0; j < 8; j++) {
        c = (c & 1) != 0 ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
      }
      table[i] = c;
    }
    return table;
  }
}

class FileEnvelope {
  const FileEnvelope({required this.fileName, required this.fileBytes});

  final String fileName;
  final Uint8List fileBytes;

  Uint8List pack() {
    final Uint8List nameBytes = Uint8List.fromList(utf8.encode(fileName));
    final int headerBytes = 4 + 1 + 2 + nameBytes.length + 8;
    final Uint8List out = Uint8List(headerBytes + fileBytes.length);
    out.setRange(0, 4, VisualProtocol.envelopeMagic);
    out[4] = 1;

    final ByteData bd = ByteData.sublistView(out);
    bd.setUint16(5, nameBytes.length, Endian.little);
    out.setRange(7, 7 + nameBytes.length, nameBytes);
    bd.setUint64(7 + nameBytes.length, fileBytes.length, Endian.little);
    out.setRange(headerBytes, out.length, fileBytes);
    return out;
  }

  static FileEnvelope? unpack(Uint8List packed) {
    if (packed.length < 15) {
      return null;
    }
    if (!_bytesEqual(packed, 0, VisualProtocol.envelopeMagic)) {
      return null;
    }
    if (packed[4] != 1) {
      return null;
    }
    final ByteData bd = ByteData.sublistView(packed);
    final int nameLen = bd.getUint16(5, Endian.little);
    final int sizeOffset = 7 + nameLen;
    if (packed.length < sizeOffset + 8) {
      return null;
    }
    final int fileSize = bd.getUint64(sizeOffset, Endian.little);
    final int fileOffset = sizeOffset + 8;
    if (fileSize < 0 || packed.length < fileOffset + fileSize) {
      return null;
    }
    final String fileName = utf8.decode(packed.sublist(7, 7 + nameLen));
    return FileEnvelope(
      fileName: fileName,
      fileBytes: Uint8List.fromList(
        packed.sublist(fileOffset, fileOffset + fileSize),
      ),
    );
  }
}

class VisualPacket {
  const VisualPacket({
    required this.transferId,
    required this.totalDataChunks,
    required this.chunkIndex,
    required this.groupIndex,
    required this.isParity,
    required this.payload,
    required this.payloadSize,
  });

  final int transferId;
  final int totalDataChunks;
  final int chunkIndex;
  final int groupIndex;
  final bool isParity;
  final Uint8List payload;
  final int payloadSize;

  Uint8List toFrameBytes() {
    final Uint8List out = Uint8List(VisualProtocol.frameBytes);
    out.setRange(0, 8, VisualProtocol.preamble);
    out.setRange(8, 12, VisualProtocol.frameMagic);
    out[12] = VisualProtocol.version;
    out[13] = isParity ? VisualProtocol.flagParity : 0;

    final ByteData bd = ByteData.sublistView(out);
    bd.setUint16(14, VisualProtocol.headerBytes, Endian.little);
    bd.setUint32(16, transferId, Endian.little);
    bd.setUint32(20, totalDataChunks, Endian.little);
    bd.setUint32(24, chunkIndex, Endian.little);
    bd.setUint32(28, groupIndex, Endian.little);
    bd.setUint16(32, payloadSize, Endian.little);
    bd.setUint32(34, Crc32.of(payload, length: payloadSize), Endian.little);

    final Uint8List headerForCrc = Uint8List.fromList(out.sublist(8, 38));
    final int headerCrc = Crc32.of(headerForCrc) & 0xFFFF;
    bd.setUint16(38, headerCrc, Endian.little);

    out.setRange(
      VisualProtocol.headerBytes,
      VisualProtocol.headerBytes + payloadSize,
      payload.sublist(0, payloadSize),
    );
    return out;
  }

  static VisualPacket? fromFrameBytes(Uint8List frameBytes) {
    if (frameBytes.length != VisualProtocol.frameBytes) {
      return null;
    }
    if (!_bytesEqual(frameBytes, 0, VisualProtocol.preamble)) {
      return null;
    }
    if (!_bytesEqual(frameBytes, 8, VisualProtocol.frameMagic)) {
      return null;
    }
    if (frameBytes[12] != VisualProtocol.version) {
      return null;
    }

    final ByteData bd = ByteData.sublistView(frameBytes);
    final int headerLen = bd.getUint16(14, Endian.little);
    if (headerLen != VisualProtocol.headerBytes) {
      return null;
    }

    final Uint8List headerForCrc = Uint8List.fromList(
      frameBytes.sublist(8, 38),
    );
    final int expectedHeaderCrc = Crc32.of(headerForCrc) & 0xFFFF;
    final int headerCrc = bd.getUint16(38, Endian.little);
    if (expectedHeaderCrc != headerCrc) {
      return null;
    }

    final int transferId = bd.getUint32(16, Endian.little);
    final int totalDataChunks = bd.getUint32(20, Endian.little);
    final int chunkIndex = bd.getUint32(24, Endian.little);
    final int groupIndex = bd.getUint32(28, Endian.little);
    final int payloadSize = bd.getUint16(32, Endian.little);
    if (payloadSize < 0 || payloadSize > VisualProtocol.maxPayloadBytes) {
      return null;
    }
    final int expectedPayloadCrc = bd.getUint32(34, Endian.little);
    final Uint8List payload = Uint8List.fromList(
      frameBytes.sublist(
        VisualProtocol.headerBytes,
        VisualProtocol.headerBytes + payloadSize,
      ),
    );
    final int actualPayloadCrc = Crc32.of(payload, length: payloadSize);
    if (actualPayloadCrc != expectedPayloadCrc) {
      return null;
    }
    return VisualPacket(
      transferId: transferId,
      totalDataChunks: totalDataChunks,
      chunkIndex: chunkIndex,
      groupIndex: groupIndex,
      isParity: (frameBytes[13] & VisualProtocol.flagParity) != 0,
      payload: payload,
      payloadSize: payloadSize,
    );
  }
}

class TransferSession {
  const TransferSession({
    required this.transferId,
    required this.fileName,
    required this.fileBytes,
    required this.totalDataChunks,
    required this.schedule,
  });

  final int transferId;
  final String fileName;
  final Uint8List fileBytes;
  final int totalDataChunks;
  final List<VisualPacket> schedule;

  double estimatedPayloadThroughputBytesPerSecond({
    required double fps,
    required int repeatCount,
  }) {
    final double usefulRatio =
        VisualProtocol.dataPerGroup / (VisualProtocol.dataPerGroup + 1);
    return (VisualProtocol.chunkPayloadBytes * fps * usefulRatio) /
        max(1, repeatCount);
  }
}

class VisualTransferEncoder {
  static TransferSession buildSession({
    required String fileName,
    required Uint8List fileBytes,
    int? transferId,
    int repeatCount = 1,
  }) {
    final int sessionId = transferId ?? _createTransferId();
    final Uint8List packed = FileEnvelope(
      fileName: fileName,
      fileBytes: fileBytes,
    ).pack();

    final List<VisualPacket> dataPackets = <VisualPacket>[];
    int chunkIndex = 0;
    for (
      int offset = 0;
      offset < packed.length;
      offset += VisualProtocol.chunkPayloadBytes
    ) {
      final int end = min(
        offset + VisualProtocol.chunkPayloadBytes,
        packed.length,
      );
      final Uint8List payload = Uint8List.fromList(packed.sublist(offset, end));
      dataPackets.add(
        VisualPacket(
          transferId: sessionId,
          totalDataChunks: 0,
          chunkIndex: chunkIndex,
          groupIndex: chunkIndex ~/ VisualProtocol.dataPerGroup,
          isParity: false,
          payload: payload,
          payloadSize: payload.length,
        ),
      );
      chunkIndex++;
    }

    final int totalDataChunks = dataPackets.length;
    final List<VisualPacket> normalizedData = dataPackets
        .map(
          (VisualPacket p) => VisualPacket(
            transferId: p.transferId,
            totalDataChunks: totalDataChunks,
            chunkIndex: p.chunkIndex,
            groupIndex: p.groupIndex,
            isParity: p.isParity,
            payload: p.payload,
            payloadSize: p.payloadSize,
          ),
        )
        .toList();

    final List<VisualPacket> parityPackets = <VisualPacket>[];
    for (
      int group = 0;
      group * VisualProtocol.dataPerGroup < totalDataChunks;
      group++
    ) {
      final int start = group * VisualProtocol.dataPerGroup;
      final int end = min(start + VisualProtocol.dataPerGroup, totalDataChunks);
      final Uint8List parity = Uint8List(VisualProtocol.chunkPayloadBytes);
      for (int i = start; i < end; i++) {
        final Uint8List padded = _padPayload(normalizedData[i].payload);
        for (int b = 0; b < parity.length; b++) {
          parity[b] ^= padded[b];
        }
      }
      parityPackets.add(
        VisualPacket(
          transferId: sessionId,
          totalDataChunks: totalDataChunks,
          chunkIndex: group,
          groupIndex: group,
          isParity: true,
          payload: parity,
          payloadSize: parity.length,
        ),
      );
    }

    final List<VisualPacket> round = _interleave(normalizedData, parityPackets);
    final List<VisualPacket> schedule = <VisualPacket>[];
    final int repeat = max(1, repeatCount);
    for (int i = 0; i < repeat; i++) {
      schedule.addAll(round);
    }

    return TransferSession(
      transferId: sessionId,
      fileName: fileName,
      fileBytes: fileBytes,
      totalDataChunks: totalDataChunks,
      schedule: schedule,
    );
  }

  static Uint8List _padPayload(Uint8List payload) {
    if (payload.length == VisualProtocol.chunkPayloadBytes) {
      return payload;
    }
    final Uint8List out = Uint8List(VisualProtocol.chunkPayloadBytes);
    out.setRange(0, payload.length, payload);
    return out;
  }

  static List<VisualPacket> _interleave(
    List<VisualPacket> data,
    List<VisualPacket> parity,
  ) {
    final int groups = parity.length;
    final List<List<VisualPacket>> dataByGroup =
        List<List<VisualPacket>>.generate(groups, (_) => <VisualPacket>[]);
    for (final VisualPacket p in data) {
      dataByGroup[p.groupIndex].add(p);
    }

    final List<VisualPacket> schedule = <VisualPacket>[];
    for (int step = 0; step <= VisualProtocol.dataPerGroup; step++) {
      for (int g = 0; g < groups; g++) {
        final List<VisualPacket> groupPackets = dataByGroup[g];
        if (step < groupPackets.length) {
          schedule.add(groupPackets[step]);
        } else if (step == VisualProtocol.dataPerGroup) {
          schedule.add(parity[g]);
        }
      }
    }
    return schedule;
  }

  static int _createTransferId() {
    final int now = DateTime.now().millisecondsSinceEpoch;
    return (now ^ (now >>> 16)) & 0xFFFFFFFF;
  }
}

class TransferAssembler {
  TransferAssembler({required this.transferId, required this.totalDataChunks});

  final int transferId;
  final int totalDataChunks;

  final Map<int, Uint8List> _chunks = <int, Uint8List>{};
  final Map<int, int> _chunkSizes = <int, int>{};
  final Map<int, Uint8List> _parityByGroup = <int, Uint8List>{};

  int get receivedChunks => _chunks.length;
  double get progress =>
      totalDataChunks == 0 ? 0 : receivedChunks / totalDataChunks;
  bool get isComplete => receivedChunks >= totalDataChunks;

  bool accept(VisualPacket packet) {
    if (packet.transferId != transferId ||
        packet.totalDataChunks != totalDataChunks) {
      return false;
    }
    bool changed = false;
    if (packet.isParity) {
      if (!_parityByGroup.containsKey(packet.groupIndex)) {
        _parityByGroup[packet.groupIndex] = _normalizePayload(
          packet.payload,
          packet.payloadSize,
        );
        changed = true;
      }
      if (_attemptRepair(packet.groupIndex)) {
        changed = true;
      }
      return changed;
    }

    if (!_chunks.containsKey(packet.chunkIndex)) {
      _chunks[packet.chunkIndex] = _normalizePayload(
        packet.payload,
        packet.payloadSize,
      );
      _chunkSizes[packet.chunkIndex] = packet.payloadSize;
      changed = true;
    }
    if (_attemptRepair(packet.groupIndex)) {
      changed = true;
    }
    return changed;
  }

  Uint8List? buildPackedFile() {
    if (!isComplete) {
      return null;
    }
    final BytesBuilder builder = BytesBuilder(copy: false);
    for (int i = 0; i < totalDataChunks; i++) {
      final Uint8List? chunk = _chunks[i];
      if (chunk == null) {
        return null;
      }
      final int size = _chunkSizes[i] ?? VisualProtocol.chunkPayloadBytes;
      builder.add(chunk.sublist(0, min(size, chunk.length)));
    }
    return builder.toBytes();
  }

  bool _attemptRepair(int group) {
    final Uint8List? parity = _parityByGroup[group];
    if (parity == null) {
      return false;
    }

    final int start = group * VisualProtocol.dataPerGroup;
    final int end = min(start + VisualProtocol.dataPerGroup, totalDataChunks);
    final List<int> missing = <int>[];
    for (int i = start; i < end; i++) {
      if (!_chunks.containsKey(i)) {
        missing.add(i);
      }
    }
    if (missing.length != 1) {
      return false;
    }

    final Uint8List restored = Uint8List.fromList(parity);
    for (int i = start; i < end; i++) {
      if (i == missing.first) {
        continue;
      }
      final Uint8List? chunk = _chunks[i];
      if (chunk == null) {
        return false;
      }
      for (int b = 0; b < restored.length; b++) {
        restored[b] ^= chunk[b];
      }
    }

    final int missingIndex = missing.first;
    _chunks[missingIndex] = restored;
    _chunkSizes[missingIndex] = missingIndex == totalDataChunks - 1
        ? VisualProtocol.chunkPayloadBytes
        : VisualProtocol.chunkPayloadBytes;
    return true;
  }

  static Uint8List _normalizePayload(Uint8List payload, int payloadSize) {
    final Uint8List out = Uint8List(VisualProtocol.chunkPayloadBytes);
    final int len = min(payloadSize, payload.length);
    out.setRange(0, len, payload);
    return out;
  }
}

class VisualFrameBitCodec {
  static List<int> bytesToBits(Uint8List bytes) {
    final List<int> bits = List<int>.filled(
      bytes.length * 8,
      0,
      growable: false,
    );
    int bi = 0;
    for (final int byte in bytes) {
      for (int bit = 7; bit >= 0; bit--) {
        bits[bi++] = (byte >> bit) & 1;
      }
    }
    return bits;
  }

  static Uint8List bitsToBytes(List<int> bits) {
    final int byteCount = bits.length ~/ 8;
    final Uint8List out = Uint8List(byteCount);
    for (int i = 0; i < byteCount; i++) {
      int value = 0;
      for (int bit = 0; bit < 8; bit++) {
        value = (value << 1) | (bits[i * 8 + bit] & 1);
      }
      out[i] = value;
    }
    return out;
  }
}

class DecodedVisualFrame {
  const DecodedVisualFrame({
    required this.packet,
    required this.threshold,
    required this.inverted,
  });

  final VisualPacket packet;
  final double threshold;
  final bool inverted;
}

class VisualFrameDecoder {
  static DecodedVisualFrame? decodeLumaSamples(List<double> lumaSamples) {
    final int expectedSamples =
        VisualProtocol.gridCols * VisualProtocol.gridRows;
    if (lumaSamples.length != expectedSamples) {
      return null;
    }

    final List<int> expectedPreambleBits = VisualFrameBitCodec.bytesToBits(
      Uint8List.fromList(VisualProtocol.preamble),
    );
    if (expectedPreambleBits.length < 64) {
      return null;
    }

    double oneSum = 0;
    double zeroSum = 0;
    int oneCount = 0;
    int zeroCount = 0;
    for (int i = 0; i < 64; i++) {
      if (expectedPreambleBits[i] == 1) {
        oneSum += lumaSamples[i];
        oneCount++;
      } else {
        zeroSum += lumaSamples[i];
        zeroCount++;
      }
    }
    if (oneCount == 0 || zeroCount == 0) {
      return null;
    }

    final double avgOne = oneSum / oneCount;
    final double avgZero = zeroSum / zeroCount;
    final double threshold = (avgOne + avgZero) / 2.0;

    final bool oneIsDarkPrimary = avgOne < avgZero;
    final Uint8List? primary = _decodeWithMapping(
      lumaSamples: lumaSamples,
      threshold: threshold,
      oneIsDark: oneIsDarkPrimary,
    );
    Uint8List? frameBytes = primary;
    bool inverted = false;

    if (frameBytes == null) {
      frameBytes = _decodeWithMapping(
        lumaSamples: lumaSamples,
        threshold: threshold,
        oneIsDark: !oneIsDarkPrimary,
      );
      inverted = true;
    }
    if (frameBytes == null) {
      return null;
    }

    final VisualPacket? packet = VisualPacket.fromFrameBytes(frameBytes);
    if (packet == null) {
      return null;
    }
    return DecodedVisualFrame(
      packet: packet,
      threshold: threshold,
      inverted: inverted,
    );
  }

  static Uint8List? _decodeWithMapping({
    required List<double> lumaSamples,
    required double threshold,
    required bool oneIsDark,
  }) {
    final List<int> bits = List<int>.filled(
      lumaSamples.length,
      0,
      growable: false,
    );
    for (int i = 0; i < lumaSamples.length; i++) {
      final double l = lumaSamples[i];
      final int bit = oneIsDark
          ? (l < threshold ? 1 : 0)
          : (l > threshold ? 1 : 0);
      bits[i] = bit;
    }
    final Uint8List bytes = VisualFrameBitCodec.bitsToBytes(bits);
    if (!_bytesEqual(bytes, 0, VisualProtocol.preamble)) {
      return null;
    }
    return bytes;
  }
}

bool _bytesEqual(Uint8List source, int offset, List<int> expected) {
  if (source.length < offset + expected.length) {
    return false;
  }
  for (int i = 0; i < expected.length; i++) {
    if (source[offset + i] != expected[i]) {
      return false;
    }
  }
  return true;
}
