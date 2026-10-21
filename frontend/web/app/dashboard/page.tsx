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

type ViewState =
  | { kind: "loading" }
  | { kind: "auth" } // redirect to login
  | { kind: "me"; user: Me }
  | { kind: "error"; message: string };

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
    return <Main>Loading…</Main>;
  }
  if (view.kind === "error") {
    return <Main>{view.message}</Main>;
  }

  const { user } = view;
  return (
    <Main>
      <header style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline" }}>
        <h1 style={{ fontSize: 22, margin: 0 }}>QAAT dashboard</h1>
        <button
          onClick={() => {
            clearToken();
            router.replace("/login");
          }}
          style={{ border: "1px solid #ccc", background: "#fff", padding: "6px 10px" }}
        >
          Sign out
        </button>
      </header>

      <p style={{ color: "#555" }}>
        {user.fullName || user.email} · <strong>{user.role}</strong>
      </p>

      <section
        style={{
          border: "1px solid #e2e2e2",
          borderRadius: 8,
          padding: 16,
          marginTop: 16,
        }}
      >
        <h2 style={{ fontSize: 16, marginTop: 0 }}>Attendance</h2>
        <p style={{ margin: 0, color: "#8a6d00" }}>
          {dashNote ?? "Attendance engine pending merge — lists, sessions, and rolls will appear here."}
        </p>
        <p style={{ margin: "8px 0 0", fontSize: 13, color: "#777" }}>
          Spec: docs/qaat-spec/06-attendance-module.md
        </p>
      </section>

      <section style={{ marginTop: 16 }}>
        <h2 style={{ fontSize: 16 }}>Overview</h2>
        <pre
          style={{
            background: "#f6f6f6",
            padding: 12,
            borderRadius: 6,
            overflowX: "auto",
            fontSize: 13,
          }}
        >
          {dash ? JSON.stringify(dash, null, 2) : "No summary available yet."}
        </pre>
      </section>
    </Main>
  );
}

function Main({ children }: { children: React.ReactNode }) {
  return (
    <main style={{ maxWidth: 760, margin: "6vh auto", padding: "0 16px", fontFamily: "system-ui" }}>
      {children}
    </main>
  );
}
