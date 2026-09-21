import Link from "next/link";

export default function NotFound() {
  return (
    <main className="flex min-h-dvh flex-col items-center justify-center px-5 sm:px-6">
      <div className="w-full max-w-[34rem]">
        <h1 className="text-[15px] text-ink">Not found.</h1>
        <p className="mt-3 text-[12.5px] text-muted">
          <Link href="/" className="transition-colors hover:text-ink">
            macid.akshith.io
          </Link>
        </p>
      </div>
    </main>
  );
}
