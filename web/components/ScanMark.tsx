/**
 * Line-art mark: a detection reticle over a radial burst.
 *
 * Drawn rather than illustrated — the rays are the geometry the recognizer
 * works in (spokes from a centroid out to landmark points) and the brackets are
 * the frame a face has to sit inside.
 */
export function ScanMark({ className = "" }: { className?: string }) {
  const rays = Array.from({ length: 12 }, (_, i) => (i * 180) / 12);

  return (
    <svg
      viewBox="0 0 200 200"
      className={className}
      fill="none"
      aria-hidden
      xmlns="http://www.w3.org/2000/svg"
    >
      <g stroke="currentColor" strokeWidth="1" opacity="0.45">
        {rays.map((angle, i) => {
          const rad = (angle * Math.PI) / 180;
          const len = i % 3 === 0 ? 58 : 42;
          return (
            <line
              x1={100 - Math.cos(rad) * len}
              y1={100 - Math.sin(rad) * len}
              x2={100 + Math.cos(rad) * len}
              y2={100 + Math.sin(rad) * len}
              key={angle}
            />
          );
        })}
      </g>

      <ellipse
        cx="100"
        cy="100"
        rx="33"
        ry="42"
        stroke="currentColor"
        strokeWidth="1"
        opacity="0.3"
      />

      <g stroke="currentColor" strokeWidth="1.5" opacity="0.85">
        <polyline points="44,70 44,44 70,44" />
        <polyline points="130,44 156,44 156,70" />
        <polyline points="156,130 156,156 130,156" />
        <polyline points="70,156 44,156 44,130" />
      </g>
    </svg>
  );
}
