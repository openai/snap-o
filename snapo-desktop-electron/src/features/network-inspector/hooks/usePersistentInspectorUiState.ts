import { useCallback, useEffect, useMemo, useState } from "react";

const inspectorUiStorageKey = "snapo.networkInspector.ui.v1";

interface InspectorUiPreferences {
  sections: Record<string, boolean>;
  pretty: Record<string, boolean>;
  json: Record<string, boolean>;
}

export interface PersistentInspectorUiState {
  sectionExpanded(key: string): boolean;
  setSectionExpanded(key: string, value: boolean): void;
  prettyEnabled(key: string, fallback: boolean): boolean;
  setPrettyEnabled(key: string, value: boolean): void;
  jsonExpanded(key: string, fallback: boolean): boolean;
  setJsonExpanded(key: string, value: boolean): void;
}

export function usePersistentInspectorUiState(): PersistentInspectorUiState {
  const [prefs, setPrefs] = useState<InspectorUiPreferences>(loadInspectorUiPreferences);

  useEffect(() => {
    window.localStorage.setItem(inspectorUiStorageKey, JSON.stringify(prefs));
  }, [prefs]);

  const sectionExpanded = useCallback((key: string) => prefs.sections[key] ?? true, [prefs.sections]);
  const setSectionExpanded = useCallback(
    (key: string, value: boolean) => setPrefs((current) => ({ ...current, sections: { ...current.sections, [key]: value } })),
    []
  );
  const prettyEnabled = useCallback((key: string, fallback: boolean) => prefs.pretty[key] ?? fallback, [prefs.pretty]);
  const setPrettyEnabled = useCallback(
    (key: string, value: boolean) => setPrefs((current) => ({ ...current, pretty: { ...current.pretty, [key]: value } })),
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

function loadInspectorUiPreferences(): InspectorUiPreferences {
  try {
    const raw = window.localStorage.getItem(inspectorUiStorageKey);
    if (raw == null) return emptyInspectorUiPreferences();
    const parsed = JSON.parse(raw) as Partial<InspectorUiPreferences>;
    return {
      sections: parsed.sections ?? {},
      pretty: parsed.pretty ?? {},
      json: parsed.json ?? {}
    };
  } catch {
    return emptyInspectorUiPreferences();
  }
}

function emptyInspectorUiPreferences(): InspectorUiPreferences {
  return { sections: {}, pretty: {}, json: {} };
}
