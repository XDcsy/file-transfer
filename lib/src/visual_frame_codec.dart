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

  Rect toRect() => Rect.fromLTWH(left, top, width, height);

  Rect toNormalizedRect(Size size) {
    if (size.width <= 0 || size.height <= 0) {
      return Rect.zero;
    }
    return Rect.fromLTWH(
      left / size.width,
      top / size.height,
      width / size.width,
      height / size.height,
    );
  }

  static VisualFrameGeometry fromSize(Size size) {
    const double horizontalUsage = 0.97;
    const double verticalUsage = 0.94;
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

  static VisualFrameGeometry fromCenterAndWidthFraction({
    required Size size,
    required double centerXFraction,
    required double centerYFraction,
    required double widthFraction,
  }) {
    final double targetAspect =
        VisualProtocol.gridCols / VisualProtocol.gridRows;
    double regionW = size.width * widthFraction;
    double regionH = regionW / targetAspect;
    if (regionH > size.height) {
      regionH = size.height;
      regionW = regionH * targetAspect;
    }

    final double centerX = size.width * centerXFraction;
    final double centerY = size.height * centerYFraction;
    double left = centerX - regionW / 2;
    double top = centerY - regionH / 2;
    left = left.clamp(0, size.width - regionW);
    top = top.clamp(0, size.height - regionH);
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
      ..strokeWidth = 1.2
      ..isAntiAlias = false;
    canvas.drawRect(region, white);
    canvas.drawRect(region, border);

    int bitIndex = 0;
    for (int r = 0; r < VisualProtocol.gridRows; r++) {
      for (int c = 0; c < VisualProtocol.gridCols; c++) {
        final bool isOne = _bits[bitIndex++] == 1;
        final Rect cell = Rect.fromLTWH(
          g.left + c * g.cellWidth,
          g.top + r * g.cellHeight,
          g.cellWidth,
          g.cellHeight,
        );
        canvas.drawRect(cell, isOne ? black : white);
      }
    }

    if (subtitle.isEmpty) {
      return;
    }
    final TextPainter tp = TextPainter(
      textDirection: TextDirection.ltr,
      text: TextSpan(
        text: subtitle,
        style: const TextStyle(
          color: Color(0xFFCBD5E1),
          fontSize: 12,
          letterSpacing: 0.1,
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

class DecodedFrameCandidate {
  const DecodedFrameCandidate({
    required this.decoded,
    required this.geometry,
    required this.sourceWidth,
    required this.sourceHeight,
  });

  final DecodedVisualFrame decoded;
  final VisualFrameGeometry geometry;
  final int sourceWidth;
  final int sourceHeight;
}

class VisualFrameSampler {
  static Future<DecodedFrameCandidate?> decodeAtHint(
    Uint8List encodedImageBytes, {
    required double centerXFraction,
    required double centerYFraction,
    required double widthFraction,
  }) async {
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
      final Size size = Size(image.width.toDouble(), image.height.toDouble());
      final VisualFrameGeometry geometry =
          VisualFrameGeometry.fromCenterAndWidthFraction(
            size: size,
            centerXFraction: centerXFraction,
            centerYFraction: centerYFraction,
            widthFraction: widthFraction,
          );
      return _tryDecodeGeometry(
        rawRgba: raw,
        width: image.width,
        height: image.height,
        geometry: geometry,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<DecodedFrameCandidate?> decodeAtNormalizedRect(
    Uint8List encodedImageBytes,
    Rect normalizedRect,
  ) async {
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
      final Size size = Size(image.width.toDouble(), image.height.toDouble());
      final VisualFrameGeometry geometry = _geometryFromNormalizedRect(
        size,
        normalizedRect,
      );
      return _tryDecodeGeometry(
        rawRgba: raw,
        width: image.width,
        height: image.height,
        geometry: geometry,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<DecodedFrameCandidate?> decodeBestFrame(
    Uint8List encodedImageBytes,
  ) async {
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
      return _decodeFromRaw(
        rawRgba: raw,
        width: image.width,
        height: image.height,
      );
    } catch (_) {
      return null;
    }
  }

  static DecodedFrameCandidate? _decodeFromRaw({
    required ByteData rawRgba,
    required int width,
    required int height,
  }) {
    final Size size = Size(width.toDouble(), height.toDouble());
    final List<VisualFrameGeometry> primary = <VisualFrameGeometry>[
      VisualFrameGeometry.fromSize(size),
      VisualFrameGeometry.fromCenterAndWidthFraction(
        size: size,
        centerXFraction: 0.5,
        centerYFraction: 0.5,
        widthFraction: 0.82,
      ),
      VisualFrameGeometry.fromCenterAndWidthFraction(
        size: size,
        centerXFraction: 0.5,
        centerYFraction: 0.5,
        widthFraction: 0.72,
      ),
    ];
    for (final VisualFrameGeometry geometry in primary) {
      final DecodedFrameCandidate? decoded = _tryDecodeGeometry(
        rawRgba: rawRgba,
        width: width,
        height: height,
        geometry: geometry,
      );
      if (decoded != null) {
        return decoded;
      }
    }

    final List<VisualFrameGeometry> rough = _candidateGeometries(size);
    final List<_GeometryScore> scored =
        rough
            .map(
              (VisualFrameGeometry g) => _GeometryScore(
                geometry: g,
                score: _geometryContrastScore(
                  rawRgba: rawRgba,
                  width: width,
                  height: height,
                  geometry: g,
                ),
              ),
            )
            .toList()
          ..sort((a, b) => b.score.compareTo(a.score));

    final int topCount = scored.length < 10 ? scored.length : 10;
    for (int i = 0; i < topCount; i++) {
      final VisualFrameGeometry base = scored[i].geometry;
      for (final VisualFrameGeometry geometry in _refinedGeometries(
        base,
        size,
      )) {
        final DecodedFrameCandidate? decoded = _tryDecodeGeometry(
          rawRgba: rawRgba,
          width: width,
          height: height,
          geometry: geometry,
        );
        if (decoded != null) {
          return decoded;
        }
      }
    }
    return null;
  }

  static DecodedFrameCandidate? _tryDecodeGeometry({
    required ByteData rawRgba,
    required int width,
    required int height,
    required VisualFrameGeometry geometry,
  }) {
    final List<List<double>> sampleSets = <List<double>>[
      _sampleFromRawWithGeometry(
        rawRgba: rawRgba,
        width: width,
        height: height,
        geometry: geometry,
      ),
      _sampleFromRawWithNestedGeometry(
        rawRgba: rawRgba,
        width: width,
        height: height,
        outer: geometry,
      ),
    ];
    for (final List<double> samples in sampleSets) {
      final DecodedVisualFrame? decoded = VisualFrameDecoder.decodeLumaSamples(
        samples,
      );
      if (decoded != null) {
        return DecodedFrameCandidate(
          decoded: decoded,
          geometry: geometry,
          sourceWidth: width,
          sourceHeight: height,
        );
      }
    }
    return null;
  }

  static VisualFrameGeometry _geometryFromNormalizedRect(
    Size size,
    Rect normalizedRect,
  ) {
    double left = normalizedRect.left * size.width;
    double top = normalizedRect.top * size.height;
    double width = normalizedRect.width * size.width;
    double height = normalizedRect.height * size.height;
    width = width.clamp(8, size.width);
    height = height.clamp(8, size.height);
    left = left.clamp(0, size.width - width);
    top = top.clamp(0, size.height - height);
    return VisualFrameGeometry(
      left: left,
      top: top,
      width: width,
      height: height,
      cellWidth: width / VisualProtocol.gridCols,
      cellHeight: height / VisualProtocol.gridRows,
    );
  }

  static List<VisualFrameGeometry> _candidateGeometries(Size size) {
    final List<VisualFrameGeometry> list = <VisualFrameGeometry>[
      VisualFrameGeometry.fromSize(size),
    ];

    for (final double w in <double>[0.92, 0.82, 0.72, 0.62]) {
      list.add(
        VisualFrameGeometry.fromCenterAndWidthFraction(
          size: size,
          centerXFraction: 0.5,
          centerYFraction: 0.5,
          widthFraction: w,
        ),
      );
    }

    const List<double> widths = <double>[0.56, 0.48, 0.40, 0.33, 0.28, 0.24];
    const List<double> xCenters = <double>[0.22, 0.32, 0.42, 0.52, 0.62, 0.72];
    const List<double> yCenters = <double>[0.22, 0.32, 0.42, 0.52, 0.62, 0.72];

    for (final double w in widths) {
      for (final double x in xCenters) {
        for (final double y in yCenters) {
          list.add(
            VisualFrameGeometry.fromCenterAndWidthFraction(
              size: size,
              centerXFraction: x,
              centerYFraction: y,
              widthFraction: w,
            ),
          );
        }
      }
    }
    return list;
  }

  static List<VisualFrameGeometry> _refinedGeometries(
    VisualFrameGeometry base,
    Size size,
  ) {
    final List<VisualFrameGeometry> out = <VisualFrameGeometry>[];
    for (final double scale in <double>[1.00, 0.88, 0.76]) {
      for (final double dx in <double>[-0.14, 0.0, 0.14]) {
        for (final double dy in <double>[-0.18, -0.06, 0.06, 0.18]) {
          out.add(_scaledShiftedGeometry(base, size, scale, dx, dy));
        }
      }
    }
    return out;
  }

  static VisualFrameGeometry _scaledShiftedGeometry(
    VisualFrameGeometry base,
    Size size,
    double scale,
    double dx,
    double dy,
  ) {
    final double w = base.width * scale;
    final double h = base.height * scale;
    final double cx = base.left + base.width / 2 + dx * base.width;
    final double cy = base.top + base.height / 2 + dy * base.height;
    double left = cx - w / 2;
    double top = cy - h / 2;
    left = left.clamp(0, size.width - w);
    top = top.clamp(0, size.height - h);
    return VisualFrameGeometry(
      left: left,
      top: top,
      width: w,
      height: h,
      cellWidth: w / VisualProtocol.gridCols,
      cellHeight: h / VisualProtocol.gridRows,
    );
  }

  static double _geometryContrastScore({
    required ByteData rawRgba,
    required int width,
    required int height,
    required VisualFrameGeometry geometry,
  }) {
    const int cols = 12;
    const int rows = 8;
    double sum = 0;
    double sumSq = 0;
    int count = 0;
    for (int r = 0; r < rows; r++) {
      final double y = geometry.top + ((r + 0.5) / rows) * geometry.height;
      final int py = y.clamp(0, height - 1).toInt();
      for (int c = 0; c < cols; c++) {
        final double x = geometry.left + ((c + 0.5) / cols) * geometry.width;
        final int px = x.clamp(0, width - 1).toInt();
        final int offset = ((py * width) + px) * 4;
        final int r8 = rawRgba.getUint8(offset);
        final int g8 = rawRgba.getUint8(offset + 1);
        final int b8 = rawRgba.getUint8(offset + 2);
        final double luma = (0.2126 * r8) + (0.7152 * g8) + (0.0722 * b8);
        sum += luma;
        sumSq += luma * luma;
        count++;
      }
    }
    if (count == 0) {
      return 0;
    }
    final double mean = sum / count;
    final double variance = (sumSq / count) - (mean * mean);
    return variance < 0 ? 0 : variance;
  }

  static List<double> _sampleFromRawWithGeometry({
    required ByteData rawRgba,
    required int width,
    required int height,
    required VisualFrameGeometry geometry,
  }) {
    final List<double> samples = List<double>.filled(
      VisualProtocol.gridCols * VisualProtocol.gridRows,
      0.0,
      growable: false,
    );

    int sampleIndex = 0;
    for (int r = 0; r < VisualProtocol.gridRows; r++) {
      for (int c = 0; c < VisualProtocol.gridCols; c++) {
        double lumaAcc = 0;
        int lumaCount = 0;
        for (final double oy in <double>[0.30, 0.50, 0.70]) {
          final double y = geometry.top + (r + oy) * geometry.cellHeight;
          final int py = y.clamp(0, height - 1).toInt();
          for (final double ox in <double>[0.30, 0.50, 0.70]) {
            final double x = geometry.left + (c + ox) * geometry.cellWidth;
            final int px = x.clamp(0, width - 1).toInt();
            final int offset = ((py * width) + px) * 4;
            final int r8 = rawRgba.getUint8(offset);
            final int g8 = rawRgba.getUint8(offset + 1);
            final int b8 = rawRgba.getUint8(offset + 2);
            lumaAcc += (0.2126 * r8) + (0.7152 * g8) + (0.0722 * b8);
            lumaCount++;
          }
        }
        samples[sampleIndex++] = lumaAcc / lumaCount;
      }
    }
    return samples;
  }

  static List<double> _sampleFromRawWithNestedGeometry({
    required ByteData rawRgba,
    required int width,
    required int height,
    required VisualFrameGeometry outer,
  }) {
    final VisualFrameGeometry inner = VisualFrameGeometry.fromSize(
      Size(outer.width, outer.height),
    );
    final VisualFrameGeometry mapped = VisualFrameGeometry(
      left: outer.left + inner.left,
      top: outer.top + inner.top,
      width: inner.width,
      height: inner.height,
      cellWidth: inner.width / VisualProtocol.gridCols,
      cellHeight: inner.height / VisualProtocol.gridRows,
    );
    return _sampleFromRawWithGeometry(
      rawRgba: rawRgba,
      width: width,
      height: height,
      geometry: mapped,
    );
  }
}

class _GeometryScore {
  const _GeometryScore({required this.geometry, required this.score});

  final VisualFrameGeometry geometry;
  final double score;
}
