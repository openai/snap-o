import type { JSX } from "preact";
import type { InterceptionState } from "../../../network/interception";

export function InterceptionOverrides({ state }: { state: InterceptionState }): JSX.Element {
  const runners = state.status === "live" ? state.runners : [];
  const routeCount = runners.reduce((count, runner) => count + runner.routes.length, 0);
  const { statusText, note } =
    state.status === "live"
      ? {
          statusText: `${routeCount} ${routeCount === 1 ? "route" : "routes"} · ${runners.length} ${runners.length === 1 ? "runner" : "runners"}`,
          note: routeCount === 0 ? "No overrides registered." : "Managed by the CLI."
        }
      : statusCopy[state.status];

  return (
    <section className="interception-overrides" aria-label="Registered overrides">
      <details open>
        <summary className="interception-summary">
          <span>Registered overrides</span>
          <span className="interception-status" role="status">
            {statusText}
          </span>
        </summary>
        <div className="interception-content">
          <p className="interception-note">{note}</p>
          {runners.map((runner) => (
            <div className="interception-runner" key={runner.id}>
              <div className="interception-runner-name" title={runner.id}>
                Runner {runner.id.slice(0, 8)}
              </div>
              <ul className="interception-routes">
                {runner.routes.map((route) => (
                  <li className="interception-route" key={route.id}>
                    <span className="interception-method">{route.method}</span>
                    <span className="interception-path">{route.path}</span>
                  </li>
                ))}
              </ul>
            </div>
          ))}
        </div>
      </details>
    </section>
  );
}

const statusCopy = {
  disconnected: { statusText: "App disconnected", note: "Connect to an app to see its live overrides." },
  connecting: { statusText: "Connecting…", note: "Waiting for the app's registered overrides." },
  unavailable: { statusText: "Override status unavailable", note: "Could not read live overrides from this app." }
};
