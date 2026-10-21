// QAAT web API client. Talks to the Go backend's per-role API groups.
// Attendance endpoints return 501 "attendance logic pending merge" until the
// engine merges in (spec doc 06) — every fetch surfaces that as a pending state.

/** Origin of the Go backend. Exported so links (e.g. the health shortcut)
 * point at it rather than at the Next.js origin. */
export const API_BASE = process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:8080";

export type Role = "student" | "lecturer" | "qa_staff" | "administrator" | "kiu_admin";

export interface Me {
  id: string;
  username: string;
  email: string;
  fullName: string;
  role: Role;
  emailVerified: boolean;
  isActive: boolean;
  staffNumber?: string;
  registrationNumber?: string;
}

export class ApiError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

function token(): string | null {
  if (typeof window === "undefined") return null;
  return localStorage.getItem("qaat_token");
}

export function setToken(t: string) {
  localStorage.setItem("qaat_token", t);
}

export function clearToken() {
  localStorage.removeItem("qaat_token");
}

async function req<T>(path: string, init: RequestInit = {}): Promise<T> {
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    ...(init.headers as Record<string, string>),
  };
  const t = token();
  if (t) headers.Authorization = `Bearer ${t}`;

  const res = await fetch(`${API_BASE}${path}`, { ...init, headers });
  const text = await res.text();
  const body = text ? JSON.parse(text) : null;

  if (!res.ok) {
    const detail = body?.detail ?? body?.error ?? `Request failed (${res.status})`;
    throw new ApiError(res.status, detail);
  }
  return body as T;
}

export const api = {
  login: (login: string, password: string) =>
    req<{ token: string; user: Me }>("/api/auth/login", {
      method: "POST",
      body: JSON.stringify({ login, password }),
    }),
  me: () => req<Me>("/api/auth/me"),

  // Dashboard summaries per role group. There is deliberately no student
  // dashboard: the web surface is staff-only (students are blocked at login)
  // and, per spec doc 07, students have no dashboard in the mobile app either.
  lecturerDashboard: () => req<Record<string, unknown>>("/api/lecturer/dashboard"),
  adminDashboard: () => req<Record<string, unknown>>("/api/admin/dashboard"),
};

// True when a caught error is the attendance merge-slot 501.
export function isPendingMerge(e: unknown): boolean {
  return e instanceof ApiError && e.status === 501;
}
