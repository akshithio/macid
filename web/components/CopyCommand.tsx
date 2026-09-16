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
        className="-mx-1.5 -mb-1.5 -mt-0.5 shrink-0 cursor-pointer p-1.5 text-muted transition-colors hover:text-ink"
        aria-label={copied ? "Copied" : "Copy install command"}
        title={copied ? "Copied" : "Copy"}
      >
        {copied ? <CheckIcon /> : <CopyIcon />}
      </button>
    </div>
  );
}

function CopyIcon() {
  return (
    <svg
      aria-hidden
      width="15"
      height="15"
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.25"
      strokeLinejoin="round"
    >
      <rect x="5.5" y="5.5" width="8" height="8" rx="1.5" />
      <path d="M10.5 3.5v-.5a1.5 1.5 0 0 0-1.5-1.5H4A1.5 1.5 0 0 0 2.5 3v5A1.5 1.5 0 0 0 4 9.5h.5" />
    </svg>
  );
}

function CheckIcon() {
  return (
    <svg
      aria-hidden
      width="15"
      height="15"
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.5"
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      <path d="M3 8.5l3.25 3.25L13 5" />
    </svg>
  );
}
