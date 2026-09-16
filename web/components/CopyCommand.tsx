"use client";

import { useState } from "react";

/**
 * The install line, laid out like the reference's email row: label cell, value
 * cell, action on the right. Copy state is per-viewer and momentary, so local
 * component state is the right home for it.
 */
export function CopyCommand({ command }: { command: string }) {
  const [copied, setCopied] = useState(false);

  async function copy() {
    try {
      await navigator.clipboard.writeText(command);
      setCopied(true);
      window.setTimeout(() => setCopied(false), 1600);
    } catch {
      // Clipboard can be blocked outright; the text is selectable either way,
      // so failing silently is better than an error the user cannot act on.
      setCopied(false);
    }
  }

  return (
    <div className="flex flex-col sm:flex-row sm:items-stretch">
      <div className="shrink-0 px-5 py-4 text-[11px] uppercase tracking-[0.14em] text-muted sm:w-36 sm:border-r sm:border-rule sm:px-6">
        Install
      </div>
      <div className="flex min-w-0 flex-1 items-center gap-4 border-t border-rule px-5 py-4 sm:border-t-0 sm:px-6">
        <code className="min-w-0 flex-1 whitespace-pre-wrap text-[12px] leading-relaxed text-ink-soft sm:text-[13px]">
          {command}
        </code>
        <button
          type="button"
          onClick={copy}
          className="shrink-0 cursor-pointer text-[11px] uppercase tracking-[0.14em] text-muted transition-colors hover:text-ink"
          aria-label="Copy install command"
        >
          {copied ? "Copied" : "Copy"}
        </button>
      </div>
    </div>
  );
}
