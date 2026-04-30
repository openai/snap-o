import { app, shell } from "electron";
import { execFile } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { promisify } from "node:util";
import { XMLParser } from "fast-xml-parser";

const execFileAsync = promisify(execFile);
const AppcastUrl = "https://openai.github.io/snap-o/appcast.xml";
const SnapOCheckUpdatesUrl = "snapo://check-updates";
const SnapODefaultsDomain = "com.openai.snapo";
const SparkleAutoCheckKey = "SUEnableAutomaticChecks";
const DefaultsToolPath = "/usr/bin/defaults";

interface VersionInfo {
  version: string;
  buildNumber: string | null;
}

interface ElectronUpdatePreferences {
  promptedForSparklePermission?: boolean;
}

interface ParsedAppcastItem {
  title?: string;
  pubDate?: string;
  enclosure?: {
    url?: string;
  };
  "sparkle:shortVersionString"?: string;
  "sparkle:version"?: string;
}

interface AppcastItem {
  shortVersion: string | null;
  titleVersion: string | null;
  buildNumber: string | null;
  publishedAt: number | null;
}

type AutoCheckDecision = "enabled" | "disabled" | "promptHost";

type UpdateCheckSource = "auto" | "manual";

export class UpdateController {
  private checking = false;
  private hasTriggeredUpdate = false;

  constructor(private readonly onCheckingChange: () => void = () => {}) {}

  get isChecking(): boolean {
    return this.checking;
  }

  async runStartupCheck(): Promise<void> {
    const decision = await autoCheckDecision();
    if (decision === "disabled") return;
    if (decision === "promptHost") {
      await openHostUpdateUi();
      return;
    }
    await this.checkForUpdates("auto");
  }

  async checkForUpdates(source: UpdateCheckSource): Promise<void> {
    if (this.checking) return;
    this.setChecking(true);
    try {
      const versionInfo = loadVersionInfo();
      if (!(await updateIsAvailable(versionInfo))) return;
      if (source === "manual" || !this.hasTriggeredUpdate) {
        this.hasTriggeredUpdate = true;
        await openHostUpdateUi();
      }
    } finally {
      this.setChecking(false);
    }
  }

  private setChecking(value: boolean): void {
    this.checking = value;
    this.onCheckingChange();
  }
}

export function openHostUpdateUi(): Promise<void> {
  return shell.openExternal(SnapOCheckUpdatesUrl);
}

async function autoCheckDecision(): Promise<AutoCheckDecision> {
  const preference = await readSparkleAutoCheckPreference();
  if (preference != null) return preference ? "enabled" : "disabled";
  return markPromptedIfNeeded() ? "promptHost" : "disabled";
}

async function readSparkleAutoCheckPreference(): Promise<boolean | null> {
  if (process.platform !== "darwin") return null;
  try {
    const result = await execFileAsync(DefaultsToolPath, ["read", SnapODefaultsDomain, SparkleAutoCheckKey], {
      timeout: 1_000
    });
    return parseBooleanPreference(result.stdout);
  } catch {
    return null;
  }
}

function markPromptedIfNeeded(): boolean {
  const current = loadUpdatePreferences();
  if (current.promptedForSparklePermission === true) return false;
  saveUpdatePreferences({ ...current, promptedForSparklePermission: true });
  return true;
}

function loadUpdatePreferences(): ElectronUpdatePreferences {
  try {
    const raw = fs.readFileSync(updatePreferencesPath(), "utf8");
    return JSON.parse(raw) as ElectronUpdatePreferences;
  } catch {
    return {};
  }
}

function saveUpdatePreferences(preferences: ElectronUpdatePreferences): void {
  try {
    fs.mkdirSync(path.dirname(updatePreferencesPath()), { recursive: true });
    fs.writeFileSync(updatePreferencesPath(), `${JSON.stringify(preferences)}\n`, "utf8");
  } catch {
    // Failure here should degrade to a later re-prompt, not block startup.
  }
}

function updatePreferencesPath(): string {
  return path.join(app.getPath("userData"), "update-preferences.json");
}

function parseBooleanPreference(value: string): boolean | null {
  switch (value.trim().toLowerCase()) {
    case "1":
    case "true":
    case "yes":
      return true;
    case "0":
    case "false":
    case "no":
      return false;
    default:
      return null;
  }
}

function loadVersionInfo(): VersionInfo {
  for (const candidate of versionFileCandidates()) {
    const parsed = readVersionFile(candidate);
    if (parsed != null) return parsed;
  }
  return {
    version: app.getVersion(),
    buildNumber: null
  };
}

function versionFileCandidates(): string[] {
  return [path.join(process.resourcesPath, "VERSION"), path.resolve(app.getAppPath(), "../VERSION")];
}

function readVersionFile(filePath: string): VersionInfo | null {
  try {
    const entries = Object.fromEntries(
      fs
        .readFileSync(filePath, "utf8")
        .split(/\r?\n/)
        .map((line) => line.trim())
        .filter((line) => line.length > 0 && !line.startsWith("#"))
        .map((line) => line.split("=", 2).map((part) => part.trim()))
        .filter((parts): parts is [string, string] => parts.length === 2)
    );
    if (entries.VERSION == null) return null;
    return {
      version: entries.VERSION,
      buildNumber: entries.BUILD_NUMBER ?? null
    };
  } catch {
    return null;
  }
}

