import { DOWNLOADS_OPEN } from "@/lib/release";

export const runtime = "edge";

const OWNER = "akshithio";
const REPO = "macid";
const ASSET = "MacID.dmg";

type Asset = { name: string; url: string; browser_download_url: string };
type Release = { draft: boolean; prerelease: boolean; assets: Asset[] };

function headers(): HeadersInit {
  const h: HeadersInit = {
    Accept: "application/vnd.github+json",
    "User-Agent": "macid.akshith.io",
  };
  if (process.env.GITHUB_TOKEN) {
    (h as Record<string, string>).Authorization = `Bearer ${process.env.GITHUB_TOKEN}`;
  }
  return h;
}

async function latestAsset(): Promise<string | null> {
  try {
    const res = await fetch(
      `https://api.github.com/repos/${OWNER}/${REPO}/releases?per_page=20`,
      { headers: headers(), next: { revalidate: 300 } },
    );
    if (!res.ok) return null;
    const releases = (await res.json()) as Release[];
    for (const release of releases) {
      if (release.draft || release.prerelease) continue;
      const asset = release.assets.find((a) => a.name === ASSET);
      if (asset) return asset.browser_download_url;
    }
  } catch {}
  return null;
}

export async function GET(request: Request) {
  if (!DOWNLOADS_OPEN) {
    return new Response(null, {
      status: 307,
      headers: { Location: new URL("/", request.url).toString() },
    });
  }

  const asset = await latestAsset();

  if (asset) {
    const upstream = await fetch(asset, {
      headers: { "User-Agent": "macid.akshith.io" },
      redirect: "follow",
      cache: "no-store",
    });
    if (upstream.ok && upstream.body) {
      const headers = new Headers({
        "Content-Type": "application/x-apple-diskimage",
        "Content-Disposition": `attachment; filename="${ASSET}"`,
        "Cache-Control": "no-store",
      });
      const length = upstream.headers.get("content-length");
      if (length) headers.set("Content-Length", length);
      return new Response(upstream.body, { headers });
    }
  }

  return new Response(null, {
    status: 302,
    headers: {
      Location: new URL(`/${ASSET}`, request.url).toString(),
      "Cache-Control": "no-store",
    },
  });
}
