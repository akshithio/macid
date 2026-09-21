import type { Metadata } from "next";
import Link from "next/link";
import { ScanMark } from "@/components/ScanMark";

export const metadata: Metadata = {
  title: "Privacy / MacID",
  description:
    "What MacID does with your face, your camera and your data. Recognition runs on device; nothing about your face leaves your Mac.",
};

function Point({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div className="flex flex-col gap-1.5 sm:flex-row sm:gap-3">
      <h2 className="w-[9.5rem] shrink-0 text-[12.5px] leading-relaxed text-muted">
        {title}
      </h2>
      <div className="space-y-2.5 text-[12.5px] leading-relaxed text-ink">
        {children}
      </div>
    </div>
  );
}

export default function Privacy() {
  return (
    <main className="flex min-h-dvh flex-col items-center justify-center px-5 py-16 sm:px-6">
      <div className="w-full max-w-[34rem]">
        <Link href="/" aria-label="MacID home">
          <ScanMark className="mb-9 h-14 w-14 text-ink" />
        </Link>

        <h1 className="text-[15px] tracking-[0.02em] text-ink">Privacy</h1>

        <p className="mt-3 text-[15px] leading-[1.75] text-ink">
          MacID recognizes your face to unlock your Mac. Nothing about your face
          ever leaves your Mac.
        </p>

        <div className="mt-8 space-y-5">
          <Point title="Your face">
            <p>
              Enrolling stores a set of mathematical descriptors of your face,
              not photographs. They live in{" "}
              <code className="bg-field px-1 py-0.5 text-[12px]">
                ~/Library/Application Support/MacID
              </code>
              , in a directory only your account can read. Deleting your face
              data in the app removes them.
            </p>
          </Point>

          <Point title="The camera">
            <p>
              Frames are read at the lock screen, compared on the spot, and
              discarded. No frame is written to disk, and none is kept after the
              comparison. Whether the camera turns on when the screen wakes or
              only when you press Return is your choice, in Settings.
            </p>
          </Point>

          <Point title="On device">
            <p>
              Recognition runs through Apple&apos;s Vision framework on your own
              machine. There is no account, no sign-in, no server that sees your
              face, and no model downloaded at runtime.
            </p>
          </Point>

          <Point title="No telemetry">
            <p>
              MacID sends nothing anywhere. No analytics, no crash reports, no
              usage counts, no update checks. The app makes no network requests
              at all.
            </p>
          </Point>

          <Point title="This website">
            <p>
              This site has no analytics, no cookies and no trackers. Requesting
              the install script or the source archive is an ordinary web
              request, and Vercel, who host it, keep the operational logs any
              web server keeps.
            </p>
          </Point>

          <Point title="Checking this">
            <p>
              MacID installs from source you can read. Every claim above is
              something you can verify in{" "}
              <a
                href="https://github.com/akshithio/macid"
                target="_blank"
                rel="noopener noreferrer"
                className="underline decoration-rule underline-offset-2 transition-colors hover:decoration-ink"
              >
                the repository
              </a>
              , which is the point of shipping it that way.
            </p>
          </Point>
        </div>

        <p className="mt-8 border-t border-rule pt-6 text-[12.5px] leading-[1.75] text-muted">
          MacID matches a 2D webcam image, so it is a convenience rather than a
          password replacement. Recognition happening on your Mac is a fact
          about where your data goes, not a claim that a webcam is as hard to
          fool as a depth sensor.
        </p>

        <footer className="mt-10 flex items-baseline gap-5 text-[11px] tracking-[0.08em] text-muted">
          <Link href="/" className="transition-colors hover:text-ink">
            macid
          </Link>
          <span className="text-rule">/</span>
          <span>MIT</span>
        </footer>
      </div>
    </main>
  );
}
