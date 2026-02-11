import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'visual_protocol.dart';

class VisualFrameGeometry {
  const VisualFrameGeometry({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.cellWidth,
    required this.cellHeight,
  });

  final double left;
  final double top;
  final double width;
  final double height;
  final double cellWidth;
  final double cellHeight;

  static VisualFrameGeometry fromSize(Size size) {
    const double horizontalUsage = 0.90;
    const double verticalUsage = 0.80;
    final double maxW = size.width * horizontalUsage;
    final double maxH = size.height * verticalUsage;
    final double targetAspect =
        VisualProtocol.gridCols / VisualProtocol.gridRows;

    double regionW = maxW;
    double regionH = maxW / targetAspect;
    if (regionH > maxH) {
      regionH = maxH;
      regionW = maxH * targetAspect;
    }

    final double left = (size.width - regionW) / 2;
    final double top = (size.height - regionH) / 2;
    return VisualFrameGeometry(
      left: left,
      top: top,
      width: regionW,
      height: regionH,
      cellWidth: regionW / VisualProtocol.gridCols,
      cellHeight: regionH / VisualProtocol.gridRows,
    );
  }
}

class VisualFramePainter extends CustomPainter {
  VisualFramePainter({required this.frameBytes, required this.subtitle})
    : _bits = VisualFrameBitCodec.bytesToBits(frameBytes);

  final Uint8List frameBytes;
  final String subtitle;
  final List<int> _bits;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint bg = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: <Color>[Color(0xFF111215), Color(0xFF060708)],
      ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, bg);

    final VisualFrameGeometry g = VisualFrameGeometry.fromSize(size);
    final Rect region = Rect.fromLTWH(g.left, g.top, g.width, g.height);
    final Paint white = Paint()..color = const Color(0xFFF4F5F6);
    final Paint black = Paint()..color = const Color(0xFF060606);
    final Paint border = Paint()
      ..color = const Color(0xFFECEFF1)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawRect(region.inflate(12), white);
    canvas.drawRect(region.inflate(12), border);

    int bitIndex = 0;
    for (int r = 0; r < VisualProtocol.gridRows; r++) {
      for (int c = 0; c < VisualProtocol.gridCols; c++) {
        final bool isOne = _bits[bitIndex++] == 1;
        final Rect cell = Rect.fromLTWH(
          g.left + c * g.cellWidth,
          g.top + r * g.cellHeight,
          g.cellWidth + 0.4,
          g.cellHeight + 0.4,
        );
        canvas.drawRect(cell, isOne ? black : white);
      }
    }

    final TextPainter tp = TextPainter(
      textDirection: TextDirection.ltr,
      text: TextSpan(
        text: subtitle,
        style: const TextStyle(
          color: Color(0xFFECEFF1),
          fontSize: 15,
          letterSpacing: 0.2,
          fontWeight: FontWeight.w600,
        ),
      ),
    )..layout(maxWidth: size.width - 24);
    tp.paint(canvas, Offset(12, size.height - tp.height - 10));
  }

  @override
  bool shouldRepaint(covariant VisualFramePainter oldDelegate) {
    if (oldDelegate.subtitle != subtitle) {
      return true;
    }
    if (oldDelegate.frameBytes.length != frameBytes.length) {
      return true;
    }
    for (int i = 0; i < frameBytes.length; i++) {
      if (oldDelegate.frameBytes[i] != frameBytes[i]) {
        return true;
      }
    }
    return false;
  }
}

class VisualFrameSampler {
  static Future<List<double>?> sampleLuma(Uint8List encodedImageBytes) async {
    try {
      final ui.Codec codec = await ui.instantiateImageCodec(encodedImageBytes);
      final ui.FrameInfo frame = await codec.getNextFrame();
      final ui.Image image = frame.image;
      final ByteData? raw = await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      if (raw == null) {
        return null;
      }
      return _sampleFromRaw(
        rawRgba: raw,
        width: image.width,
        height: image.height,
      );
    } catch (_) {
      return null;
    }
  }

  static List<double> _sampleFromRaw({
    required ByteData rawRgba,
    required int width,
    required int height,
  }) {
    final Size size = Size(width.toDouble(), height.toDouble());
    final VisualFrameGeometry g = VisualFrameGeometry.fromSize(size);
    final List<double> samples = List<double>.filled(
      VisualProtocol.gridCols * VisualProtocol.gridRows,
      0.0,
      growable: false,
    );

    int sampleIndex = 0;
    for (int r = 0; r < VisualProtocol.gridRows; r++) {
      final double y = g.top + (r + 0.5) * g.cellHeight;
      final int py = y.clamp(0, height - 1).toInt();
      for (int c = 0; c < VisualProtocol.gridCols; c++) {
        final double x = g.left + (c + 0.5) * g.cellWidth;
        final int px = x.clamp(0, width - 1).toInt();
        final int offset = ((py * width) + px) * 4;
        final int r8 = rawRgba.getUint8(offset);
        final int g8 = rawRgba.getUint8(offset + 1);
        final int b8 = rawRgba.getUint8(offset + 2);
        final double luma = (0.2126 * r8) + (0.7152 * g8) + (0.0722 * b8);
        samples[sampleIndex++] = luma;
      }
    }
    return samples;
  }
}