async function updateIsAvailable(current: VersionInfo): Promise<boolean> {
  try {
    const response = await fetch(AppcastUrl, {
      headers: { Accept: "application/rss+xml, application/xml, text/xml" },
      signal: AbortSignal.timeout(10_000)
    });
    if (!response.ok) return false;
    const latest = pickLatest(parseAppcast(await response.text()));
    if (latest == null) return false;
    return isNewerVersion(latest, current) === true;
  } catch {
    return false;
  }
}

function parseAppcast(xml: string): AppcastItem[] {
  const parser = new XMLParser({
    ignoreAttributes: false,
    attributeNamePrefix: "",
    parseAttributeValue: false,
    parseTagValue: false
  });
  const parsed = parser.parse(xml) as {
    rss?: {
      channel?: {
        item?: ParsedAppcastItem | ParsedAppcastItem[];
      };
    };
  };
  const items = parsed.rss?.channel?.item;
  return asArray(items).map((item) => ({
    shortVersion: stringOrNull(item["sparkle:shortVersionString"]),
    titleVersion: titleVersion(item.title),
    buildNumber: stringOrNull(item["sparkle:version"]),
    publishedAt: parsePublishedAt(item.pubDate)
  }));
}

function pickLatest(items: AppcastItem[]): AppcastItem | null {
  if (items.length === 0) return null;
  return [...items].sort(compareAppcastItems).at(-1) ?? null;
}

function compareAppcastItems(left: AppcastItem, right: AppcastItem): number {
  return (
    compareBuildNumbers(left.buildNumber, right.buildNumber) ??
    compareSemvers(left.shortVersion ?? left.titleVersion, right.shortVersion ?? right.titleVersion) ??
    compareNullableNumbers(left.publishedAt, right.publishedAt) ??
    0
  );
}

function isNewerVersion(latest: AppcastItem, current: VersionInfo): boolean | null {
  const buildComparison = compareBuildNumbers(latest.buildNumber, current.buildNumber);
  if (buildComparison != null) return buildComparison > 0;
  const semverComparison = compareSemvers(latest.shortVersion ?? latest.titleVersion, current.version);
  if (semverComparison != null) return semverComparison > 0;
  return null;
}

function compareBuildNumbers(left: string | null, right: string | null): number | null {
  const leftBuild = parseBuildNumber(left);
  const rightBuild = parseBuildNumber(right);
  if (leftBuild == null && rightBuild == null) return null;
  return compareTuples(leftBuild ?? [0, 0], rightBuild ?? [0, 0]);
}

function compareSemvers(left: string | null, right: string | null): number | null {
  const leftSemver = parseSemver(left);
  const rightSemver = parseSemver(right);
  if (leftSemver == null && rightSemver == null) return null;
  return compareTuples(leftSemver ?? [0, 0, 0], rightSemver ?? [0, 0, 0]);
}

function compareNullableNumbers(left: number | null, right: number | null): number | null {
  if (left == null && right == null) return null;
  return (left ?? 0) - (right ?? 0);
}

function parseBuildNumber(value: string | null): [number, number] | null {
  if (value == null || value.trim().length === 0) return null;
  const [major, minor = "0"] = value.trim().split(".", 2);
  const parsedMajor = Number.parseInt(major, 10);
  const parsedMinor = Number.parseInt(minor, 10);
  if (!Number.isFinite(parsedMajor) || !Number.isFinite(parsedMinor)) return null;
  return [parsedMajor, parsedMinor];
}

function parseSemver(value: string | null): [number, number, number] | null {
  if (value == null || value.trim().length === 0) return null;
  const clean = value.trim().split(/[-+]/, 1)[0];
  const parts = clean.split(".");
  const major = Number.parseInt(parts[0] ?? "", 10);
  const minor = Number.parseInt(parts[1] ?? "", 10);
  const patch = Number.parseInt(parts[2] ?? "0", 10);
  if (![major, minor, patch].every(Number.isFinite)) return null;
  return [major, minor, patch];
}

function compareTuples(left: number[], right: number[]): number {
  for (let index = 0; index < Math.max(left.length, right.length); index += 1) {
    const difference = (left[index] ?? 0) - (right[index] ?? 0);
    if (difference !== 0) return difference;
  }
  return 0;
}

function parsePublishedAt(value: string | undefined): number | null {
  if (value == null) return null;
  const timestamp = Date.parse(value);
  return Number.isFinite(timestamp) ? timestamp : null;
}

function titleVersion(title: string | undefined): string | null {
  if (title == null) return null;
  return title.trim().split(/\s+/).at(-1) ?? null;
}

function stringOrNull(value: unknown): string | null {
  return typeof value === "string" && value.trim().length > 0 ? value.trim() : null;
}

function asArray<T>(value: T | T[] | undefined): T[] {
  if (value == null) return [];
  return Array.isArray(value) ? value : [value];
}
