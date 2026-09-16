import type { NextConfig } from "next";

const config: NextConfig = {
  // The installer and the source tarball are served straight out of public/,
  // so they must never be rewritten or cached as HTML.
  async headers() {
    return [
      {
        source: "/install.sh",
        headers: [
          { key: "Content-Type", value: "text/plain; charset=utf-8" },
          { key: "Cache-Control", value: "public, max-age=300" },
        ],
      },
      {
        source: "/:file(macid-.*\\.tar\\.gz)",
        headers: [
          { key: "Content-Type", value: "application/gzip" },
          { key: "Cache-Control", value: "public, max-age=300" },
        ],
      },
    ];
  },
};

export default config;
