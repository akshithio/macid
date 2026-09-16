import type { ReactNode } from "react";

/**
 * The bordered module the whole page is built from: a hairline box divided into
 * full-width rows, each row optionally split into a fixed label cell and a
 * content cell. Everything on the page is one of these, which is what keeps the
 * layout feeling like a single printed form rather than a stack of cards.
 */
export function Module({ children }: { children: ReactNode }) {
  return (
    <div className="border border-rule divide-y divide-rule bg-paper">
      {children}
    </div>
  );
}

export function Row({
  label,
  children,
  className = "",
}: {
  label?: string;
  children: ReactNode;
  className?: string;
}) {
  if (!label) {
    return <div className={`px-5 py-4 sm:px-6 ${className}`}>{children}</div>;
  }

  return (
    <div className={`flex flex-col sm:flex-row sm:items-stretch ${className}`}>
      <div className="shrink-0 px-5 py-4 text-[11px] uppercase tracking-[0.14em] text-muted sm:w-44 sm:border-r sm:border-rule sm:px-6">
        {label}
      </div>
      <div className="min-w-0 flex-1 border-t border-rule px-5 py-4 sm:border-t-0 sm:px-6">
        {children}
      </div>
    </div>
  );
}

export function SectionLabel({ children }: { children: ReactNode }) {
  return (
    <div className="mb-3 flex items-baseline gap-3 text-[11px] uppercase tracking-[0.14em] text-muted-soft">
      {children}
    </div>
  );
}
