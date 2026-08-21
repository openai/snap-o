import { LoaderCircle } from "lucide-react";

export function InspectorWaitingState(): JSX.Element {
  const label = "Waiting for inspector";
  return (
    <div className="inspector-loading" role="status" aria-label={label}>
      <span>{label}</span>
      <LoaderCircle className="body-loading-spinner" size={20} aria-hidden="true" />
    </div>
  );
}
