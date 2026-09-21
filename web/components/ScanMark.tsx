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
      <path fillRule="evenodd" d="M45 26h10a24 24 0 0 1 0 48H45V26Zm10 16a8 8 0 1 0 0 16 8 8 0 0 0 0-16Z" />
    </svg>
  );
}
