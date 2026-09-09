import type { SelectedAppInspector } from "../../network/bridge-types";

export function isInspectorMetadataPending(selection: SelectedAppInspector): boolean {
  return selection.kind === "tweaks" && selection.protocolVersion == null;
}
