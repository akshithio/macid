"use client";

import { useEffect, useState } from "react";

import { DOWNLOADS_OPEN } from "@/lib/release";

type Fit = "unknown" | "mac" | "intel-mac" | "other";

function detect(): Fit {
  if (typeof navigator === "undefined") return "unknown";

  const ua = navigator.userAgent;
  const isMac = /Mac OS X|Macintosh/.test(ua) && !/iPhone|iPad|iPod/.test(ua);
  if (!isMac) return "other";

  try {
    const gl = document.createElement("canvas").getContext("webgl");
    const info = gl?.getExtension("WEBGL_debug_renderer_info");
    const renderer = info
      ? String(gl?.getParameter(info.UNMASKED_RENDERER_WEBGL) ?? "")
      : "";
    if (/Intel|Radeon|NVIDIA|GeForce/i.test(renderer)) return "intel-mac";
  } catch {}

  return "mac";
}

export function Download({ count }: { count: number | null }) {
  const [fit, setFit] = useState<Fit>("unknown");

  useEffect(() => setFit(detect()), []);

  return (
    <div>
      {fit === "other" ? (
        <p className="border border-rule bg-field px-4 py-3.5 text-[13px] leading-[1.7] text-ink sm:px-5">
          MacID runs on macOS only. It replaces the Mac lock screen&rsquo;s
          password prompt, so there is nothing for it to do here.
        </p>
      ) : (
        <a
          href={DOWNLOADS_OPEN ? "/download" : undefined}
          aria-disabled={!DOWNLOADS_OPEN}
          className={`flex items-center justify-between gap-4 border border-ink bg-ink px-5 py-3.5 text-[13px] text-paper transition-opacity ${
            DOWNLOADS_OPEN ? "hover:opacity-85" : "cursor-default"
          }`}
        >
          <span>Download MacID</span>
          <span className="text-[11px] tracking-[0.06em] opacity-70">
            macOS 14+ &middot; Apple silicon &middot; 7.2 MB
          </span>
        </a>
      )}

      {fit === "intel-mac" && (
        <p className="mt-3 text-[12.5px] leading-[1.7] text-muted">
          This Mac looks like an Intel model. MacID is built for Apple silicon
          and won&rsquo;t open on it.
        </p>
      )}

      {fit !== "other" && count !== null && count > 0 && (
        <p className="mt-3 text-[11px] tracking-[0.06em] text-muted">
          {count.toLocaleString("en-US")} download{count === 1 ? "" : "s"}
        </p>
      )}
    </div>
  );
}
