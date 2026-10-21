"use client";

import { FormEvent, useState } from "react";
import { useRouter } from "next/navigation";
import { api, setToken, ApiError } from "@/lib/api";

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

  return (
    <main style={{ maxWidth: 380, margin: "10vh auto", fontFamily: "system-ui" }}>
      <h1 style={{ fontSize: 24 }}>QAAT</h1>
      <p style={{ color: "#555", marginTop: 0 }}>
        Administrator · QA · KIU-admin sign-in
      </p>
      <form onSubmit={onSubmit} style={{ display: "grid", gap: 12 }}>
        <label style={{ display: "grid", gap: 4 }}>
          Email, reg no, or staff number
          <input
            value={login}
            onChange={(e) => setLogin(e.target.value)}
            autoComplete="username"
            required
            style={{ padding: 10, fontSize: 16 }}
          />
        </label>
        <label style={{ display: "grid", gap: 4 }}>
          Password
          <input
            type="password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            autoComplete="current-password"
            required
            style={{ padding: 10, fontSize: 16 }}
          />
        </label>
        {error && (
          <p role="alert" style={{ color: "#b00020", margin: 0 }}>
            {error}
          </p>
        )}
        <button
          type="submit"
          disabled={busy}
          style={{ padding: 10, fontSize: 16, background: "#1a56db", color: "#fff", border: 0 }}
        >
          {busy ? "Signing in…" : "Sign in"}
        </button>
      </form>
    </main>
  );
}
