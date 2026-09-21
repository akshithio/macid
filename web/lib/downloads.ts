const OWNER = "akshithio";
const REPO = "macid";
const ASSET = "MacID.dmg";

type Release = {
  draft: boolean;
  prerelease: boolean;
  assets: { name: string; download_count: number }[];
};

export async function downloadCount(): Promise<number | null> {
  const headers: Record<string, string> = {
    Accept: "application/vnd.github+json",
    "User-Agent": "macid.akshith.io",
  };
  if (process.env.GITHUB_TOKEN) {
    headers.Authorization = `Bearer ${process.env.GITHUB_TOKEN}`;
  }

  try {
    const res = await fetch(
      `https://api.github.com/repos/${OWNER}/${REPO}/releases?per_page=100`,
      { headers, next: { revalidate: 600 } },
    );
    if (!res.ok) return null;

    const releases = (await res.json()) as Release[];
    let total = 0;
    for (const release of releases) {
      if (release.draft) continue;
      for (const asset of release.assets) {
        if (asset.name === ASSET) total += asset.download_count;
      }
    }
    return total;
  } catch {
    return null;
  }
}
