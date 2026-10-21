import { redirect } from "next/navigation";

// The web app is the staff surface: land on the dashboard (auth-gated).
export default function Home() {
  redirect("/dashboard");
}
