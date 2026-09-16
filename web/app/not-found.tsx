import Link from "next/link";
import { Grid } from "@/components/Grid";
import { Module, Row } from "@/components/Module";

export default function NotFound() {
  return (
    <main className="relative min-h-dvh overflow-hidden">
      <Grid />
      <div className="relative z-10 mx-auto flex min-h-dvh max-w-3xl flex-col justify-center px-4 sm:px-6">
        <Module>
          <Row>
            <div className="flex flex-wrap items-baseline justify-between gap-x-6 gap-y-2">
              <h1 className="text-[13px] uppercase tracking-[0.1em] text-ink sm:text-sm">
                Not found.
              </h1>
              <span className="text-[13px] tabular-nums text-muted-soft">404</span>
            </div>
          </Row>
          <Row label="Go back">
            <Link
              href="/"
              className="text-[13px] text-ink-soft underline-offset-4 transition-colors hover:text-ink hover:underline"
            >
              macid.akshith.io
            </Link>
          </Row>
        </Module>
      </div>
    </main>
  );
}
