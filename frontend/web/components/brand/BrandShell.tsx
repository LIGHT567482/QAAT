"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { brand } from "@/lib/brand";
import { API_BASE } from "@/lib/api";

/** Navigation for the staff dashboards. Spec doc 08 §8 keeps the API health
 * shortcut one click away from the dashboard. */
const NAV: Array<{ href: string; label: string }> = [
  { href: "/dashboard", label: "Dashboard" },
  { href: `${API_BASE}/health`, label: "API health" },
];

/**
 * The branded application frame: sidebar (brand.json `sidebar_color`), header
 * (`header_color`), footer (`footer_color`), crest and brand strings. Every
 * staff page renders inside this so the chrome is configured in one place.
 */
export function BrandShell({
  children,
  title,
}: {
  children: React.ReactNode;
  title: string;
}) {
  const pathname = usePathname();

  return (
    <div style={{ display: "flex", minHeight: "100vh" }}>
      <aside
        style={{
          width: 232,
          flexShrink: 0,
          background: "var(--brand-sidebar)",
          color: "var(--brand-text-dark)",
          display: "flex",
          flexDirection: "column",
          gap: 20,
          padding: "20px 16px",
        }}
      >
        <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
          {/* eslint-disable-next-line @next/next/no-img-element -- crest may be any URL brand.json supplies */}
          <img
            src={brand.crest_asset}
            alt={`${brand.name} crest`}
            width={40}
            height={40}
            style={{ objectFit: "contain", flexShrink: 0 }}
          />
          <div style={{ lineHeight: 1.25, minWidth: 0 }}>
            <div style={{ fontWeight: 700, fontSize: 16 }}>{brand.app_name}</div>
            <div style={{ fontSize: 11, opacity: 0.85 }}>{brand.motto}</div>
          </div>
        </div>

        <nav style={{ display: "grid", gap: 4 }}>
          {NAV.map((item) => {
            const active = pathname === item.href;
            const external = item.href.startsWith("http");
            return (
              <Link
                key={item.href}
                href={item.href}
                {...(external ? { target: "_blank", rel: "noreferrer" } : {})}
                style={{
                  padding: "8px 10px",
                  borderRadius: 6,
                  fontSize: 14,
                  background: active ? "rgba(255,255,255,0.16)" : "transparent",
                  color: "var(--brand-text-dark)",
                }}
              >
                {item.label}
              </Link>
            );
          })}
        </nav>

        <div style={{ marginTop: "auto", fontSize: 11, opacity: 0.8, lineHeight: 1.5 }}>
          <div>{brand.name}</div>
          {brand.address && <div>{brand.address}</div>}
        </div>
      </aside>

      <div style={{ flex: 1, display: "flex", flexDirection: "column", minWidth: 0 }}>
        <header
          style={{
            background: "var(--brand-header)",
            color: "var(--brand-text-dark)",
            padding: "12px 20px",
            display: "flex",
            alignItems: "center",
            justifyContent: "space-between",
            gap: 12,
            flexWrap: "wrap",
          }}
        >
          <h1 style={{ fontSize: 15, fontWeight: 600, margin: 0 }}>{title}</h1>
          <span style={{ fontSize: 13, opacity: 0.9 }}>{brand.slogan}</span>
        </header>

        <main style={{ flex: 1, padding: 24, width: "100%", maxWidth: 1040 }}>
          {children}
        </main>

        <footer
          style={{
            background: "var(--brand-footer)",
            color: "var(--brand-text-dark)",
            padding: "10px 20px",
            fontSize: 12,
            display: "flex",
            justifyContent: "space-between",
            gap: 12,
            flexWrap: "wrap",
          }}
        >
          <span>
            {brand.name} · {brand.app_name}
          </span>
          <span>
            {brand.motto}
            {brand.address && ` · ${brand.address}`}
          </span>
        </footer>
      </div>
    </div>
  );
}
