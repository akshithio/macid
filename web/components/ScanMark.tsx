/**
 * Line-art mark: a detection reticle over a radial burst.
 *
 * Drawn rather than illustrated — the burst is the same geometry the recognizer
 * works in (rays from a centroid out to landmark points), and the corner
 * brackets are the frame a face has to sit inside. Decorative, but not
 * arbitrary.
 */
export function ScanMark({ className = "" }: { className?: string }) {
  const rays = Array.from({ length: 14 }, (_, i) => (i * 180) / 14);

  return (
    <svg
      viewBox="0 0 200 200"
      className={className}
      fill="none"
      aria-hidden
      xmlns="http://www.w3.org/2000/svg"
    >
      <g stroke="currentColor" strokeWidth="0.75" opacity="0.55">
        {rays.map((angle, i) => {
          const rad = (angle * Math.PI) / 180;
          const len = i % 3 === 0 ? 62 : 46;
          const x = Math.cos(rad) * len;
          const y = Math.sin(rad) * len;
          return (
            <line
              key={angle}
              x1={100 - x}
              y1={100 - y}
              x2={100 + x}
              y2={100 + y}
            />
          );
        })}
      </g>

      <g stroke="currentColor" strokeWidth="0.75" opacity="0.35">
        <ellipse cx="100" cy="100" rx="34" ry="44" />
        <ellipse cx="100" cy="100" rx="52" ry="52" />
      </g>

      {/* Detection brackets. */}
      <g stroke="currentColor" strokeWidth="1.25" opacity="0.9">
        <polyline points="42,68 42,42 68,42" />
        <polyline points="132,42 158,42 158,68" />
        <polyline points="158,132 158,158 132,158" />
        <polyline points="68,158 42,158 42,132" />
      </g>

      <g stroke="currentColor" strokeWidth="0.75" opacity="0.5">
        <line x1="42" y1="100" x2="52" y2="100" />
        <line x1="148" y1="100" x2="158" y2="100" />
      </g>
    </svg>
  );
}
