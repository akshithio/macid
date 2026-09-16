import type { Metadata } from "next";
import { JetBrains_Mono } from "next/font/google";
import "./globals.css";

const jetbrains = JetBrains_Mono({ subsets: ["latin"], variable: "--font-jetbrains" });

export const metadata: Metadata = {
  title: "MacID — face unlock for your Mac",
  description:
    "Wake your Mac, press Return, and you are in. A menu bar app that unlocks with your face, built from source on your own machine.",
  metadataBase: new URL("https://macid.akshith.io"),
  openGraph: {
    title: "MacID",
    description: "Face unlock for your Mac.",
    url: "https://macid.akshith.io",
    siteName: "MacID",
  },
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
