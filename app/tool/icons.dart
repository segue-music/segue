// Makes the app's icons from tool/icon.png, the artwork: a red rounded square on a near-black background. Run it from
// app/ after changing the artwork: DART=1 tool/flutter.sh run tool/icons.dart
//
// - Android: the launcher icon, adaptive (Android 8 and later, mipmap-anydpi-v26/ic_launcher.xml) and as a plain image
//   before that, and the Android TV banner.
// - Linux: the window's icon, also the one of the menu entry that install-desktop-entry.sh adds.
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart';

/// The rounded square in the artwork, in its pixels, and how far the note reaches from the square's centre (the tip of
/// its top flag), as measured on it. A new artwork needs these measured again.
const _left = 140.0, _top = 137.0, _right = 1112.0, _bottom = 1085.0, _radius = 200.0, _note = 450.0;

const _res = 'android/app/src/main/res';

/// Android's densities, as pixels per dp.
const _densities = {'mdpi': 1.0, 'hdpi': 1.5, 'xhdpi': 2.0, 'xxhdpi': 3.0, 'xxxhdpi': 4.0};

void main() {
  final art = _Artwork(decodePng(File('tool/icon.png').readAsBytesSync())!);
  for (final MapEntry(key: density, value: scale) in _densities.entries) {
    // Before Android 8: the rounded square as it is, at the size of the square icons in the 48 dp grid (40 dp).
    _write('$_res/mipmap-$density/ic_launcher.png', art.shape((48 * scale).round(), 40 / 48));
    // Android 8 and later: the launcher cuts the icon to its own shape (a circle, a squircle...), so the foreground
    // layer, 108 dp of which 72 dp show, is the inside of the square without its edge, stretched to the layer's
    // borders. The note fits in the 66 dp circle that every shape keeps.
    _write('$_res/mipmap-$density/ic_launcher_foreground.png', art.inside((108 * scale).round(), 66 / 108));
  }
  // The Android TV banner, 320 × 180 dp: the artwork with its glow, on its own background.
  _write('$_res/drawable-xhdpi/banner.png', art.banner(640, 360));
  _write('linux/runner/resources/app_icon.png', art.shape(256, 0.84));
}

void _write(String path, Image image) {
  File(path)
    ..createSync(recursive: true)
    ..writeAsBytesSync(encodePng(image, level: 9));
  stdout.writeln(path);
}

/// A colour with its alpha, straight (not premultiplied), each channel from 0 to 1.
typedef _Rgba = (double, double, double, double);

class _Artwork {
  _Artwork(Image image)
    : width = image.width,
      height = image.height,
      _rgb = image.convert(numChannels: 3).getBytes(order: ChannelOrder.rgb);

  final int width, height;
  final Uint8List _rgb;

  static const _cx = (_left + _right) / 2, _cy = (_top + _bottom) / 2;

  /// The rounded square alone, with what is around it transparent, [fill] of a [size] × [size] image wide.
  Image shape(int size, double fill) {
    final scale = max(_right - _left, _bottom - _top) / (size * fill);
    return _render(size, size, scale, (x, y) {
      final (r, g, b) = _sample(x, y);
      return (r, g, b, _inside(x, y) ? 1 : 0);
    });
  }

  /// The inside of the rounded square, 16 px from its edge, carried on to the image's borders by repeating that edge
  /// outwards: opaque, with nothing of the square's shape left. [fill] is how much of the image the note takes.
  Image inside(int size, double fill) {
    const inset = 16.0;
    final scale = 2 * _note / (size * fill);
    return _render(size, size, scale, (x, y) {
      final (px, py) = _nearestInside(x, y, inset);
      final (r, g, b) = _sample(px, py);
      return (r, g, b, 1);
    });
  }

  /// The whole artwork, as tall as the image, on the colour of its borders.
  Image banner(int width, int height) {
    final (br, bg, bb) = _borderColour();
    final scale = this.height / height;
    return _render(width, height, scale, (x, y) {
      if (x < 0 || x > this.width || y < 0 || y > this.height) return (br, bg, bb, 1);
      final (r, g, b) = _sample(x, y);
      return (r, g, b, 1);
    });
  }

  /// A width × height image centred on the rounded square, each pixel [scale] artwork pixels wide. [paint] gives the
  /// colour at a point of the artwork; each pixel averages it over a grid of points at least as fine as the artwork's.
  Image _render(int width, int height, double scale, _Rgba Function(double x, double y) paint) {
    final n = max(1, scale.ceil());
    final image = Image(width: width, height: height, numChannels: 4);
    final x0 = _cx - width * scale / 2, y0 = _cy - height * scale / 2;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        var r = 0.0, g = 0.0, b = 0.0, a = 0.0;
        for (var j = 0; j < n; j++) {
          for (var i = 0; i < n; i++) {
            final (pr, pg, pb, pa) = paint(x0 + (x + (i + 0.5) / n) * scale, y0 + (y + (j + 0.5) / n) * scale);
            r += pr * pa;
            g += pg * pa;
            b += pb * pa;
            a += pa;
          }
        }
        // Averaged premultiplied, so the transparent pixels around the shape don't darken its edge.
        if (a > 0) image.setPixelRgba(x, y, 255 * r / a, 255 * g / a, 255 * b / a, 255 * a / (n * n));
      }
    }
    return image;
  }

  /// The artwork's colour at (x, y), between its pixels' centres.
  (double, double, double) _sample(double x, double y) {
    final fx = (x - 0.5).clamp(0.0, width - 1.0), fy = (y - 0.5).clamp(0.0, height - 1.0);
    final x0 = fx.floor(), y0 = fy.floor();
    final x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1);
    final tx = fx - x0, ty = fy - y0;
    double channel(int c) {
      double at(int x, int y) => _rgb[(y * width + x) * 3 + c] / 255;
      final top = at(x0, y0) * (1 - tx) + at(x1, y0) * tx;
      final bottom = at(x0, y1) * (1 - tx) + at(x1, y1) * tx;
      return top * (1 - ty) + bottom * ty;
    }

    return (channel(0), channel(1), channel(2));
  }

  /// The mean colour of the artwork's outermost pixels.
  (double, double, double) _borderColour() {
    var r = 0.0, g = 0.0, b = 0.0, n = 0;
    void add(int x, int y) {
      final i = (y * width + x) * 3;
      r += _rgb[i];
      g += _rgb[i + 1];
      b += _rgb[i + 2];
      n++;
    }

    for (var x = 0; x < width; x++) {
      add(x, 0);
      add(x, height - 1);
    }
    for (var y = 1; y < height - 1; y++) {
      add(0, y);
      add(width - 1, y);
    }
    return (r / n / 255, g / n / 255, b / n / 255);
  }

  /// Whether (x, y) is in the rounded square.
  static bool _inside(double x, double y) => _nearestInside(x, y, 0) == (x, y);

  /// The point of the rounded square shrunk by [inset] nearest to (x, y): (x, y) itself when it is inside.
  static (double, double) _nearestInside(double x, double y, double inset) {
    final radius = _radius - inset;
    // The rectangle of the corners' centres; the shape is every point within [radius] of it.
    final kx = (_right - _left) / 2 - inset - radius, ky = (_bottom - _top) / 2 - inset - radius;
    final qx = (x - _cx).clamp(-kx, kx), qy = (y - _cy).clamp(-ky, ky);
    final dx = x - _cx - qx, dy = y - _cy - qy;
    final distance = sqrt(dx * dx + dy * dy);
    if (distance <= radius) return (x, y);
    return (_cx + qx + dx * radius / distance, _cy + qy + dy * radius / distance);
  }
}
