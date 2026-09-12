import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;

import 'net.dart';

/// The institution's identity — the same shape the backend serves at
/// `GET /api/v1/branding` and the frontends bundle as `assets/branding/brand.json`,
/// so bundled == fetched the instant the network answers. Mirrors the native app's
/// `BrandingClient.Branding`.
class Branding {
  const Branding({
    this.name = '',
    this.motto = '',
    this.logoUrl = '',
    this.brandColor = '',
    this.backgroundColor = '',
    this.sidebarColor = '',
    this.footerColor = '',
    this.textColorLight = '',
    this.textColorDark = '',
  });

  factory Branding.fromJson(Map<String, dynamic> j) => Branding(
        name: (j['name'] ?? 'QAAT') as String,
        motto: ((j['motto'] ?? j['slogan']) ?? '') as String,
        logoUrl: (j['logo_url'] ?? '') as String,
        brandColor: (j['brand_color'] ?? '') as String,
        backgroundColor: (j['background_color'] ?? '') as String,
        sidebarColor: (j['sidebar_color'] ?? '') as String,
        footerColor: (j['footer_color'] ?? '') as String,
        textColorLight: (j['text_color_light'] ?? '') as String,
        textColorDark: (j['text_color_dark'] ?? '') as String,
      );

  final String name;
  final String motto;
  final String logoUrl; // https URL or a data: base64 image
  final String brandColor; // "#RRGGBB"
  final String backgroundColor;
  final String sidebarColor; // the admin sidebar colour — app nav + header
  final String footerColor;
  final String textColorLight; // per-theme text colour set by the super-admin
  final String textColorDark;
}

/// "#RRGGBB" → [Color], or null when malformed.
Color? parseHex(String hex) {
  if (!hex.startsWith('#') || hex.length != 7) return null;
  final v = int.tryParse(hex.substring(1), radix: 16);
  if (v == null) return null;
  return Color(0xFF000000 | v);
}

/// This app's one instance of the institution identity. Mirror of `AppState.branding`:
/// the bundled default is applied instantly at startup (offline-safe) and the backend
/// override replaces it the moment a sign-in can fetch it.
class BrandingState {
  BrandingState._();

  static final ValueNotifier<Branding?> current = ValueNotifier<Branding?>(null);

  /// The bundled `assets/branding/brand.json` — instant, offline identity before any
  /// backend override. Best-effort: a missing/unparseable file keeps the app's own
  /// default green scheme.
  static Future<void> loadDefault() async {
    try {
      final raw = await rootBundle.loadString('assets/branding/brand.json');
      current.value = Branding.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {}
  }

  /// Fetch the live branding (`GET /api/v1/branding`) and adopt it. Fires after a
  /// successful sign-in. Failures are ignored — the bundled default stays.
  static Future<void> refresh(String token) async {
    try {
      final r = await http.get(
        Uri.parse('${Net.baseUrl}/api/v1/branding'),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (r.statusCode < 200 || r.statusCode >= 300) return;
      current.value =
          Branding.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
    } catch (_) {}
  }
}

/// A Material3 colour scheme that inherits the tenant's brand + background colours —
/// the same values the admin dashboards use. Light theme only.
ColorScheme brandedColorScheme(Branding? b) {
  var s = const ColorScheme.light();
  final brand = parseHex(b?.brandColor ?? '');
  if (brand != null) {
    s = s.copyWith(primary: brand, secondary: brand, tertiary: brand);
  }
  final bg = parseHex(b?.backgroundColor ?? '');
  if (bg != null) s = s.copyWith(surface: bg);
  final text = parseHex(b?.textColorLight ?? '');
  if (text != null) s = s.copyWith(onSurface: text);
  return s;
}

/// The tenant's admin-sidebar colour — tints the app's top bar so the phone chrome
/// matches the admin dashboard. Falls back to the brand colour.
Color? navBarColor(Branding? b) =>
    parseHex(b?.sidebarColor ?? '') ?? parseHex(b?.brandColor ?? '');

/// Readable content colour (white on dark chrome, near-black on light).
Color onNavColor(Color bg) =>
    bg.computeLuminance() > 0.55 ? const Color(0xFF0F172A) : Colors.white;

/// The tenant's page background colour (the admin dashboard's content background).
Color? appBackgroundColor(Branding? b) => parseHex(b?.backgroundColor ?? '');