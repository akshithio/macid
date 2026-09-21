import { Download } from "@/components/Download";
import { Faq } from "@/components/Faq";
import { ScanMark } from "@/components/ScanMark";
import { downloadCount } from "@/lib/downloads";

const FAQ = [
  {
    q: "Can a photo unlock it?",
    a: "Yes, a good enough one can. Turn on Require a blink in the app to stop a still photo, though not a video.",
  },
  {
    q: "What if it breaks?",
    a: "You type your password, like before. If anything gets in the way, the lock screen just asks for it.",
  },
  {
    q: "Where does my password go?",
    a: "Nowhere. It stays on your Mac, encrypted by the Secure Enclave, and only unlocks your Keychain after MacID lets you in.",
  },
  {
    q: "How do I uninstall?",
    a: "Click Uninstall in the app to remove everything. Dragging it to the Trash is safe too.",
  },
];

export default async function Home() {
  const count = await downloadCount();

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
          <Download count={count} />
        </div>

        <p className="mt-8 border-t border-rule pt-6 text-[12.5px] leading-[1.75] text-muted">
          A good photo of your face could unlock MacID. Turn on Require a blink
          in the app to stop that. If anything fails, you get the normal
          password prompt. Recognition runs on device. Nothing leaves your Mac.
        </p>

        <a
          href="https://akshith.io/notes/macid"
          target="_blank"
          rel="noreferrer"
          className="group mt-6 flex items-baseline justify-between gap-4 border-y border-rule py-3.5 text-[13px] leading-snug transition-colors hover:border-ink/30"
        >
          <span>
            <span className="block text-[11px] tracking-[0.08em] text-muted">
              HOW IT WORKS
            </span>
            <span className="mt-1 block text-ink">
              MacID: Bringing Face ID to the Mac
            </span>
          </span>
          <span
            aria-hidden
            className="text-ink transition-transform group-hover:translate-x-0.5"
          >
            &rarr;
          </span>
        </a>

        <section className="mt-10">
          <h2 className="text-[11px] tracking-[0.08em] text-muted">FAQ</h2>
          <Faq items={FAQ} />
        </section>

        <footer className="mt-10 flex flex-wrap items-baseline gap-x-5 gap-y-2 text-[11px] tracking-[0.08em] text-muted">
          <a href="/privacy" className="transition-colors hover:text-ink">
            privacy
          </a>
          <span className="text-rule">/</span>
          <a
            href="https://github.com/akshithio/macid"
            target="_blank"
            rel="noreferrer"
            className="transition-colors hover:text-ink"
          >
            github
          </a>
          <span className="text-rule">/</span>
          <span>MIT</span>
        </footer>
      </div>
    </main>
  );
}
