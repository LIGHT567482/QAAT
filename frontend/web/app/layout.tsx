import type { Metadata, Viewport } from "next";
import localFont from "next/font/local";
import "./globals.css";
import { brand, brandCssVars } from "@/lib/brand";

const geistSans = localFont({
  src: "./fonts/GeistVF.woff",
  variable: "--font-geist-sans",
  weight: "100 900",
});
const geistMono = localFont({
  src: "./fonts/GeistMonoVF.woff",
  variable: "--font-geist-mono",
  weight: "100 900",
});

// Titles, description, favicon and theme colour all come from brand.json.
export const metadata: Metadata = {
  title: {
    default: `${brand.app_name} — ${brand.name}`,
    template: `%s · ${brand.app_name}`,
  },
  description: brand.motto,
  icons: { icon: brand.crest_asset },
};

export const viewport: Viewport = {
  themeColor: brand.header_color,
};

/** Serialises the brand as CSS custom properties consumed by globals.css. */
function brandStyle() {
  const vars = Object.entries(brandCssVars())
    .map(([k, v]) => `${k}:${v}`)
    .join(";");
  return { __html: `:root{${vars}}` };
}

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en">
      <head>
        {/* One file (brand.json) drives every colour on every page. */}
        <style dangerouslySetInnerHTML={brandStyle()} />
      </head>
      <body className={`${geistSans.variable} ${geistMono.variable}`}>
        <div id="brand-background" aria-hidden="true">
          <div className="layer" />
          <div className="overlay" />
        </div>
        {children}
      </body>
    </html>
  );
}
