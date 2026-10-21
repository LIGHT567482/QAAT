// Branding accessor for the web surface.
//
// The data lives in lib/brand.json, which scripts/brand-sync.mjs derives from
// the repo-root brand.json — the single source of branding truth. Never
// hardcode a brand colour, string or image in a component: read it from here
// (`make brand` regenerates, `make brand-check` guards drift).

import type { CSSProperties } from "react";

import raw from "./brand.json";

export interface Brand {
  /** Product name, e.g. QAAT. */
  app_name: string;
  /** Institution the crest belongs to. */
  name: string;
  motto: string;
  slogan: string;
  address: string;
  logo_asset: string;
  crest_asset: string;
  badge_asset: string;
  brand_color: string;
  header_color: string;
  sidebar_color: string;
  footer_color: string;
  background_color: string;
  background_image: string;
  background_blur: number;
  background_brightness: number;
  background_contrast: number;
  background_overlay_color: string;
  background_overlay_opacity: number;
  text_color_light: string;
  text_color_dark: string;
}

export const brand: Brand = raw;

/**
 * The brand as CSS custom properties, consumed by app/globals.css and by any
 * inline style that needs a brand value. `brandCssVars()` is injected once into
 * :root by app/layout.tsx, so `var(--brand-header)` etc. work everywhere.
 */
export function brandCssVars(b: Brand = brand): Record<string, string> {
  return {
    "--brand-primary": b.brand_color,
    "--brand-header": b.header_color,
    "--brand-sidebar": b.sidebar_color,
    "--brand-footer": b.footer_color,
    "--brand-bg": b.background_color,
    "--brand-text-light": b.text_color_light,
    "--brand-text-dark": b.text_color_dark,
    "--brand-surface": "#ffffff",
    "--brand-bg-image": b.background_image ? `url("${b.background_image}")` : "none",
    "--brand-bg-blur": `${b.background_blur}px`,
    "--brand-bg-brightness": `${b.background_brightness}%`,
    "--brand-bg-contrast": `${b.background_contrast}%`,
    "--brand-bg-overlay": b.background_overlay_color || "transparent",
    "--brand-bg-overlay-opacity": String(b.background_overlay_opacity / 100),
  };
}

/** Inline style carrying the brand custom properties (for a scoped subtree). */
export function brandVarsStyle(): CSSProperties {
  return brandCssVars() as CSSProperties;
}
