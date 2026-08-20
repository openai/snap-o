import type { SelectedAppInspector } from "../../network/bridge-types";

export function isInspectorMetadataPending(selection: SelectedAppInspector, usesNativeServerPicker: boolean): boolean {
  return usesNativeServerPicker && selection.kind === "tweaks" && selection.protocolVersion == null;
}
