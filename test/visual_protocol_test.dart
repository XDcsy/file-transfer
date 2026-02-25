import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:myapp/src/visual_protocol.dart';

void main() {
  test('encoder emits manifest and applies packet-level repeat', () {
    final Uint8List fileBytes = Uint8List.fromList(
      List<int>.generate(3000, (int i) => i % 251),
    );
    final TransferSession session = VisualTransferEncoder.buildSession(
      fileName: 'hello.bin',
      fileBytes: fileBytes,
      repeatCount: 2,
    );

    final int parityCount =
        (session.totalDataChunks + VisualProtocol.dataPerGroup - 1) ~/
        VisualProtocol.dataPerGroup;
    final int expectedPacketsPerLoop =
        (session.totalDataChunks + parityCount) * 2 +
        VisualProtocol.manifestPacketsPerLoop;

    expect(session.packetsPerLoop, expectedPacketsPerLoop);
    expect(session.schedule.length, expectedPacketsPerLoop);

    final List<VisualPacket> manifestPackets = session.schedule
        .where((VisualPacket p) => p.isManifest)
        .toList();
    expect(manifestPackets.length, VisualProtocol.manifestPacketsPerLoop);

    final TransferManifest? manifest = TransferManifest.unpack(
      manifestPackets.first.payload,
      transferId: manifestPackets.first.transferId,
      payloadSize: manifestPackets.first.payloadSize,
    );
    expect(manifest, isNotNull);
    expect(manifest!.totalDataChunks, session.totalDataChunks);
    expect(manifest.packetsPerLoop, session.packetsPerLoop);
    expect(manifest.repeatCount, 2);
    expect(manifest.recommendedCaptureFrames, session.recommendedCaptureFrames);
  });

  test('assembler rebuilds file while ignoring manifest packets', () {
    final Uint8List fileBytes = Uint8List.fromList(
      List<int>.generate(4096, (int i) => (i * 31) & 0xFF),
    );
    final TransferSession session = VisualTransferEncoder.buildSession(
      fileName: 'payload.dat',
      fileBytes: fileBytes,
      repeatCount: 3,
      transferId: 0x10203040,
    );

    final TransferAssembler assembler = TransferAssembler(
      transferId: session.transferId,
      totalDataChunks: session.totalDataChunks,
    );

    final VisualPacket manifestPacket = session.schedule.firstWhere(
      (VisualPacket p) => p.isManifest,
    );
    expect(assembler.accept(manifestPacket), isFalse);

    for (final VisualPacket packet in session.schedule) {
      assembler.accept(packet);
    }

    expect(assembler.isComplete, isTrue);
    final Uint8List packed = assembler.buildPackedFile()!;
    final FileEnvelope? envelope = FileEnvelope.unpack(packed);
    expect(envelope, isNotNull);
    expect(envelope!.fileName, 'payload.dat');
    expect(envelope.fileBytes, orderedEquals(fileBytes));
  });

  test('differential decoder handles low-contrast watermark samples', () {
    final TransferSession session = VisualTransferEncoder.buildSession(
      fileName: 'tiny.bin',
      fileBytes: Uint8List.fromList(
        List<int>.generate(1600, (int i) => i & 0xFF),
      ),
      repeatCount: 2,
      transferId: 0x55667788,
    );
    final VisualPacket packet = session.schedule.firstWhere(
      (VisualPacket p) => !p.isManifest,
    );
    final Uint8List frameBytes = packet.toFrameBytes();
    final List<int> bits = VisualFrameBitCodec.bytesToBits(frameBytes);
    final List<double> differential = List<double>.filled(bits.length, 0);
    for (int i = 0; i < bits.length; i++) {
      final double base = bits[i] == 1 ? 2.35 : -2.35;
      differential[i] = base + (((i % 7) - 3) * 0.06);
    }

    final DecodedVisualFrame? decoded =
        VisualFrameDecoder.decodeDifferentialSamples(differential);
    expect(decoded, isNotNull);
    expect(decoded!.packet.transferId, packet.transferId);
    expect(decoded.packet.totalDataChunks, packet.totalDataChunks);
    expect(decoded.packet.chunkIndex, packet.chunkIndex);
    expect(decoded.packet.groupIndex, packet.groupIndex);
    expect(decoded.packet.isParity, packet.isParity);
    expect(decoded.packet.isManifest, packet.isManifest);
    expect(decoded.packet.payloadSize, packet.payloadSize);
    expect(decoded.packet.payload, orderedEquals(packet.payload));
  });
}
