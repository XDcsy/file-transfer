import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:myapp/src/frame_archive.dart';

void main() {
  test('frame archive round-trip', () async {
    final Directory dir = await Directory.systemTemp.createTemp('cvt_archive');
    try {
      final File archive = File(
        '${dir.path}${Platform.pathSeparator}frames.cvar',
      );
      final FrameArchiveWriter writer = await FrameArchiveWriter.create(
        archive,
      );
      final Uint8List frame1 = Uint8List.fromList(<int>[1, 2, 3, 4]);
      final Uint8List frame2 = Uint8List.fromList(<int>[0xFF, 0xD8, 9, 8, 7]);
      await writer.append(frame1);
      await writer.append(frame2);
      await writer.close();

      final List<Uint8List> out = await FrameArchiveReader.readFrames(
        archive,
      ).toList();
      expect(out.length, 2);
      expect(out[0], orderedEquals(frame1));
      expect(out[1], orderedEquals(frame2));
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('frame archive detects invalid magic', () async {
    final Directory dir = await Directory.systemTemp.createTemp(
      'cvt_archive_bad',
    );
    try {
      final File archive = File('${dir.path}${Platform.pathSeparator}bad.cvar');
      await archive.writeAsBytes(<int>[1, 2, 3, 4, 0, 0, 0, 0], flush: true);
      await expectLater(
        FrameArchiveReader.readFrames(archive).toList(),
        throwsA(isA<FormatException>()),
      );
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
