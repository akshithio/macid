import { CopyCommand } from "@/components/CopyCommand";
import { ScanMark } from "@/components/ScanMark";

const INSTALL = "curl -fsSL https://macid.akshith.io/install.sh | bash";

export default function Home() {
  return (
    <main className="flex min-h-dvh flex-col items-center justify-center px-5 py-16 sm:px-6">
      <div className="w-full max-w-[34rem]">
        <ScanMark className="mb-9 h-14 w-14 text-ink" />

        <h1 className="text-[15px] tracking-[0.02em] text-ink">MacID</h1>

        <p className="mt-3 text-[15px] leading-[1.75] text-ink">
          Face unlock for your Mac. Wake it, press Return on the empty password
          field, and you are in.
        </p>

        <div className="mt-8">
          <CopyCommand command={INSTALL} />
        </div>

        <dl className="mt-8 space-y-2.5 text-[12.5px] leading-relaxed">
          <div className="flex gap-3">
            <dt className="w-[5.5rem] shrink-0 text-muted">Installs</dt>
            <dd className="text-ink">
              A menu bar app, and a{" "}
              <code className="bg-field px-1 py-0.5 text-[12px]">macid</code>{" "}
              command.
            </dd>
          </div>
          <div className="flex gap-3">
            <dt className="w-[5.5rem] shrink-0 text-muted">Needs</dt>
            <dd className="text-ink">
              macOS 14+, Apple silicon, Xcode command line tools. Builds from
              source.
            </dd>
          </div>
          <div className="flex gap-3">
            <dt className="w-[5.5rem] shrink-0 text-muted">Privacy</dt>
            <dd className="text-ink">
              Recognition runs on device. Nothing leaves your Mac.
            </dd>
          </div>
        </dl>

        {/* The one caveat worth a visitor's time before they pipe a script into
            their shell. Everything else lives in the repo. */}
        <p className="mt-8 border-t border-rule pt-6 text-[12.5px] leading-[1.75] text-muted">
          A blink is required, so a photo of you will not unlock your Mac. A
          video might. This is a webcam and not an infrared depth sensor —
          treat it as a convenience over typing, not an upgrade over your
          password. If anything fails, you get the normal password prompt.
        </p>

        <footer className="mt-10 flex items-baseline gap-5 text-[11px] tracking-[0.08em] text-muted">
          <a href="/install.sh" className="transition-colors hover:text-ink">
            read the installer
          </a>
          <span className="text-rule">/</span>
          <span>MIT</span>
        </footer>
      </div>
    </main>
  );
}
