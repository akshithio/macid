import type { Metadata } from "next";
import { JetBrains_Mono } from "next/font/google";
import "./globals.css";

const jetbrains = JetBrains_Mono({ subsets: ["latin"], variable: "--font-jetbrains" });

export const metadata: Metadata = {
  title: "MacID",
  description:
    "Face unlock for your Mac. Wake it, press Return on the empty password field, and you are in.",
  metadataBase: new URL("https://macid.akshith.io"),
  openGraph: {
    title: "MacID",
    description: "Face unlock for your Mac. Wake it, press Return, and you are in.",
    url: "https://macid.akshith.io",
    siteName: "MacID",
  },
  twitter: { card: "summary_large_image" },
};

export default function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body
        className={`${jetbrains.variable} bg-paper text-ink font-mono antialiased`}
      >
        {children}
      </body>
    </html>
  );
}
