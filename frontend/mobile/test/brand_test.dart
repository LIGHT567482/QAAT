import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qaat/core/brand/brand.g.dart';

/// brand.json at the repository root is the single source of branding truth.
/// This test is the tripwire: it fails if the generated [QaatBrand] constants,
/// the bundled crest, or any screen drift away from it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // flutter test runs with the package root as CWD → ../../brand.json is the
  // canonical file every surface inherits from.
  final raw = jsonDecode(File('../../brand.json').readAsStringSync()) as Map<String, dynamic>;

  String field(String key) => (raw[key] ?? '').toString().trim();

  Color hexColor(String hex) {
    var h = hex.replaceFirst('#', '');
    if (h.length == 3) {
      h = h.split('').map((c) => '$c$c').join();
    }
    if (h.length == 6) h = 'ff$h';
    return Color(int.parse(h, radix: 16));
  }

  test('brand.g.dart inherits its identity from brand.json', () {
    expect(QaatBrand.appName, field('app_name'));
    expect(QaatBrand.institution, field('name'));
    expect(QaatBrand.motto, field('motto'));
    expect(QaatBrand.slogan, field('slogan'));
    expect(QaatBrand.address, field('address'));
  });

  test('brand.g.dart inherits its palette from brand.json', () {
    expect(QaatBrand.brandColor, hexColor(field('brand_color')));
    expect(QaatBrand.headerColor, hexColor(field('header_color')));
    expect(QaatBrand.sidebarColor, hexColor(field('sidebar_color')));
    expect(QaatBrand.footerColor, hexColor(field('footer_color')));
    expect(QaatBrand.backgroundColor, hexColor(field('background_color')));
    expect(QaatBrand.textColorLight, hexColor(field('text_color_light')));
    expect(QaatBrand.textColorDark, hexColor(field('text_color_dark')));
  });

  test('brand.g.dart inherits its background treatment from brand.json', () {
    expect(QaatBrand.backgroundImage, field('background_image'));
    expect(QaatBrand.backgroundBlur, num.parse(field('background_blur')));
    expect(QaatBrand.backgroundBrightness, num.parse(field('background_brightness')));
    expect(QaatBrand.backgroundContrast, num.parse(field('background_contrast')));
    expect(QaatBrand.backgroundOverlayOpacity, num.parse(field('background_overlay_opacity')));
    expect(
      QaatBrand.backgroundOverlayColor,
      field('background_overlay_color').isEmpty ? null : hexColor(field('background_overlay_color')),
    );
  });

  test('the bundled crest is exactly the logo in brand.json', () async {
    final source = field('logo_url');
    expect(source, startsWith('data:image/'),
        reason: 'set logo_url to a base64 data URI in brand.json');

    final declared = base64Decode(source.split(',').last);
    final bundled = await QaatBrand.assetBytes(QaatBrand.crestAssetPath);

    expect(bundled, declared,
        reason: 'run `make brand` — the bundled crest no longer matches brand.json');
    // PNG magic, so a corrupt asset fails here rather than as a blank image.
    expect(bundled.sublist(0, 8), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  });

  test('no screen hardcodes a brand colour', () {
    // Hex literals belong in brand.json only. brand.g.dart is the generated
    // output; brand_background.dart only handles brand.json's own numbers.
    final allowed = {
      'lib/core/brand/brand.g.dart',
      'lib/core/brand/brand_background.dart',
    };
    final hex = RegExp(r'#[0-9a-fA-F]{3,8}\b');
    final offenders = <String>[];

    for (final entry in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      final rel = entry.path.replaceFirst('${Directory.current.path}/', '');
      if (allowed.contains(rel)) continue;
      final matches = hex.allMatches(entry.readAsStringSync()).map((m) => m.group(0)).toList();
      if (matches.isNotEmpty) offenders.add('$rel → ${matches.join(', ')}');
    }

    expect(offenders, isEmpty,
        reason: 'move these to brand.json and regenerate with `make brand`:\n'
            '${offenders.join('\n')}');
  });
}
