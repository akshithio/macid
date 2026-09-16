"use client";

import { useState } from "react";

/**
 * The install line, and the only thing on the page you are meant to act on.
 *
 * The command wraps at spaces rather than scrolling or truncating: a half-shown
 * curl command is a trap, and there is no horizontal room to spare on a phone.
 */
export function CopyCommand({ command }: { command: string }) {
  const [copied, setCopied] = useState(false);

  async function copy() {
    try {
      await navigator.clipboard.writeText(command);
      setCopied(true);
      window.setTimeout(() => setCopied(false), 1600);
    } catch {
      // Clipboard access can be blocked outright. The text is selectable
      // either way, so failing quietly beats an error nobody can act on.
      setCopied(false);
    }
  }

  return (
    <div className="flex items-start gap-3 border border-rule bg-field px-4 py-3.5 sm:gap-4 sm:px-5">
      <span aria-hidden className="select-none pt-px text-[13px] text-muted">
        $
      </span>
      <code className="min-w-0 flex-1 whitespace-pre-wrap text-[13px] leading-[1.7] text-ink">
        {command}
      </code>
      <button
        type="button"
        onClick={copy}
        className="shrink-0 cursor-pointer pt-px text-[11px] tracking-[0.08em] text-muted transition-colors hover:text-ink"
        aria-label="Copy install command"
      >
        {copied ? "copied" : "copy"}
      </button>
    </div>
  );
}
