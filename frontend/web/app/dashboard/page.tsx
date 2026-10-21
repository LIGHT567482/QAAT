"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import {
  api,
  clearToken,
  isPendingMerge,
  Me,
  ApiError,
} from "@/lib/api";
import { brand } from "@/lib/brand";
import { BrandShell } from "@/components/brand/BrandShell";

type ViewState =
  | { kind: "loading" }
  | { kind: "auth" } // redirect to login
  | { kind: "me"; user: Me }
  | { kind: "error"; message: string };

/** Panel surface + border, shared by every card on the page. */
const panel: React.CSSProperties = {
  background: "var(--brand-surface)",
  border: "1px solid color-mix(in srgb, var(--brand-text-light) 12%, transparent)",
  borderRadius: 8,
  padding: 16,
};

export default function DashboardPage() {
  const router = useRouter();
  const [view, setView] = useState<ViewState>({ kind: "loading" });
  const [dash, setDash] = useState<Record<string, unknown> | null>(null);
  const [dashNote, setDashNote] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const user = await api.me();
        if (cancelled) return;
        setView({ kind: "me", user });

        // Pick the dashboard matching the caller's role group.
        try {
          const data =
            user.role === "lecturer" || user.role === "kiu_admin"
              ? await api.lecturerDashboard()
              : await api.adminDashboard();
          if (!cancelled) setDash(data);
        } catch (e) {
          if (cancelled) return;
          setDashNote(
            isPendingMerge(e)
              ? "Attendance data pending engine merge."
              : e instanceof ApiError
                ? e.message
                : "Could not load dashboard."
          );
        }
      } catch (e) {
        if (cancelled) return;
        if (e instanceof ApiError && e.status === 401) {
          clearToken();
          setView({ kind: "auth" });
        } else {
          setView({
            kind: "error",
            message: e instanceof ApiError ? e.message : "Could not reach the server.",
          });
        }
      }
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  useEffect(() => {
    if (view.kind === "auth") router.replace("/login");
  }, [view, router]);

  if (view.kind === "loading" || view.kind === "auth") {
    return (
      <BrandShell title={`${brand.app_name} dashboard`}>
        <p>Loading…</p>
      </BrandShell>
    );
  }
  if (view.kind === "error") {
    return (
      <BrandShell title={`${brand.app_name} dashboard`}>
        <section style={panel}>{view.message}</section>
      </BrandShell>
    );
  }

  const { user } = view;
  return (
    <BrandShell title={`${brand.app_name} dashboard`}>
      <header
        style={{
          display: "flex",
          justifyContent: "space-between",
          alignItems: "baseline",
          gap: 12,
          flexWrap: "wrap",
        }}
      >
        <p style={{ margin: 0 }}>
          {user.fullName || user.email} · <strong>{user.role}</strong>
        </p>
        <button
          onClick={() => {
            clearToken();
            router.replace("/login");
          }}
          style={{
            border: "1px solid color-mix(in srgb, var(--brand-text-light) 20%, transparent)",
            background: "var(--brand-surface)",
            color: "var(--brand-text-light)",
            padding: "6px 10px",
            borderRadius: 6,
          }}
        >
          Sign out
        </button>
      </header>

      <section style={{ ...panel, marginTop: 16 }}>
        <h2 style={{ fontSize: 16, marginTop: 0 }}>Attendance</h2>
        <p style={{ margin: 0, color: "#8a6d00" }}>
          {dashNote ?? "Attendance engine pending merge — lists, sessions, and rolls will appear here."}
        </p>
        <p style={{ margin: "8px 0 0", fontSize: 13, opacity: 0.7 }}>
          Spec: docs/qaat-spec/06-attendance-module.md
        </p>
      </section>

      <section style={{ marginTop: 16 }}>
        <h2 style={{ fontSize: 16 }}>Overview</h2>
        <pre
          style={{
            background: "var(--brand-surface)",
            border: "1px solid color-mix(in srgb, var(--brand-text-light) 12%, transparent)",
            padding: 12,
            borderRadius: 6,
            overflowX: "auto",
            fontSize: 13,
          }}
        >
          {dash ? JSON.stringify(dash, null, 2) : "No summary available yet."}
        </pre>
      </section>
    </BrandShell>
  );
}
