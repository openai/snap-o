import type { JSX } from "preact";
export function LoadingSpinner({ size }: { size: number }): JSX.Element {
  return (
    <span className="body-loading-spinner" aria-hidden="true">
      <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2}>
        <circle cx={12} cy={12} r={9} strokeLinecap="round" />
      </svg>
    </span>
  );
}
