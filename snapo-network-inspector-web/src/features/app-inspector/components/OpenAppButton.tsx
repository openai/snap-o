import { LoadingSpinner } from "../../../components/LoadingSpinner";
import type { InspectableApp } from "../../../network/bridge-types";
import type { AppLaunchControl } from "../useAppLaunch";

export function OpenAppButton({ app, launch }: { app: InspectableApp; launch: AppLaunchControl }): JSX.Element {
  return (
    <>
      {launch.pending ? (
        <span className="inspector-open-progress" role="progressbar" aria-label={`Opening ${app.name}`}>
          <LoadingSpinner size={20} />
        </span>
      ) : (
        <button className="inspector-open-app" type="button" onClick={launch.open}>
          Open {app.name}
        </button>
      )}
      {launch.error ? (
        <p className="inspector-open-error" role="alert">
          {launch.error}
        </p>
      ) : null}
    </>
  );
}
