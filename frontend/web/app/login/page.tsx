"use client";

import { FormEvent, useState } from "react";
import { useRouter } from "next/navigation";
import { api, setToken, ApiError } from "@/lib/api";
import { brand } from "@/lib/brand";

/** Staff sign-in. The crest, colours and every string come from brand.json. */
export default function LoginPage() {
  const router = useRouter();
  const [login, setLogin] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function onSubmit(e: FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);
    try {
      const { token, user } = await api.login(login.trim(), password);
      // Staff surfaces only: students/lecturers belong in the mobile app.
      if (user.role === "student") {
        setError("Students sign in with the mobile app.");
        setBusy(false);
        return;
      }
      setToken(token);
      router.push("/dashboard");
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Could not reach the server.");
      setBusy(false);
    }
  }

  const input: React.CSSProperties = {
    padding: 10,
    fontSize: 16,
    border: "1px solid color-mix(in srgb, var(--brand-text-light) 20%, transparent)",
    borderRadius: 6,
    background: "var(--brand-surface)",
    color: "var(--brand-text-light)",
  };

  return (
    <main
      style={{
        minHeight: "100vh",
        display: "grid",
        placeItems: "center",
        padding: 24,
      }}
    >
      <section
        style={{
          width: "100%",
          maxWidth: 400,
          background: "var(--brand-surface)",
          border: "1px solid color-mix(in srgb, var(--brand-text-light) 12%, transparent)",
          borderRadius: 12,
          padding: 28,
          boxShadow: "0 8px 32px rgba(0,0,0,0.08)",
        }}
      >
        <header style={{ textAlign: "center", marginBottom: 20 }}>
          {/* eslint-disable-next-line @next/next/no-img-element -- crest may be any URL brand.json supplies */}
          <img
            src={brand.crest_asset}
            alt={`${brand.name} crest`}
            width={72}
            height={72}
            style={{ objectFit: "contain" }}
          />
          <h1
            style={{
              fontSize: 24,
              margin: "10px 0 2px",
              color: "var(--brand-primary)",
              fontWeight: 700,
            }}
          >
            {brand.app_name}
          </h1>
          {brand.slogan && <p style={{ margin: 0, fontSize: 13 }}>{brand.slogan}</p>}
          <p style={{ margin: "2px 0 0", fontSize: 13, opacity: 0.75 }}>{brand.name}</p>
        </header>

        <p style={{ margin: "0 0 12px", fontSize: 13, opacity: 0.75 }}>
          Administrator · QA · KIU-admin sign-in
        </p>

        <form onSubmit={onSubmit} style={{ display: "grid", gap: 12 }}>
          <label style={{ display: "grid", gap: 4, fontSize: 13 }}>
            Email, reg no, or staff number
            <input
              value={login}
              onChange={(e) => setLogin(e.target.value)}
              autoComplete="username"
              required
              style={input}
            />
          </label>
          <label style={{ display: "grid", gap: 4, fontSize: 13 }}>
            Password
            <input
              type="password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              autoComplete="current-password"
              required
              style={input}
            />
          </label>
          {error && (
            <p role="alert" style={{ color: "#b00020", margin: 0, fontSize: 13 }}>
              {error}
            </p>
          )}
          <button
            type="submit"
            disabled={busy}
            style={{
              padding: 10,
              fontSize: 16,
              background: "var(--brand-primary)",
              color: "var(--brand-text-dark)",
              border: 0,
              borderRadius: 6,
              opacity: busy ? 0.7 : 1,
            }}
          >
            {busy ? "Signing in…" : "Sign in"}
          </button>
        </form>
      </section>
    </main>
  );
}
