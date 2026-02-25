import 'dart:io';
import 'dart:typed_data';

class FrameArchiveWriter {
  FrameArchiveWriter._({required this.file, required RandomAccessFile raf})
    : _raf = raf;

  static const List<int> _magic = <int>[0x43, 0x56, 0x41, 0x52]; // CVAR
  static const int _headerBytes = 8;

  final File file;
  final RandomAccessFile _raf;
  Future<void> _pendingWrite = Future<void>.value();
  bool _closed = false;

  int frameCount = 0;
  int payloadBytes = 0;

  static Future<FrameArchiveWriter> create(File file) async {
    await file.parent.create(recursive: true);
    final RandomAccessFile raf = await file.open(mode: FileMode.writeOnly);

    final Uint8List header = Uint8List(_headerBytes);
    header.setRange(0, 4, _magic);
    final ByteData bd = ByteData.sublistView(header);
    bd.setUint16(4, 1, Endian.little);
    bd.setUint16(6, 0, Endian.little);
    await raf.writeFrom(header);

    return FrameArchiveWriter._(file: file, raf: raf);
  }

  Future<void> append(Uint8List frameBytes) {
    if (_closed) {
      return Future<void>.error(StateError('archive writer already closed'));
    }
    _pendingWrite = _pendingWrite.then((_) async {
      final Uint8List lenBuf = Uint8List(4);
      final ByteData lenBd = ByteData.sublistView(lenBuf);
      lenBd.setUint32(0, frameBytes.length, Endian.little);
      await _raf.writeFrom(lenBuf);
      await _raf.writeFrom(frameBytes);
      frameCount++;
      payloadBytes += frameBytes.length;
    });
    return _pendingWrite;
  }

  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _pendingWrite;
    await _raf.flush();
    await _raf.close();
  }
}

class FrameArchiveReader {
  static const List<int> _magic = <int>[0x43, 0x56, 0x41, 0x52]; // CVAR

  static Stream<Uint8List> readFrames(File file) async* {
    final RandomAccessFile raf = await file.open(mode: FileMode.read);
    try {
      final Uint8List header = await raf.read(8);
      if (header.length != 8) {
        throw const FormatException('archive header truncated');
      }
      if (!_bytesEqual(header, 0, _magic)) {
        throw const FormatException('archive magic mismatch');
      }
      final ByteData headerBd = ByteData.sublistView(header);
      final int version = headerBd.getUint16(4, Endian.little);
      if (version != 1) {
        throw FormatException('unsupported archive version: $version');
      }

      while (true) {
        final Uint8List lenBuf = await raf.read(4);
        if (lenBuf.isEmpty) {
          break;
        }
        if (lenBuf.length != 4) {
          throw const FormatException('archive frame length truncated');
        }
        final ByteData lenBd = ByteData.sublistView(lenBuf);
        final int frameLen = lenBd.getUint32(0, Endian.little);
        if (frameLen <= 0 || frameLen > (32 * 1024 * 1024)) {
          throw FormatException('archive frame length invalid: $frameLen');
        }

        final Uint8List frame = await raf.read(frameLen);
        if (frame.length != frameLen) {
          throw const FormatException('archive frame payload truncated');
        }
        yield frame;
      }
    } finally {
      await raf.close();
    }
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
