import { LoadingSpinner } from "../../../components/LoadingSpinner";
import type { InspectableApp } from "../../../network/bridge-types";
import type { AppLaunchControl } from "../useAppLaunch";
import { OpenAppButton } from "./OpenAppButton";

export function InspectorWaitingState({
  launch,
  app,
  error
}: {
  launch?: AppLaunchControl | null;
  app?: InspectableApp | null;
  error?: string | null;
}): JSX.Element {
  const label = "Waiting for inspector";
  const canOpenApp = app != null && launch != null;
  return (
    <div className="inspector-loading">
      <div className="inspector-loading-status" role="status" aria-label={label}>
        <span>{label}</span>
        {!canOpenApp ? <LoadingSpinner size={20} /> : null}
      </div>
      {app && launch ? <OpenAppButton app={app} launch={launch} /> : null}
      {error ? (
        <p className="inspector-open-error" role="alert">
          {error}
        </p>
      ) : null}
    </div>
  );
}
