import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'brand.g.dart';

/// The brand background: [QaatBrand.backgroundColor] plus, when
/// [QaatBrand.backgroundImage] is set, the image carrying the brand's blur /
/// brightness / contrast treatment and optional colour overlay.
///
/// Every screen body sits inside this, so the background is configured in
/// exactly one place — brand.json.
class BrandBackground extends StatelessWidget {
  const BrandBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    const overlay = QaatBrand.backgroundOverlayColor;
    const overlayOpacity = QaatBrand.backgroundOverlayOpacity;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        const ColoredBox(color: QaatBrand.backgroundColor),
        if (QaatBrand.backgroundImage.isNotEmpty)
          const Positioned.fill(child: _BrandImage()),
        if (overlay != null && overlayOpacity > 0)
          Positioned.fill(
            child: ColoredBox(color: overlay.withAlpha((255 * overlayOpacity / 100).round())),
          ),
        Positioned.fill(child: child),
      ],
    );
  }
}

class _BrandImage extends StatelessWidget {
  const _BrandImage();

  static Uint8List _decodeDataUri(String uri) {
    final payload = uri.substring(uri.indexOf(',') + 1).replaceAll(RegExp(r'\s'), '');
    return base64Decode(payload);
  }

  ImageProvider get _provider {
    const source = QaatBrand.backgroundImage;
    if (source.startsWith('http://') || source.startsWith('https://')) {
      return const NetworkImage(source);
    }
    if (source.startsWith('data:image/')) {
      // Runtime decode of the brand's base64 — cannot be const.
      return MemoryImage(_decodeDataUri(source)); // ignore: prefer_const_constructors
    }
    return const AssetImage(source);
  }

  @override
  Widget build(BuildContext context) {
    // 100/100 is the identity — the same numbers the web surface feeds to the
    // CSS `filter` property.
    const contrast = QaatBrand.backgroundContrast / 100;
    const brightness = QaatBrand.backgroundBrightness / 100;
    const shift = (1 - contrast) * 128 + (brightness - 1) * 255;

    Widget image = Image(
      image: _provider,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
    );

    if (contrast != 1 || brightness != 1) {
      image = _withColorFilter(
        image,
        const ColorFilter.matrix(<double>[
          contrast, 0, 0, 0, shift,
          0, contrast, 0, 0, shift,
          0, 0, contrast, 0, shift,
          0, 0, 0, 1, 0,
        ]),
      );
    }

    const blur = QaatBrand.backgroundBlur;
    if (blur > 0) {
      image = ImageFiltered(
        imageFilter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: image,
      );
    }

    return image;
  }

  /// Wraps [child] in a ColorFiltered. A helper, because the wrapper's
  /// argument is the runtime-built image above.
  static Widget _withColorFilter(Widget child, ColorFilter filter) =>
      ColorFiltered(colorFilter: filter, child: child);
}

/// The branded bottom strip: app name · motto · address, on
/// [QaatBrand.footerColor]. Used wherever a screen has room for a footer.
class BrandFooter extends StatelessWidget {
  const BrandFooter({super.key});

  @override
  Widget build(BuildContext context) {
    final parts = <String>[QaatBrand.institution, QaatBrand.appName];
    if (QaatBrand.motto.isNotEmpty) parts.add(QaatBrand.motto);
    if (QaatBrand.address.isNotEmpty) parts.add(QaatBrand.address);
    return ColoredBox(
      color: QaatBrand.footerColor,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Text(
            parts.join(' · '),
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 11,
              color: QaatBrand.textColorDark,
              letterSpacing: 0.2,
            ),
          ),
        ),
      ),
    );
  }
}

/// The crest, sized for an app bar or a login header.
class BrandCrest extends StatelessWidget {
  const BrandCrest({super.key, this.size = 56});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Image(
      image: QaatBrand.crestImage,
      width: size,
      height: size,
      fit: BoxFit.contain,
      errorBuilder: (_, __, ___) =>
          Icon(Icons.school_outlined, size: size, color: QaatBrand.brandColor),
    );
  }
}
