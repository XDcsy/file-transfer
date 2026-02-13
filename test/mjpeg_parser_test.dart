import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:myapp/src/mjpeg_parser.dart';

Uint8List _jpegFrame(List<int> body) {
  return Uint8List.fromList(<int>[0xFF, 0xD8, ...body, 0xFF, 0xD9]);
}

void main() {
  test('Mjpeg parser splits contiguous frames', () {
    final List<Uint8List> out = <Uint8List>[];
    final MjpegFrameParser parser = MjpegFrameParser(onFrame: out.add);
    final Uint8List frame1 = _jpegFrame(<int>[1, 2, 3, 4]);
    final Uint8List frame2 = _jpegFrame(<int>[5, 6, 7]);
    parser.addChunk(Uint8List.fromList(<int>[...frame1, ...frame2]));
    expect(out.length, 2);
    expect(out[0], orderedEquals(frame1));
    expect(out[1], orderedEquals(frame2));
  });

  test('Mjpeg parser handles marker across chunk boundary', () {
    final List<Uint8List> out = <Uint8List>[];
    final MjpegFrameParser parser = MjpegFrameParser(onFrame: out.add);
    parser.addChunk(<int>[0x00, 0x11, 0xFF]);
    parser.addChunk(<int>[0xD8, 0xAA, 0xBB, 0xFF]);
    parser.addChunk(<int>[0xD9, 0xFF, 0xD8, 0xEE, 0xFF, 0xD9]);
    expect(out.length, 2);
    expect(out[0], orderedEquals(<int>[0xFF, 0xD8, 0xAA, 0xBB, 0xFF, 0xD9]));
    expect(out[1], orderedEquals(<int>[0xFF, 0xD8, 0xEE, 0xFF, 0xD9]));
  });
}
