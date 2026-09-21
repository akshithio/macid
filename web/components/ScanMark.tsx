/**
 * The MacID monogram: an I and a D, the D's counter a lens two units clear of
 * its left edge.
 *
 * No tile here. The tile belongs to the app icon, where macOS expects a
 * rounded square; on the page the mark is the glyph alone in the current text
 * colour, which is what the light lockup resolves to anyway.
 *
 * Geometry matches tools/make-icons.swift exactly — the same 100-unit grid,
 * cropped to the glyph. The menu bar deliberately differs; see BrandMark.
 */
export function ScanMark({ className = "" }: { className?: string }) {
  return (
    <svg
      viewBox="23 26 56 48"
      className={className}
      fill="currentColor"
      aria-hidden
      xmlns="http://www.w3.org/2000/svg"
    >
      <rect x="23" y="26" width="13" height="48" rx="6.5" />
      {/* The counter is a hole in the D, not a shape laid over it, so the two
          can never drift out of register. */}
      <path fillRule="evenodd" d="M45 26h10a24 24 0 0 1 0 48H45V26Zm10 16a8 8 0 1 0 0 16 8 8 0 0 0 0-16Z" />
    </svg>
  );
}
