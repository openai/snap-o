import { useCallback, useMemo, useState } from "react";

interface InspectorUiPreferences {
  sections: Record<string, boolean>;
  pretty: Record<string, boolean>;
  json: Record<string, boolean>;
}

export interface InspectorUiState {
  sectionExpanded(key: string, fallback?: boolean): boolean;
  setSectionExpanded(key: string, value: boolean): void;
  prettyEnabled(key: string, fallback: boolean): boolean;
  setPrettyEnabled(key: string, value: boolean): void;
  jsonExpanded(key: string, fallback: boolean): boolean;
  setJsonExpanded(key: string, value: boolean): void;
}

export function useInspectorUiState(): InspectorUiState {
  const [prefs, setPrefs] = useState<InspectorUiPreferences>(emptyInspectorUiPreferences);

  const sectionExpanded = useCallback(
    (key: string, fallback = true) => prefs.sections[key] ?? fallback,
    [prefs.sections]
  );
  const setSectionExpanded = useCallback(
    (key: string, value: boolean) =>
      setPrefs((current) => ({ ...current, sections: { ...current.sections, [key]: value } })),
    []
  );
  const prettyEnabled = useCallback((key: string, fallback: boolean) => prefs.pretty[key] ?? fallback, [prefs.pretty]);
  const setPrettyEnabled = useCallback(
    (key: string, value: boolean) =>
      setPrefs((current) => ({ ...current, pretty: { ...current.pretty, [key]: value } })),
    []
  );
  const jsonExpanded = useCallback((key: string, fallback: boolean) => prefs.json[key] ?? fallback, [prefs.json]);
  const setJsonExpanded = useCallback(
    (key: string, value: boolean) => setPrefs((current) => ({ ...current, json: { ...current.json, [key]: value } })),
    []
  );

  return useMemo(
    () => ({
      sectionExpanded,
      setSectionExpanded,
      prettyEnabled,
      setPrettyEnabled,
      jsonExpanded,
      setJsonExpanded
    }),
    [jsonExpanded, prettyEnabled, sectionExpanded, setJsonExpanded, setPrettyEnabled, setSectionExpanded]
  );
}

function emptyInspectorUiPreferences(): InspectorUiPreferences {
  return { sections: {}, pretty: {}, json: {} };
}
