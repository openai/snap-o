import type { JSX } from "preact";
import { useEffect, useState } from "preact/hooks";
import { LoadingSpinner } from "../../../components/LoadingSpinner";

export function InspectorWaitingState({ error }: { error?: string | null }): JSX.Element | null {
  const [showIndicator, setShowIndicator] = useState(false);
  useEffect(() => {
    const timer = setTimeout(() => setShowIndicator(true), 300);
    return () => clearTimeout(timer);
  }, []);
  if (!showIndicator && !error) return null;

  const label = "Waiting for inspector";
  return (
    <div className="inspector-loading">
      <div className="inspector-loading-status" role="status" aria-label={label}>
        <span>{label}</span>
        <LoadingSpinner size={20} />
      </div>
      {error ? (
        <p className="inspector-open-error" role="alert">
          {error}
        </p>
      ) : null}
    </div>
  );
}
