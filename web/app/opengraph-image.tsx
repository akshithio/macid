import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { ImageResponse } from "next/og";

export const alt = "MacID: face unlock for your Mac";
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";

export default async function Image() {
  const sans = await readFile(join(process.cwd(), "assets/Arimo-Regular.ttf"));

  return new ImageResponse(
    (
      <div
        style={{
          width: "100%",
          height: "100%",
          display: "flex",
          flexDirection: "column",
          justifyContent: "space-between",
          padding: "96px 104px",
          background: "#faf9f7",
          color: "#1f1f1d",
          fontFamily: "Arimo",
        }}
      >
        <svg width="112" height="96" viewBox="23 26 56 48" fill="#1f1f1d">
          <rect x="23" y="26" width="13" height="48" rx="6.5" />
          <path
            fillRule="evenodd"
            d="M45 26h10a24 24 0 0 1 0 48H45V26Zm10 16a8 8 0 1 0 0 16 8 8 0 0 0 0-16Z"
          />
        </svg>
        <div style={{ display: "flex", flexDirection: "column" }}>
          <div style={{ fontSize: 80, letterSpacing: "-0.01em" }}>MacID</div>
          <div style={{ marginTop: 20, maxWidth: 760, fontSize: 36, lineHeight: 1.5 }}>
            Face unlock for your Mac. Wake it, press Return, and you are in.
          </div>
          <div style={{ marginTop: 44, fontSize: 26, color: "#8c8a84" }}>macid.akshith.io</div>
        </div>
      </div>
    ),
    { ...size, fonts: [{ name: "Arimo", data: sans, style: "normal", weight: 400 }] },
  );
}
