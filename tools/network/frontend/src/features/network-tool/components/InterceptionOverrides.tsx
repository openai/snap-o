import type { JSX } from "preact";
import type { InterceptionRunner } from "../../../network/interception";

export function InterceptionOverrides({ runners }: { runners: InterceptionRunner[] }): JSX.Element | null {
  const routeCount = runners.reduce((count, runner) => count + runner.routes.length, 0);
  if (routeCount === 0) return null;

  return (
    <section className="interception-overrides" aria-label="Registered overrides">
      <details>
        <summary className="interception-summary">
          <span>Registered overrides</span>
          <span className="interception-status" role="status">
            {`${routeCount} ${routeCount === 1 ? "route" : "routes"} · ${runners.length} ${runners.length === 1 ? "runner" : "runners"}`}
          </span>
        </summary>
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
      </details>
    </section>
  );
}
