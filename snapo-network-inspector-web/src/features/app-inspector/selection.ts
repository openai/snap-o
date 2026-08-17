import type { AppInspectorOption, InspectableApp, SelectedAppInspector } from "../../network/bridge-types";

export function preferredInspector(
  app: InspectableApp,
  selection: SelectedAppInspector | null
): AppInspectorOption | undefined {
  const currentOption = app.inspectors.find(
    (option) =>
      app.id === selection?.appId &&
      option.kind === selection.kind &&
      option.server.deviceId === selection.server.deviceId &&
      option.server.socketName === selection.server.socketName
  );
  return currentOption ?? app.inspectors.find((option) => option.kind === selection?.kind) ?? app.inspectors[0];
}

export function reconcileInspectorSelection(
  apps: InspectableApp[],
  current: SelectedAppInspector | null
): SelectedAppInspector | null {
  if (current) {
    for (const app of apps) {
      const option = app.inspectors.find(
        (candidate) =>
          candidate.kind === current.kind &&
          candidate.server.deviceId === current.server.deviceId &&
          candidate.server.socketName === current.server.socketName
      );
      if (option) {
        return app.id === current.appId && option.protocolVersion === current.protocolVersion
          ? current
          : { ...current, appId: app.id, protocolVersion: option.protocolVersion };
      }
    }
    const app = apps.find((candidate) => candidate.id === current.appId);
    const option = app && preferredInspector(app, current);
    if (app && option) return { appId: app.id, ...option };
  }

  const app = apps.find((candidate) => candidate.inspectors.length > 0);
  return app ? { appId: app.id, ...app.inspectors[0] } : null;
}

export function isInspectorMetadataPending(selection: SelectedAppInspector, usesNativeServerPicker: boolean): boolean {
  return usesNativeServerPicker && selection.kind === "tweaks" && selection.protocolVersion == null;
}
