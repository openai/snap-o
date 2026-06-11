export function parseVersionInfo(contents, source = "VERSION") {
  const entries = Object.fromEntries(
    contents
      .split(/\r?\n/u)
      .map((line) => line.trim())
      .filter((line) => line.length > 0 && !line.startsWith("#"))
      .map((line) => line.split("=", 2).map((part) => part.trim()))
      .filter((parts) => parts.length === 2)
  );
  if (entries.VERSION == null) throw new Error(`Missing VERSION in ${source}`);
  return {
    version: entries.VERSION,
    buildNumber: entries.BUILD_NUMBER ?? null
  };
}
