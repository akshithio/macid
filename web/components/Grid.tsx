/**
 * The blueprint grid behind everything.
 *
 * Each rule is a gradient rather than a solid border so it fades out toward the
 * edges of the viewport — the lines read as a drafting underlay rather than as
 * a table. Purely decorative, so it is hidden from assistive tech.
 */
export function Grid() {
  const columns = [8, 30, 70, 92];
  const rows = [14, 86];

  return (
    <div aria-hidden className="pointer-events-none fixed inset-0 z-0">
      {columns.map((left) => (
        <div
          key={`c-${left}`}
          className="absolute top-0 h-full w-px"
          style={{
            left: `${left}%`,
            backgroundImage:
              "linear-gradient(to bottom, transparent, var(--color-rule) 20%, var(--color-rule) 80%, transparent)",
          }}
        />
      ))}
      {rows.map((top) => (
        <div
          key={`r-${top}`}
          className="absolute left-0 h-px w-full"
          style={{
            top: `${top}%`,
            backgroundImage:
              "linear-gradient(to right, transparent, var(--color-rule) 20%, var(--color-rule) 80%, transparent)",
          }}
        />
      ))}
    </div>
  );
}
