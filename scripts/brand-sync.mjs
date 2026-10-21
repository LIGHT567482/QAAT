#!/usr/bin/env node
// brand-sync — brand.json at the repository root is the SINGLE source of
// branding truth. Every crest, colour, background and brand string on every
// surface is derived from it by this script; no UI code hardcodes branding.
//
//   brand.json  ──►  frontend/web/lib/brand.json                imported by the app
//              ──►  frontend/web/public/brand/{crest,badge}.png favicon + <img>
//              ──►  frontend/mobile/assets/brand/*.png          Flutter image assets
//              ──►  frontend/mobile/lib/core/brand/brand.g.dart typed Dart consts
//
// Usage:
//   node scripts/brand-sync.mjs           regenerate the derived files
//   node scripts/brand-sync.mjs --check   exit 1 if anything drifted
//
// `make brand` / `make brand-check` wrap these. Derived files are committed so
// a fresh clone builds without running this, and `make test` runs --check so
// drift cannot survive a PR.

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const checkOnly = process.argv.includes("--check");

// ---------------------------------------------------------------------------
// read + validate
// ---------------------------------------------------------------------------

const errors = [];
const fail = (m) => errors.push(m);

let raw;
try {
  raw = JSON.parse(readFileSync(join(repoRoot, "brand.json"), "utf8"));
} catch (e) {
  console.error(`brand.json: ${e.message}`);
  process.exit(1);
}

const HEX = /^#(?:[0-9a-f]{3}|[0-9a-f]{6}|[0-9a-f]{8})$/i;

const str = (key, fallback = "") => {
  const v = raw[key];
  if (v === undefined || v === null) return fallback;
  if (typeof v !== "string") {
    fail(`${key} must be a string, got ${typeof v}`);
    return fallback;
  }
  return v.trim();
};

const color = (key, fallback = "") => {
  const v = str(key, fallback);
  if (v === "") return "";
  if (!HEX.test(v)) {
    fail(`${key} = "${v}" is not a #rgb / #rrggbb / #rrggbbaa colour`);
    return fallback;
  }
  return v.toLowerCase();
};

const num = (key, fallback, min, max) => {
  const v = raw[key];
  if (v === undefined || v === null || v === "") return fallback;
  const n = Number(v);
  if (!Number.isFinite(n)) {
    fail(`${key} = ${JSON.stringify(v)} is not a number`);
    return fallback;
  }
  if (n < min || n > max) {
    fail(`${key} = ${n} is outside ${min}..${max}`);
    return fallback;
  }
  return n;
};

