import type { Metadata } from "next";
import { Inter, Fraunces } from "next/font/google";
import "./globals.css";

const inter = Inter({
  subsets: ["latin"],
  variable: "--font-inter",
  display: "swap",
});

const fraunces = Fraunces({
  subsets: ["latin"],
  variable: "--font-fraunces",
  display: "swap",
  axes: ["SOFT", "WONK", "opsz"],
});

export const metadata: Metadata = {
  title: "Miles — Feel close, even from here",
  description:
    "A quiet, beautiful space for couples in long-distance relationships. Countdowns, timezone-aware rituals, and a shared record of your journey.",
  metadataBase: new URL(
    process.env.NEXT_PUBLIC_APP_URL ?? "http://localhost:3000",
  ),
  openGraph: {
    title: "Miles — Feel close, even from here",
    description:
      "Built around the experience of distance. Countdowns, rituals, and a shared timeline for LDR couples.",
    type: "website",
  },
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en" className={`dark ${inter.variable} ${fraunces.variable}`}>
      <body>{children}</body>
    </html>
  );
}
