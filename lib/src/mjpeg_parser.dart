import 'dart:typed_data';

/// Splits an incoming mjpeg byte stream into standalone jpeg frames.
class MjpegFrameParser {
  MjpegFrameParser({
    required this.onFrame,
    this.maxBufferBytes = 6 * 1024 * 1024,
  });

  final void Function(Uint8List frameBytes) onFrame;
  final int maxBufferBytes;
  final List<int> _stash = <int>[];

  void addChunk(List<int> chunk) {
    if (chunk.isEmpty) {
      return;
    }
    _stash.addAll(chunk);
    _evictIfNeeded();
    _parseFrames();
  }

  void reset() {
    _stash.clear();
  }

  void _parseFrames() {
    while (_stash.length >= 4) {
      final int soi = _findMarker(0xFF, 0xD8, 0);
      if (soi < 0) {
        // Keep at most one trailing byte to allow cross-chunk marker match.
        if (_stash.length > 1) {
          _stash.removeRange(0, _stash.length - 1);
        }
        return;
      }
      if (soi > 0) {
        _stash.removeRange(0, soi);
      }
      final int eoi = _findMarker(0xFF, 0xD9, 2);
      if (eoi < 0) {
        return;
      }
      final Uint8List frame = Uint8List.fromList(_stash.sublist(0, eoi + 2));
      _stash.removeRange(0, eoi + 2);
      onFrame(frame);
    }
  }

  int _findMarker(int a, int b, int start) {
    for (int i = start; i < _stash.length - 1; i++) {
      if (_stash[i] == a && _stash[i + 1] == b) {
        return i;
      }
    }
    return -1;
  }

  void _evictIfNeeded() {
    if (_stash.length <= maxBufferBytes) {
      return;
    }
    final int keep = maxBufferBytes ~/ 2;
    _stash.removeRange(0, _stash.length - keep);
  }
}
