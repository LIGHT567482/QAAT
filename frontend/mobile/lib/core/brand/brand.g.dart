// GENERATED FILE — DO NOT EDIT OR RUN THE FORMATTER OVER IT.
// Derived from brand.json at the repository root by scripts/brand-sync.mjs.
// Rebrand by editing ../../../../brand.json, then run: make brand

// ignore_for_file: prefer_single_quotes

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

/// Every brand colour, string and image, derived from brand.json.
///
/// The UI layer reads branding from here and nowhere else — rebranding is a
/// one-file edit followed by `make brand`.
class QaatBrand {
  QaatBrand._();

  // --- identity ----------------------------------------------------------
  static const String appName = 'QAAT';
  static const String institution = 'Kampala International University';
  static const String motto = 'Exploring the Heights';
  static const String slogan = 'Exploring the Heights';
  static const String address = '';

  // --- palette -----------------------------------------------------------
  /// Primary brand colour: buttons, accents, links.
  static const Color brandColor = Color(0xFF1A7A3F);
  /// App bar / header background.
  static const Color headerColor = Color(0xFF1A7A3F);
  /// Sidebar / bottom navigation background.
  static const Color sidebarColor = Color(0xFF1A7A3F);
  /// Footer background.
  static const Color footerColor = Color(0xFF1A7A3F);
  /// Page background.
  static const Color backgroundColor = Color(0xFFF0FDF4);
  static const Color textColorLight = Color(0xFF0F172A);
  static const Color textColorDark = Color(0xFFE5E7EB);

  // --- background image ---------------------------------------------------
  /// Empty = solid [backgroundColor]. Otherwise a data URI, an http(s) URL or
  /// an asset path — see BrandBackground, which applies the treatment below.
  static const String backgroundImage = '';
  static const double backgroundBlur = 0.0;
  static const double backgroundBrightness = 100.0;
  static const double backgroundContrast = 100.0;
  static const Color? backgroundOverlayColor =
      null;
  /// 0–100: the overlay colour's opacity as a percentage.
  static const double backgroundOverlayOpacity = 0.0;

  // --- crest / badge / logo ------------------------------------------------
  /// Materialised from brand.json's base64 by scripts/brand-sync.mjs.
  static const String logoAssetPath = 'assets/brand/crest.png';
  static const String crestAssetPath = 'assets/brand/crest.png';
  static const String badgeAssetPath = 'assets/brand/crest.png';

  static const ImageProvider logoImage = AssetImage(logoAssetPath);
  static const ImageProvider crestImage = AssetImage(crestAssetPath);
  static const ImageProvider badgeImage = AssetImage(badgeAssetPath);

  /// Raw bytes of a bundled asset — used by the brand drift test.
  static Future<Uint8List> assetBytes(String assetPath) async {
    final data = await rootBundle.load(assetPath);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }
}
