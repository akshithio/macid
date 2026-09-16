import type { Metadata } from "next";
import { Inter, JetBrains_Mono, Reenie_Beanie } from "next/font/google";
import "./globals.css";

const inter = Inter({ subsets: ["latin"], variable: "--font-inter" });
const jetbrains = JetBrains_Mono({ subsets: ["latin"], variable: "--font-jetbrains" });
const reenie = Reenie_Beanie({
  subsets: ["latin"],
  weight: "400",
  variable: "--font-reenie",
});

export const metadata: Metadata = {
  title: "MacID — face unlock for the macOS lock screen",
  description:
    "Wake your Mac, press Return, and you are in. A PAM module and a camera agent, built from source on your own machine.",
  metadataBase: new URL("https://macid.akshith.io"),
  openGraph: {
    title: "MacID",
    description: "Face unlock for the macOS lock screen.",
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
        className={`${inter.variable} ${jetbrains.variable} ${reenie.variable} bg-paper text-ink font-mono antialiased`}
      >
        {children}
      </body>
    </html>
  );
}