// An image may be a base64 data: URI, an http(s) URL, or an absolute path
// served from web/public.
const image = (key) => {
  const v = str(key);
  if (v === "") return "";
  if (v.startsWith("data:image/")) return v;
  if (/^https?:\/\//i.test(v)) return v;
  if (v.startsWith("/")) return v;
  fail(`${key} must be a data:image/... URI, an http(s) URL, or an absolute /path`);
  return "";
};

const MAGIC = [
  ["png", "89504e47"],
  ["jpeg", "ffd8ff"],
  ["gif", "47494638"],
];

const dataUriBytes = (value, key) => {
  const m = /^data:image\/([a-z0-9.+-]+);base64,([\s\S]*)$/i.exec(value);
  if (!m) {
    fail(`${key} is not a base64 data:image/... URI`);
    return Buffer.alloc(0);
  }
  const bytes = Buffer.from(m[2].replace(/\s+/g, ""), "base64");
  if (bytes.length === 0) {
    fail(`${key} decoded to zero bytes`);
    return Buffer.alloc(0);
  }
  const kind = m[1].toLowerCase().replace("jpg", "jpeg");
  const magic = MAGIC.find(([k]) => k === kind);
  if (magic && !bytes.subarray(0, magic[1].length / 2).equals(Buffer.from(magic[1], "hex"))) {
    fail(`${key} declares image/${kind} but the payload does not start with its magic bytes`);
    return Buffer.alloc(0);
  }
  return bytes;
};

// ---------------------------------------------------------------------------
// resolve (applying the fallbacks consumers would otherwise repeat)
// ---------------------------------------------------------------------------

const appName = str("app_name", "QAAT");
const institution = str("name");
const motto = str("motto");
const slogan = str("slogan", motto);
const address = str("address");

const logo = image("logo_url");
const crest = image("crest_url") || logo;
const badge = image("badge_url") || crest;

const brandColor = color("brand_color", "#1a7a3f");
const headerColor = color("header_color", brandColor) || brandColor;
const sidebarColor = color("sidebar_color", brandColor) || brandColor;
const footerColor = color("footer_color", brandColor) || brandColor;
const backgroundColor = color("background_color", "#ffffff");
const textLight = color("text_color_light", "#0f172a");
const textDark = color("text_color_dark", "#e5e7eb");
const backgroundImage = image("background_image");
const backgroundBlur = num("background_blur", 0, 0, 100);
const backgroundBrightness = num("background_brightness", 100, 0, 300);
const backgroundContrast = num("background_contrast", 100, 0, 300);
const overlayColor = color("background_overlay_color", "");
const overlayOpacity = num("background_overlay_opacity", 0, 0, 100);

// Where each image lands once materialised. A data: URI becomes one real file
// on both surfaces (identical payloads are written once and shared); a URL or
// an absolute path passes through untouched.
const emitted = new Map(); // data URI -> { asset, bytes, ext }
const materialise = (value, slug) => {
  if (!value.startsWith("data:image/")) return { asset: value, bytes: null, ext: null };
  if (emitted.has(value)) return emitted.get(value);
  const ext = value
    .slice("data:image/".length, value.indexOf(";"))
    .toLowerCase()
    .replace("jpg", "jpeg");
  const out = {
    asset: `/brand/${slug}.${ext === "jpeg" ? "jpg" : ext}`,
    bytes: dataUriBytes(value, `${slug}_url`),
    ext,
  };
  emitted.set(value, out);
  return out;
};

// Order matters: crest is the brand-meaningful name, so a logo shared by all
// three ends up as crest.png rather than logo.png.
const crestOut = materialise(crest, "crest");
const badgeOut = materialise(badge, "badge");
const logoOut = materialise(logo, "logo");

if (errors.length) {
  console.error("brand.json is not valid branding:\n" + errors.map((e) => `  - ${e}`).join("\n"));
  process.exit(1);
}

// ---------------------------------------------------------------------------
// emit
// ---------------------------------------------------------------------------

// JSON cannot carry comments, so the generated file is bare — the "do not
// edit" notice lives in lib/brand.ts and in this script.
const BANNER_DART =
  "// GENERATED FILE — DO NOT EDIT OR RUN THE FORMATTER OVER IT.\n" +
  "// Derived from brand.json at the repository root by scripts/brand-sync.mjs.\n" +
  "// Rebrand by editing ../../../../brand.json, then run: make brand\n";

const resolved = {
  app_name: appName,
  name: institution,
  motto,
  slogan,
  address,
  logo_asset: logoOut.asset,
  crest_asset: crestOut.asset,
  badge_asset: badgeOut.asset,
  brand_color: brandColor,
  header_color: headerColor,
  sidebar_color: sidebarColor,
  footer_color: footerColor,
  background_color: backgroundColor,
  background_image: backgroundImage,
  background_blur: backgroundBlur,
  background_brightness: backgroundBrightness,
  background_contrast: backgroundContrast,
  background_overlay_color: overlayColor,
  background_overlay_opacity: overlayOpacity,
  text_color_light: textLight,
  text_color_dark: textDark,
};

const jsonBody = JSON.stringify(resolved, null, 2) + "\n";

// Dart string literal: escape backslash, quote and dollar (interpolation).
const dartStr = (v) =>
  "'" + v.replace(/\\/g, "\\\\").replace(/'/g, "\\'").replace(/\$/g, "\\$") + "'";

// Dart Color is 0xAARRGGBB.
const dartColor = (hex) => {
  let h = hex.replace("#", "").toLowerCase();
  if (h.length === 3) h = [...h].map((c) => c + c).join("");
  if (h.length === 6) h = "ff" + h;
  else if (h.length === 8) h = h.slice(6) + h.slice(0, 6);
  return `Color(0x${h.toUpperCase()})`;
};

const dartNum = (n) => {
  const s = String(n);
  return /[.e]/.test(s) ? s : `${s}.0`;
};

const dartAsset = (out) =>
  out.asset.startsWith("/") ? `'assets${out.asset}'` : dartStr(out.asset);

const dart = `${BANNER_DART}
// ignore_for_file: prefer_single_quotes

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

/// Every brand colour, string and image, derived from brand.json.
///
/// The UI layer reads branding from here and nowhere else — rebranding is a
/// one-file edit followed by \`make brand\`.
class QaatBrand {
  QaatBrand._();

  // --- identity ----------------------------------------------------------
  static const String appName = ${dartStr(appName)};
  static const String institution = ${dartStr(institution)};
  static const String motto = ${dartStr(motto)};
  static const String slogan = ${dartStr(slogan)};
  static const String address = ${dartStr(address)};

  // --- palette -----------------------------------------------------------
  /// Primary brand colour: buttons, accents, links.
  static const Color brandColor = ${dartColor(brandColor)};
  /// App bar / header background.
  static const Color headerColor = ${dartColor(headerColor)};
  /// Sidebar / bottom navigation background.
  static const Color sidebarColor = ${dartColor(sidebarColor)};
  /// Footer background.
  static const Color footerColor = ${dartColor(footerColor)};
  /// Page background.
  static const Color backgroundColor = ${dartColor(backgroundColor)};
  static const Color textColorLight = ${dartColor(textLight)};
  static const Color textColorDark = ${dartColor(textDark)};

  // --- background image ---------------------------------------------------
  /// Empty = solid [backgroundColor]. Otherwise a data URI, an http(s) URL or
  /// an asset path — see BrandBackground, which applies the treatment below.
  static const String backgroundImage = ${dartStr(backgroundImage)};
  static const double backgroundBlur = ${dartNum(backgroundBlur)};
  static const double backgroundBrightness = ${dartNum(backgroundBrightness)};
  static const double backgroundContrast = ${dartNum(backgroundContrast)};
  static const Color? backgroundOverlayColor =
      ${overlayColor ? dartColor(overlayColor) : "null"};
  /// 0–100: the overlay colour's opacity as a percentage.
  static const double backgroundOverlayOpacity = ${dartNum(overlayOpacity)};

  // --- crest / badge / logo ------------------------------------------------
  /// Materialised from brand.json's base64 by scripts/brand-sync.mjs.
  static const String logoAssetPath = ${dartAsset(logoOut)};
  static const String crestAssetPath = ${dartAsset(crestOut)};
  static const String badgeAssetPath = ${dartAsset(badgeOut)};

  static const ImageProvider logoImage = AssetImage(logoAssetPath);
  static const ImageProvider crestImage = AssetImage(crestAssetPath);
  static const ImageProvider badgeImage = AssetImage(badgeAssetPath);

  /// Raw bytes of a bundled asset — used by the brand drift test.
  static Future<Uint8List> assetBytes(String assetPath) async {
    final data = await rootBundle.load(assetPath);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }
}
`;

/** @type {Array<[string, Buffer]>} */
const outputs = [
  ["frontend/web/lib/brand.json", Buffer.from(jsonBody)],
  ["frontend/mobile/lib/core/brand/brand.g.dart", Buffer.from(dart)],
];

for (const out of emitted.values()) {
  if (!out.bytes) continue;
  const name = out.asset.slice("/brand/".length);
  outputs.push([`frontend/web/public/brand/${name}`, out.bytes]);
  outputs.push([`frontend/mobile/assets/brand/${name}`, out.bytes]);
}

// ---------------------------------------------------------------------------
// write or verify
// ---------------------------------------------------------------------------

let stale = 0;
for (const [rel, buf] of outputs) {
  const abs = join(repoRoot, rel);
  let current = null;
  try {
    current = readFileSync(abs);
  } catch {
    /* missing */
  }
  const same = current !== null && current.equals(buf);
  if (checkOnly) {
    if (!same) {
      stale++;
      console.error(`  ${rel}: ${current === null ? "missing" : "out of date"}`);
    }
  } else if (!same) {
    mkdirSync(dirname(abs), { recursive: true });
    writeFileSync(abs, buf);
    console.log(`  wrote ${relative(repoRoot, abs)} (${buf.length} B)`);
  }
}

if (checkOnly) {
  if (stale > 0) {
    console.error(`\nbranding drifted from brand.json in ${stale} file(s) — run 'make brand'.`);
    process.exit(1);
  }
  console.log("branding is in sync with brand.json ✓");
}
