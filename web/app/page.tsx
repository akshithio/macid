import { Grid } from "@/components/Grid";
import { Module, Row, SectionLabel } from "@/components/Module";
import { CopyCommand } from "@/components/CopyCommand";
import { ScanMark } from "@/components/ScanMark";

const INSTALL = "curl -fsSL https://macid.akshith.io/install.sh | bash";

const FLOW = [
  ["01", "Screen locks", "macid receives com.apple.screenIsLocked and turns the camera on."],
  ["02", "Recognition", "Vision detects the face, crops it, and compares a featureprint against your enrolled samples."],
  ["03", "Liveness", "A blink is required. A still photo of you cannot blink."],
  ["04", "Token", "A match arms a single-use token. The camera shuts off immediately."],
  ["05", "Unlock", "You press Return on the empty field. pam_macid redeems the token and the stack short-circuits."],
];

const COMMANDS = [
  ["macid enroll", "Capture 8 samples and calibrate your match threshold"],
  ["macid test", "Run recognition live, before trusting it"],
  ["macid status", "Show what is wired up and what is not"],
  ["sudo macid uninstall", "Remove everything, restore the original PAM stack"],
];

export default function Home() {
  return (
    <main className="relative min-h-dvh overflow-hidden">
      <Grid />

      <div className="relative z-10 mx-auto max-w-3xl px-4 py-10 sm:px-6 sm:py-16">
        <div className="mb-10 flex items-baseline justify-between text-[11px] uppercase tracking-[0.14em] text-muted-soft">
          <span>MacID</span>
          <span>v0.1.0</span>
        </div>

        {/* Hero */}
        <Module>
          <Row>
            <div className="flex flex-wrap items-baseline justify-between gap-x-6 gap-y-2">
              <h1 className="text-[13px] uppercase tracking-[0.1em] text-ink sm:text-sm">
                MacID. Face unlock for macOS. Built from source.
              </h1>
              <span className="text-[13px] tabular-nums text-muted-soft">
                0001260916
              </span>
            </div>
          </Row>

          <CopyCommand command={INSTALL} />

          <div className="flex flex-col sm:flex-row sm:items-stretch">
            <div className="flex shrink-0 items-center justify-center border-rule px-5 py-6 text-ink sm:w-44 sm:border-r sm:px-6">
              <ScanMark className="h-28 w-28" />
            </div>
            <div className="min-w-0 flex-1 border-t border-rule px-5 py-5 sm:border-t-0 sm:px-6">
              <p className="text-[13px] uppercase leading-[1.85] tracking-[0.04em] text-ink-soft">
                Wake the Mac. Press Return on the empty password field. If the
                camera recognizes you, you are in. A PAM module, a camera agent,
                and nothing leaving the machine.
              </p>
            </div>
          </div>
        </Module>

        <p className="mt-4 pr-2 text-right text-[26px] leading-none text-muted font-[family-name:var(--font-reenie)]">
          press return to unlock
        </p>

        {/* How it works */}
        <section className="mt-16">
          <SectionLabel>
            <span>How it works</span>
            <span className="h-px flex-1 bg-rule" />
          </SectionLabel>

          <Module>
            {FLOW.map(([n, title, detail]) => (
              <Row key={n} label={`${n} — ${title}`}>
                <p className="text-[13px] leading-relaxed text-ink-soft">
                  {detail}
                </p>
              </Row>
            ))}
          </Module>
        </section>

        {/* Honesty */}
        <section className="mt-16">
          <SectionLabel>
            <span>What this is not</span>
            <span className="h-px flex-1 bg-rule" />
          </SectionLabel>

          <Module>
            <Row label="Not Face ID">
              <p className="text-[13px] leading-relaxed text-ink-soft">
                Apple&rsquo;s Face ID projects roughly 30,000 infrared dots and
                matches a depth map. This matches a 2D image from your webcam.
                The liveness defense is a required blink, which stops a photo
                held up to the camera and will not stop a video of you. Treat it
                as a convenience over typing, not an upgrade over your password.
              </p>
            </Row>
            <Row label="Fails safe">
              <p className="text-[13px] leading-relaxed text-ink-soft">
                The PAM module returns only success or ignore, never an
                authentication error. Agent crashed, camera denied, face not
                recognized, socket missing — every one of those falls through to
                the normal password prompt. Breaking MacID cannot lock you out of
                your Mac.
              </p>
            </Row>
            <Row label="Single use">
              <p className="text-[13px] leading-relaxed text-ink-soft">
                A successful scan arms a token that lives ten seconds and is
                destroyed the moment PAM reads it. One scan cannot unlock twice,
                and unlocking clears it.
              </p>
            </Row>
            <Row label="Local only">
              <p className="text-[13px] leading-relaxed text-ink-soft">
                Recognition runs on-device through Vision. No image, no
                featureprint, and no telemetry leaves the machine. The camera
                indicator light is hardware-wired and stays on for exactly the
                window the camera is open.
              </p>
            </Row>
          </Module>
        </section>

        {/* Requirements */}
        <section className="mt-16">
          <SectionLabel>
            <span>Requirements</span>
            <span className="h-px flex-1 bg-rule" />
          </SectionLabel>

          <Module>
            <Row label="macOS">
              <p className="text-[13px] leading-relaxed text-ink-soft">
                14 or newer, Apple silicon. Verified on 26.5. The lock screen PAM
                stack is not a public API and has moved between releases, so a
                major update can break this — the repo ships a probe that tells
                you in a minute whether it still works.
              </p>
            </Row>
            <Row label="Toolchain">
              <p className="text-[13px] leading-relaxed text-ink-soft">
                Xcode command line tools.{" "}
                <code className="text-ink">xcode-select --install</code> if you
                do not have them. The installer builds from source rather than
                shipping a binary, because this puts a module into your
                authentication stack.
              </p>
            </Row>
          </Module>
        </section>

        {/* Commands */}
        <section className="mt-16">
          <SectionLabel>
            <span>Commands</span>
            <span className="h-px flex-1 bg-rule" />
          </SectionLabel>

          <Module>
            {COMMANDS.map(([cmd, desc]) => (
              <Row key={cmd}>
                <div className="flex flex-col gap-1 sm:flex-row sm:items-baseline sm:gap-6">
                  <code className="shrink-0 text-[13px] text-ink sm:w-52">
                    {cmd}
                  </code>
                  <span className="text-[13px] text-muted">{desc}</span>
                </div>
              </Row>
            ))}
          </Module>
        </section>

        <footer className="mt-16 flex flex-wrap items-baseline justify-between gap-4 border-t border-rule pt-5 text-[11px] uppercase tracking-[0.14em] text-muted-soft">
          <span>MacID — Akshith</span>
          <a
            href="/install.sh"
            className="transition-colors hover:text-ink"
          >
            Read the installer
          </a>
        </footer>
      </div>
    </main>
  );
}
