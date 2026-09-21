"use client";

import { useState } from "react";

export function Faq({ items }: { items: { q: string; a: string }[] }) {
  const [open, setOpen] = useState<string | null>(null);

  return (
    <div className="mt-3 border-t border-rule text-[12.5px] leading-[1.75]">
      {items.map(({ q, a }) => {
        const expanded = open === q;
        return (
          <div key={q} className="border-b border-rule">
            <button
              type="button"
              aria-expanded={expanded}
              onClick={() => setOpen(expanded ? null : q)}
              className="flex w-full cursor-pointer items-baseline justify-between gap-4 py-3 text-left text-ink"
            >
              {q}
              <span
                aria-hidden
                className={`inline-block text-muted transition-transform duration-300 ease-[cubic-bezier(0.2,0.8,0.2,1)] ${
                  expanded ? "rotate-45" : ""
                }`}
              >
                +
              </span>
            </button>
            <div
              className={`grid transition-[grid-template-rows] duration-300 ease-[cubic-bezier(0.2,0.8,0.2,1)] motion-reduce:transition-none ${
                expanded ? "grid-rows-[1fr]" : "grid-rows-[0fr]"
              }`}
            >
              <div className="overflow-hidden">
                <p
                  className={`pb-3.5 text-muted transition-[opacity,translate] duration-300 ease-[cubic-bezier(0.2,0.8,0.2,1)] motion-reduce:transition-none ${
                    expanded ? "translate-y-0 opacity-100" : "-translate-y-1 opacity-0"
                  }`}
                >
                  {a}
                </p>
              </div>
            </div>
          </div>
        );
      })}
    </div>
  );
}
