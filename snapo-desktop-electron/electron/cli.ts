import { gunzipSync } from "node:zlib";
import { AdbClient, type Device } from "./adb.js";
import { SnapOLinkConnection, type HelloRecord, type SnapORecord } from "./snapo-link.js";
import { parseSnapOSockets, pidFromSocketName } from "./server-utils.js";
import type { CdpMessage } from "../src/network/bridge-types.js";

type OutputMode = "human" | "json";

interface DeviceSelectionOptions {
  serialId: string | null;
  useUsbDevice: boolean;
  useEmulator: boolean;
}

interface ServerRef {
  deviceId: string;
  socketName: string;
}

interface ServerAppInfo {
  packageName: string | null;
  appName: string | null;
}

interface CliOptions extends DeviceSelectionOptions {
  json: boolean;
}

interface NetworkRequestsOptions extends CliOptions {
  socketName: string | null;
  noStream: boolean;
}

interface NetworkShowOptions extends CliOptions {
  socketName: string | null;
  requestId: string | null;
}

interface RequestDetailsSnapshot {
  requestSeen: boolean;
  requestHasPostData: boolean;
  requestMethod: string | null;
  requestUrl: string | null;
  requestHeaders: Record<string, string>;
  requestBodyEncoding: string | null;
  responseSeen: boolean;
  responseTerminal: boolean;
  loadingFailedMessage: string | null;
  responseStatus: number | null;
  responseUrl: string | null;
  responseHeaders: Record<string, string>;
}

type FetchRequestDetailsResult =
  | {
      kind: "success";
      requestMethod: string | null;
      requestUrl: string | null;
      requestHeaders: Record<string, string>;
      requestBodyEncoding: string | null;
      requestBody: string | null;
      responseStatus: number | null;
      responseUrl: string | null;
      responseHeaders: Record<string, string>;
      responseBody: string;
      responseBodyBase64Encoded: boolean;
    }
  | { kind: "missingBody"; message: string }
  | { kind: "failure"; message: string };

const NetworkFeatureId = "network";
const SnapshotQuietPeriodMs = 300;
const SnapshotMaxWaitMs = 5_000;
const CommandResponseTimeoutMs = 500;
const CommandAttemptLimit = 3;
const HelloWaitTimeoutMs = 1_200;
const RedactedValue = "[REDACTED]";
const RequestHeaderNames = new Set(["authorization", "cookie"]);
const ResponseHeaderNames = new Set(["set-cookie"]);

export async function runCli(args: string[]): Promise<number> {
  if (args.length === 0 || isHelpFlag(args[0])) {
    printRootHelp();
    return 0;
  }

  if (args[0] !== "network") {
    printError(`Unknown command '${args[0]}'`);
    printRootHelp();
    return 2;
  }

  return runNetworkCommand(args.slice(1));
}

async function runNetworkCommand(args: string[]): Promise<number> {
  const subcommand = args[0];
  if (subcommand == null || isHelpFlag(subcommand)) {
    printNetworkHelp();
    return 0;
  }

  try {
    switch (subcommand) {
      case "list":
        if (containsHelpFlag(args.slice(1))) {
          printNetworkListHelp();
          return 0;
        }
        return runNetworkList(parseNetworkListOptions(args.slice(1)));
      case "requests":
        if (containsHelpFlag(args.slice(1))) {
          printNetworkRequestsHelp();
          return 0;
        }
        return runNetworkRequests(parseNetworkRequestsOptions(args.slice(1)));
      case "show":
        if (containsHelpFlag(args.slice(1))) {
          printNetworkShowHelp();
          return 0;
        }
        return runNetworkShow(parseNetworkShowOptions(args.slice(1)));
      default:
        printError(`Unknown network command '${subcommand}'`);
        printNetworkHelp();
        return 2;
    }
  } catch (error) {
    printError(errorMessage(error));
    return 2;
  }
}

async function runNetworkList(options: CliOptions & { includeAppInfo: boolean }): Promise<number> {
  const adb = new AdbClient();
  const discovery = await discoverServers(adb, options);
  if (discovery.kind === "failure") return fail(discovery.message);
  if (discovery.servers.length === 0) return fail("No Snap-O link servers found");

  const appInfoByServer = options.includeAppInfo
    ? await Promise.all(
        discovery.servers.map(
          async (server) => [serverIdentifier(server), await resolveServerAppInfo(adb, server)] as const
        )
      ).then((entries) => new Map(entries))
    : null;

  if (options.json) {
    for (const server of discovery.servers) {
      const appInfo = appInfoByServer?.get(serverIdentifier(server));
      printJson({
        server: serverIdentifier(server),
        deviceId: server.deviceId,
        socketName: server.socketName,
        packageName: appInfo?.packageName ?? null,
        appName: appInfo?.appName ?? null
      });
    }
    return 0;
  }

  emitServerListHuman(discovery.servers, appInfoByServer);
  return 0;
}

async function runNetworkRequests(options: NetworkRequestsOptions): Promise<number> {
  const adb = new AdbClient();
  const resolved = await resolveServer(adb, options.socketName, options);
  if (resolved.kind === "failure") return fail(resolved.message);

  const session = await CliSession.open(adb, resolved.server);
  if (session == null) return fail(`Failed to connect to ${serverIdentifier(resolved.server)}`);

  try {
    const outputMode: OutputMode = options.json ? "json" : "human";
    if (options.noStream) {
      const completed = await runSnapshotRequests(session, outputMode);
      if (!completed) return fail(`Timed out waiting for handshake from ${serverIdentifier(resolved.server)}`);
    } else {
      await runStreamingRequests(session, outputMode);
    }
    return 0;
  } finally {
    session.close();
  }
}

async function runNetworkShow(options: NetworkShowOptions): Promise<number> {
  if (options.requestId == null || options.requestId.trim().length === 0) {
    return fail("Please specify a request ID with -r/--request-id");
  }

  const adb = new AdbClient();
  const resolved = await resolveServer(adb, options.socketName, options);
  if (resolved.kind === "failure") return fail(resolved.message);

  const result = await fetchRequestDetails(adb, resolved.server, options.requestId);
  if (result.kind !== "success") return fail(result.message);

  emitRequestDetails(
    {
      server: serverIdentifier(resolved.server),
      requestId: options.requestId,
      requestMethod: result.requestMethod,
      requestUrl: result.requestUrl,
      requestHeaders: result.requestHeaders,
      requestBodyEncoding: result.requestBodyEncoding,
      requestBody: result.requestBody,
      responseStatus: result.responseStatus,
      responseUrl: result.responseUrl,
      responseHeaders: result.responseHeaders,
      responseBody: result.responseBody,
      responseBodyBase64Encoded: result.responseBodyBase64Encoded
    },
    options.json ? "json" : "human"
  );
  return 0;
}

async function runSnapshotRequests(session: CliSession, outputMode: OutputMode): Promise<boolean> {
  let featureOpenedAtMs: number | null = null;
  let lastNetworkEventMs: number | null = null;
  const startedAtMs = Date.now();

  while (true) {
    const now = Date.now();
    if (featureOpenedAtMs == null && now - startedAtMs >= SnapshotMaxWaitMs) return false;
    const waitMs = snapshotWaitMs(now, featureOpenedAtMs, lastNetworkEventMs);
    const record = await session.nextRecord(waitMs);
    if (record == null) {
      if (session.closed) return featureOpenedAtMs != null;
      if (featureOpenedAtMs == null) continue;
      const resolvedLastNetworkAt = lastNetworkEventMs ?? featureOpenedAtMs;
      const quietForMs = now - resolvedLastNetworkAt;
      const elapsedMs = now - featureOpenedAtMs;
      if (quietForMs >= SnapshotQuietPeriodMs || elapsedMs >= SnapshotMaxWaitMs) return true;
      continue;
    }

    if (record.kind === "hello" && featureOpenedAtMs == null) {
      session.sendFeatureOpened(NetworkFeatureId);
      featureOpenedAtMs = Date.now();
    }

    if (record.kind === "network") {
      emitNetworkEvent(sanitizeMessage(record.value), outputMode);
      lastNetworkEventMs = Date.now();
    }
  }
}

async function runStreamingRequests(session: CliSession, outputMode: OutputMode): Promise<void> {
  let featureOpened = false;
  while (true) {
    const record = await session.nextRecord();
    if (record == null) return;
    if (record.kind === "hello" && !featureOpened) {
      session.sendFeatureOpened(NetworkFeatureId);
      featureOpened = true;
    }
    if (record.kind === "network") {
      emitNetworkEvent(sanitizeMessage(record.value), outputMode);
    }
  }
}

async function fetchRequestDetails(
  adb: AdbClient,
  server: ServerRef,
  requestId: string
): Promise<FetchRequestDetailsResult> {
  const session = await CliSession.open(adb, server);
  if (session == null) {
    return { kind: "failure", message: `Failed to connect to ${serverIdentifier(server)}` };
  }

  try {
    let featureOpened = false;
    let commandId = 1;
    let pendingRequestBodyId: number | null = null;
    let pendingResponseBodyId: number | null = null;
    let requestBodyAttempts = 0;
    let responseBodyAttempts = 0;
    const startedAtMs = Date.now();
    let details = emptyRequestDetailsSnapshot();
    let requestBody: string | null = null;
    let requestBodyEncoding: string | null = null;
    let requestBodyResolved = false;
    let responseBody: string | null = null;
    let responseBodyBase64Encoded = false;
    let responseBodyResolved = false;

    while (true) {
      const record = await session.nextRecord(CommandResponseTimeoutMs);
      if (record == null) {
        if (!featureOpened) {
          if (Date.now() - startedAtMs >= SnapshotMaxWaitMs) {
            return { kind: "failure", message: `Timed out waiting for handshake from ${serverIdentifier(server)}` };
          }
          continue;
        }
        pendingRequestBodyId = null;
        pendingResponseBodyId = null;
      } else if (record.kind === "hello") {
        if (!featureOpened) {
          session.sendFeatureOpened(NetworkFeatureId);
          featureOpened = true;
        }
      } else if (record.kind === "network") {
        const message = record.value;
        details = updateRequestDetailsSnapshot(details, message, requestId);
        requestBodyEncoding ??= details.requestBodyEncoding;
        if (!requestBodyResolved && details.requestSeen && !details.requestHasPostData) {
          requestBodyResolved = true;
        }
        if (shouldResolveEmptyResponseBody(responseBodyResolved, details)) {
          responseBody = "";
          responseBodyBase64Encoded = false;
          responseBodyResolved = true;
        }
        if (details.responseTerminal && !details.responseSeen) {
          return {
            kind: "failure",
            message: details.loadingFailedMessage ?? `Request failed before receiving a response for ${requestId}`
          };
        }

        if (message.id != null && message.method == null) {
          if (message.id === pendingRequestBodyId) {
            pendingRequestBodyId = null;
            requestBody = stringField(message.result, "postData");
            requestBodyResolved = true;
          } else if (message.id === pendingResponseBodyId) {
            pendingResponseBodyId = null;
            if (message.error != null) {
              if (details.loadingFailedMessage != null && details.loadingFailedMessage.trim().length > 0) {
                return { kind: "failure", message: details.loadingFailedMessage };
              }
              if (message.error.message.toLowerCase().includes("no response body captured")) {
                return { kind: "missingBody", message: message.error.message };
              }
              return { kind: "failure", message: message.error.message };
            }
            const body = stringField(message.result, "body");
            const base64Encoded = booleanField(message.result, "base64Encoded");
            if (body == null || base64Encoded == null) {
              return { kind: "failure", message: "Malformed response for Network.getResponseBody" };
            }
            responseBody = body;
            responseBodyBase64Encoded = base64Encoded;
            responseBodyResolved = true;
          }
        }
      }

      if (
        shouldSendRequestBodyCommand(
          featureOpened,
          details.requestSeen && details.requestHasPostData,
          requestBodyResolved,
          pendingRequestBodyId,
          requestBodyAttempts
        )
      ) {
        pendingRequestBodyId = commandId;
        requestBodyAttempts += 1;
        session.sendFeatureCommand({
          id: commandId,
          method: "Network.getRequestPostData",
          params: { requestId }
        });
        commandId += 1;
      }

      if (
        shouldSendResponseBodyCommand(
          featureOpened,
          details.responseSeen && details.responseTerminal && !responseShouldNotHaveBody(details),
          responseBodyResolved,
          pendingResponseBodyId,
          responseBodyAttempts
        )
      ) {
        pendingResponseBodyId = commandId;
        responseBodyAttempts += 1;
        session.sendFeatureCommand({
          id: commandId,
          method: "Network.getResponseBody",
          params: { requestId }
        });
        commandId += 1;
      }

      if (!requestBodyResolved && requestBodyAttempts >= CommandAttemptLimit && pendingRequestBodyId == null) {
        requestBodyResolved = true;
      }

      if (!responseBodyResolved && responseBodyAttempts >= CommandAttemptLimit && pendingResponseBodyId == null) {
        return {
          kind: "failure",
          message: `Timed out waiting for Network.getResponseBody for ${requestId} on ${serverIdentifier(server)}`
        };
      }

      if (requestBodyResolved && responseBodyResolved) {
        return {
          kind: "success",
          requestMethod: details.requestMethod,
          requestUrl: details.requestUrl,
          requestHeaders: details.requestHeaders,
          requestBodyEncoding: requestBodyEncoding ?? details.requestBodyEncoding,
          requestBody,
          responseStatus: details.responseStatus,
          responseUrl: details.responseUrl,
          responseHeaders: details.responseHeaders,
          responseBody: responseBody ?? "",
          responseBodyBase64Encoded
        };
      }

      if (Date.now() - startedAtMs >= SnapshotMaxWaitMs) {
        return {
          kind: "failure",
          message: `Timed out waiting for network lifecycle for ${requestId} on ${serverIdentifier(server)}`
        };
      }
    }
  } finally {
    session.close();
  }
}

async function discoverServers(
  adb: AdbClient,
  selection: DeviceSelectionOptions
): Promise<{ kind: "success"; servers: ServerRef[] } | { kind: "failure"; message: string }> {
  let devices: Device[];
  try {
    devices = await adb.devicesList();
  } catch {
    return { kind: "failure", message: "Failed to list adb devices" };
  }

  if (devices.length === 0) return { kind: "failure", message: "No connected devices found" };
  const selectedDeviceIds = resolveTargetDeviceIds(
    devices.map((device) => device.id),
    selection
  );
  if (selectedDeviceIds.kind === "failure") return selectedDeviceIds;

  const servers: ServerRef[] = [];
  for (const deviceId of selectedDeviceIds.deviceIds) {
    try {
      const sockets = parseSnapOSockets(await adb.listUnixSockets(deviceId));
      for (const socketName of sockets) servers.push({ deviceId, socketName });
    } catch {
      // A device may disappear while we are listing sockets; omit it from this snapshot.
    }
  }

  servers.sort((left, right) => {
    const device = left.deviceId.localeCompare(right.deviceId);
    return device !== 0 ? device : left.socketName.localeCompare(right.socketName);
  });
  return { kind: "success", servers };
}

async function resolveServerAppInfo(adb: AdbClient, server: ServerRef): Promise<ServerAppInfo> {
  const [hint, hello] = await Promise.all([packageNameHint(adb, server), fetchHello(adb, server)]);
  return {
    packageName: hello?.packageName ?? hint,
    appName: hello?.processName?.trim() || null
  };
}

async function fetchHello(adb: AdbClient, server: ServerRef): Promise<HelloRecord | null> {
  const session = await CliSession.open(adb, server);
  if (session == null) return null;
  try {
    while (true) {
      const record = await session.nextRecord(HelloWaitTimeoutMs);
      if (record == null) return null;
      if (record.kind === "hello") return record.value;
    }
  } finally {
    session.close();
  }
}

async function packageNameHint(adb: AdbClient, server: ServerRef): Promise<string | null> {
  const pid = pidFromSocketName(server.socketName);
  if (pid == null) return null;
  try {
    const output = await adb.runShellString(server.deviceId, `cat /proc/${pid}/cmdline 2>/dev/null`);
    return (
      output
        .split("\u0000")
        .find((part) => part.trim().length > 0)
        ?.trim() ??
      output
        .split(/\r?\n/u)
        .find((part) => part.trim().length > 0)
        ?.trim() ??
      null
    );
  } catch {
    return null;
  }
}

async function resolveServer(
  adb: AdbClient,
  socketArgument: string | null,
  selection: DeviceSelectionOptions
): Promise<{ kind: "success"; server: ServerRef } | { kind: "failure"; message: string }> {
  const socketName = socketArgument?.trim() || null;
  const discovery = await discoverServers(adb, selection);
  if (discovery.kind === "failure") return discovery;
  if (discovery.servers.length === 0) {
    return { kind: "failure", message: "No Snap-O link servers found for selected device(s)" };
  }

  if (socketName == null) {
    if (discovery.servers.length === 1) return { kind: "success", server: discovery.servers[0] };
    return {
      kind: "failure",
      message: `Multiple sockets found; select one with -n/--socket. Available: ${await formatSocketChoicesWithPackageHint(
        adb,
        discovery.servers
      )}`
    };
  }

  const qualified = parseServerRef(socketName);
  if (qualified != null) {
    const exactMatch = discovery.servers.find((server) => sameServer(server, qualified));
    return exactMatch == null
      ? { kind: "failure", message: `Server '${serverIdentifier(qualified)}' was not found for selected device(s)` }
      : { kind: "success", server: exactMatch };
  }

  const matches = discovery.servers.filter((server) => server.socketName === socketName);
  if (matches.length === 0) {
    return { kind: "failure", message: `No Snap-O link server named '${socketName}' found` };
  }
  if (matches.length > 1) {
    return {
      kind: "failure",
      message: `Socket '${socketName}' exists on multiple devices; use -s <serial>, -d, or -e. Available: ${await formatSocketChoicesWithPackageHint(
        adb,
        matches
      )}`
    };
  }
  return { kind: "success", server: matches[0] };
}

function resolveTargetDeviceIds(
  connectedDeviceIds: string[],
  selection: DeviceSelectionOptions
): { kind: "success"; deviceIds: string[] } | { kind: "failure"; message: string } {
  const selectedByCount = [
    selection.serialId != null && selection.serialId.trim().length > 0,
    selection.useUsbDevice,
    selection.useEmulator
  ].filter(Boolean).length;
  if (selectedByCount > 1) return { kind: "failure", message: "Options -s, -d, and -e are mutually exclusive" };

  const serial = selection.serialId?.trim() || null;
  if (serial != null) {
    return connectedDeviceIds.includes(serial)
      ? { kind: "success", deviceIds: [serial] }
      : { kind: "failure", message: `Device '${serial}' is not connected` };
  }

  if (selection.useEmulator) {
    const emulators = connectedDeviceIds.filter((deviceId) => deviceId.startsWith("emulator-"));
    if (emulators.length === 0) return { kind: "failure", message: "No emulator connected" };
    if (emulators.length > 1) {
      return { kind: "failure", message: "More than one emulator connected; use -s <serial>" };
    }
    return { kind: "success", deviceIds: emulators };
  }

  if (selection.useUsbDevice) {
    const usbDevices = connectedDeviceIds.filter((deviceId) => !deviceId.startsWith("emulator-"));
    if (usbDevices.length === 0) return { kind: "failure", message: "No USB device connected" };
    if (usbDevices.length > 1) {
      return { kind: "failure", message: "More than one USB device connected; use -s <serial>" };
    }
    return { kind: "success", deviceIds: usbDevices };
  }

  return { kind: "success", deviceIds: connectedDeviceIds };
}

async function formatSocketChoicesWithPackageHint(adb: AdbClient, servers: ServerRef[]): Promise<string> {
  const entries = await Promise.all(
    servers.map(async (server) => `${server.socketName} (pkg:${(await packageNameHint(adb, server)) ?? "unknown"})`)
  );
  return entries.join(", ");
}

function parseServerRef(value: string): ServerRef | null {
  const separator = value.indexOf("/");
  if (separator <= 0 || separator >= value.length - 1) return null;
  const deviceId = value.slice(0, separator).trim();
  const socketName = value.slice(separator + 1).trim();
  return deviceId.length === 0 || socketName.length === 0 ? null : { deviceId, socketName };
}

function parseNetworkListOptions(args: string[]): CliOptions & { includeAppInfo: boolean } {
  const parsed = parseCommonOptions(args, new Set(), new Set(["--json", "--no-app-info"]));
  return {
    ...parsed.common,
    includeAppInfo: !parsed.flags.has("--no-app-info")
  };
}

function parseNetworkRequestsOptions(args: string[]): NetworkRequestsOptions {
  const parsed = parseCommonOptions(args, new Set(["-n", "--socket"]), new Set(["--json", "--no-stream"]));
  return {
    ...parsed.common,
    socketName: parsed.values.get("--socket") ?? null,
    noStream: parsed.flags.has("--no-stream")
  };
}

function parseNetworkShowOptions(args: string[]): NetworkShowOptions {
  const parsed = parseCommonOptions(args, new Set(["-n", "--socket", "-r", "--request-id"]), new Set(["--json"]));
  return {
    ...parsed.common,
    socketName: parsed.values.get("--socket") ?? null,
    requestId: parsed.values.get("--request-id") ?? null
  };
}

function parseCommonOptions(
  args: string[],
  valueOptions: Set<string>,
  allowedFlags: Set<string>
): {
  common: CliOptions;
  flags: Set<string>;
  values: Map<string, string>;
} {
  const flags = new Set<string>();
  const values = new Map<string, string>();
  let serialId: string | null = null;
  let useUsbDevice = false;
  let useEmulator = false;

  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (KnownFlags.has(arg)) {
      if (!allowedFlags.has(arg)) throw new Error(`Unknown option '${arg}'`);
      flags.add(arg);
      continue;
    }
    if (arg === "-d") {
      useUsbDevice = true;
      continue;
    }
    if (arg === "-e") {
      useEmulator = true;
      continue;
    }
    if (arg === "-s" || arg === "--serial") {
      serialId = nextOptionValue(args, index, arg);
      index += 1;
      continue;
    }
    if (valueOptions.has(arg)) {
      const normalized = arg === "-n" ? "--socket" : arg === "-r" ? "--request-id" : arg;
      values.set(normalized, nextOptionValue(args, index, arg));
      index += 1;
      continue;
    }
    throw new Error(`Unknown option '${arg}'`);
  }

  return {
    common: {
      serialId,
      useUsbDevice,
      useEmulator,
      json: flags.has("--json")
    },
    flags,
    values
  };
}

function nextOptionValue(args: string[], index: number, option: string): string {
  const value = args[index + 1];
  if (value == null || value.startsWith("-")) throw new Error(`Missing value for ${option}`);
  return value;
}

function emptyRequestDetailsSnapshot(): RequestDetailsSnapshot {
  return {
    requestSeen: false,
    requestHasPostData: false,
    requestMethod: null,
    requestUrl: null,
    requestHeaders: {},
    requestBodyEncoding: null,
    responseSeen: false,
    responseTerminal: false,
    loadingFailedMessage: null,
    responseStatus: null,
    responseUrl: null,
    responseHeaders: {}
  };
}

function updateRequestDetailsSnapshot(
  current: RequestDetailsSnapshot,
  message: CdpMessage,
  requestId: string
): RequestDetailsSnapshot {
  if (message.params == null) return current;
  switch (message.method) {
    case "Network.requestWillBeSent":
      if (stringAt(message.params, "requestId") !== requestId) return current;
      return {
        ...current,
        requestSeen: true,
        requestHasPostData: booleanAt(message.params, "request.hasPostData") ?? false,
        requestMethod: stringAt(message.params, "request.method"),
        requestUrl: stringAt(message.params, "request.url"),
        requestHeaders: redactHeaderMap(headersAt(message.params, "request.headers"), RequestHeaderNames),
        requestBodyEncoding: stringAt(message.params, "request.postDataEncoding")
      };
    case "Network.responseReceived":
      if (stringAt(message.params, "requestId") !== requestId) return current;
      return {
        ...current,
        responseSeen: true,
        responseStatus: numberAt(message.params, "response.status"),
        responseUrl: stringAt(message.params, "response.url"),
        responseHeaders: redactHeaderMap(headersAt(message.params, "response.headers"), ResponseHeaderNames)
      };
    case "Network.loadingFinished":
      if (stringAt(message.params, "requestId") !== requestId) return current;
      return { ...current, responseTerminal: true, loadingFailedMessage: null };
    case "Network.loadingFailed":
      if (stringAt(message.params, "requestId") !== requestId) return current;
      return {
        ...current,
        responseTerminal: true,
        loadingFailedMessage: stringAt(message.params, "errorText") ?? stringAt(message.params, "type")
      };
    default:
      return current;
  }
}

function shouldSendRequestBodyCommand(
  featureOpened: boolean,
  canRequestBody: boolean,
  requestBodyResolved: boolean,
  pendingRequestBodyId: number | null,
  requestBodyAttempts: number
): boolean {
  return (
    featureOpened &&
    canRequestBody &&
    !requestBodyResolved &&
    pendingRequestBodyId == null &&
    requestBodyAttempts < CommandAttemptLimit
  );
}

function shouldSendResponseBodyCommand(
  featureOpened: boolean,
  canRequestBody: boolean,
  responseBodyResolved: boolean,
  pendingResponseBodyId: number | null,
  responseBodyAttempts: number
): boolean {
  return (
    featureOpened &&
    canRequestBody &&
    !responseBodyResolved &&
    pendingResponseBodyId == null &&
    responseBodyAttempts < CommandAttemptLimit
  );
}

function responseShouldNotHaveBody(snapshot: RequestDetailsSnapshot): boolean {
  const contentLength = headerValue(snapshot.responseHeaders, "Content-Length");
  return responseIsDefinedAsBodyless(
    snapshot.requestMethod,
    snapshot.responseStatus,
    contentLength == null ? null : Number.parseInt(contentLength, 10)
  );
}

function shouldResolveEmptyResponseBody(responseBodyResolved: boolean, details: RequestDetailsSnapshot): boolean {
  return (
    !responseBodyResolved && details.responseSeen && details.responseTerminal && responseShouldNotHaveBody(details)
  );
}

function responseIsDefinedAsBodyless(
  requestMethod: string | null,
  responseStatus: number | null,
  responseContentLength: number | null
): boolean {
  if (requestMethod?.toUpperCase() === "HEAD") return true;
  if (responseStatus == null) return false;
  if (responseStatus >= 100 && responseStatus <= 199) return true;
  if (responseStatus === 204 || responseStatus === 205 || responseStatus === 304) return true;
  return responseContentLength === 0;
}

function snapshotWaitMs(nowMs: number, openedAtMs: number | null, lastNetworkAtMs: number | null): number {
  if (openedAtMs == null) return 250;
  const elapsedSinceOpen = nowMs - openedAtMs;
  if (elapsedSinceOpen >= SnapshotMaxWaitMs) return 1;
  const quietRemaining =
    lastNetworkAtMs == null ? SnapshotQuietPeriodMs : Math.max(1, SnapshotQuietPeriodMs - (nowMs - lastNetworkAtMs));
  const maxRemaining = Math.max(1, SnapshotMaxWaitMs - elapsedSinceOpen);
  return Math.min(quietRemaining, maxRemaining);
}

function sanitizeMessage(message: CdpMessage): CdpMessage {
  if (message.method == null || message.params == null) return message;
  let params = message.params;
  switch (message.method) {
    case "Network.requestWillBeSent":
      params = redactHeadersAtPath(params, ["request", "headers"], RequestHeaderNames);
      break;
    case "Network.responseReceived":
      params = redactHeadersAtPath(params, ["response", "headers"], ResponseHeaderNames);
      break;
    case "Network.webSocketCreated":
      params = redactHeadersAtPath(params, ["headers"], RequestHeaderNames);
      break;
    case "Network.webSocketHandshakeResponseReceived":
      params = redactHeadersAtPath(params, ["response", "headers"], ResponseHeaderNames);
      break;
    default:
      return message;
  }
  return params === message.params ? message : { ...message, params };
}

function redactHeadersAtPath(
  root: Record<string, unknown>,
  path: string[],
  sensitiveHeaderNames: Set<string>
): Record<string, unknown> {
  if (path.length === 0) {
    return redactUnknownHeaderRecord(root, sensitiveHeaderNames);
  }
  const [key, ...rest] = path;
  const child = root[key];
  if (!isRecord(child)) return root;
  const next = redactHeadersAtPath(child, rest, sensitiveHeaderNames);
  return next === child ? root : { ...root, [key]: next };
}

function redactHeaderMap(headers: Record<string, string>, sensitiveHeaderNames: Set<string>): Record<string, string> {
  const updated: Record<string, string> = {};
  let changed = false;
  for (const [name, value] of Object.entries(headers)) {
    if (sensitiveHeaderNames.has(name.toLowerCase())) {
      updated[name] = RedactedValue;
      changed = true;
    } else {
      updated[name] = value;
    }
  }
  return changed ? updated : headers;
}

function redactUnknownHeaderRecord(
  headers: Record<string, unknown>,
  sensitiveHeaderNames: Set<string>
): Record<string, unknown> {
  const updated: Record<string, unknown> = {};
  let changed = false;
  for (const [name, value] of Object.entries(headers)) {
    if (sensitiveHeaderNames.has(name.toLowerCase())) {
      updated[name] = RedactedValue;
      changed = true;
    } else {
      updated[name] = value;
    }
  }
  return changed ? updated : headers;
}

function emitServerListHuman(servers: ServerRef[], appInfoByServer: Map<string, ServerAppInfo> | null): void {
  const byDevice = new Map<string, ServerRef[]>();
  for (const server of servers) {
    const deviceServers = byDevice.get(server.deviceId) ?? [];
    deviceServers.push(server);
    byDevice.set(server.deviceId, deviceServers);
  }
  for (const deviceId of [...byDevice.keys()].sort()) {
    console.log(`${deviceId}:`);
    for (const server of (byDevice.get(deviceId) ?? []).sort((left, right) =>
      left.socketName.localeCompare(right.socketName)
    )) {
      if (appInfoByServer == null) {
        console.log(`    ${server.socketName}`);
      } else {
        const packageName = appInfoByServer.get(serverIdentifier(server))?.packageName ?? "unknown";
        console.log(`    ${server.socketName}  pkg:${packageName}`);
      }
    }
  }
}

function emitNetworkEvent(message: CdpMessage, outputMode: OutputMode): void {
  if (outputMode === "json") {
    printJson(message);
    return;
  }
  console.log(formatNetworkEventLine(message));
}

function emitRequestDetails(
  line: {
    server: string;
    requestId: string;
    requestMethod: string | null;
    requestUrl: string | null;
    requestHeaders: Record<string, string>;
    requestBodyEncoding: string | null;
    requestBody: string | null;
    responseStatus: number | null;
    responseUrl: string | null;
    responseHeaders: Record<string, string>;
    responseBody: string;
    responseBodyBase64Encoded: boolean;
  },
  outputMode: OutputMode
): void {
  if (outputMode === "json") {
    printJson(line);
    return;
  }

  console.log(`Server: ${line.server}`);
  console.log(`Request ID: ${line.requestId}`);
  console.log(`Request: ${line.requestMethod ?? "unknown"} ${line.requestUrl ?? "unknown"}`);
  emitHeadersSection("Request Headers", line.requestHeaders);
  console.log(`Response: ${line.responseStatus ?? "unknown"} ${line.responseUrl ?? "unknown"}`);
  emitHeadersSection("Response Headers", line.responseHeaders);
  console.log("Request Body:");
  console.log(
    line.requestBody == null
      ? "<none>"
      : decodeBodyForDisplay(
          line.requestBody,
          line.requestBodyEncoding,
          headerValue(line.requestHeaders, "Content-Encoding")
        )
  );
  console.log(`Response Body (base64 encoded: ${line.responseBodyBase64Encoded}):`);
  console.log(line.responseBody);
}

function emitHeadersSection(title: string, headers: Record<string, string>): void {
  console.log(`${title}:`);
  const entries = Object.entries(headers).sort(([left], [right]) =>
    left.toLowerCase().localeCompare(right.toLowerCase())
  );
  if (entries.length === 0) {
    console.log("  <none>");
    return;
  }
  for (const [name, value] of entries) console.log(`  ${name}: ${value}`);
}

function formatNetworkEventLine(message: CdpMessage): string {
  if (message.method == null) return `EVENT ${JSON.stringify(message)}`;
  switch (message.method) {
    case "Network.requestWillBeSent":
      return `REQUEST ${stringAt(message.params, "requestId") ?? "?"} ${stringAt(message.params, "request.method") ?? "?"} ${
        stringAt(message.params, "request.url") ?? "?"
      }`;
    case "Network.responseReceived":
      return `RESPONSE ${stringAt(message.params, "requestId") ?? "?"} ${numberAt(message.params, "response.status") ?? "?"} ${
        stringAt(message.params, "response.url") ?? "unknown-url"
      }`;
    case "Network.loadingFinished":
      return `FINISH ${stringAt(message.params, "requestId") ?? "?"} bytes=${numberAt(message.params, "encodedDataLength") ?? 0}`;
    case "Network.loadingFailed":
      return `FAIL ${stringAt(message.params, "requestId") ?? "?"} ${
        stringAt(message.params, "errorText") ?? stringAt(message.params, "type") ?? "unknown-error"
      }`;
    case "Network.webSocketFrameSent":
      return `WS-SENT ${stringAt(message.params, "requestId") ?? "?"} opcode=${
        numberAt(message.params, "response.opcode") ?? "?"
      } size=${numberAt(message.params, "response.payloadSize") ?? 0}`;
    case "Network.webSocketFrameReceived":
      return `WS-RECV ${stringAt(message.params, "requestId") ?? "?"} opcode=${
        numberAt(message.params, "response.opcode") ?? "?"
      } size=${numberAt(message.params, "response.payloadSize") ?? 0}`;
    default:
      return `EVENT ${message.method}`;
  }
}

function decodeBodyForDisplay(
  rawBody: string,
  rawEncoding: string | null,
  contentEncodingHeader: string | null
): string {
  if (rawEncoding?.toLowerCase() !== "base64" || !hasGzipContentEncoding(contentEncodingHeader)) return rawBody;
  try {
    const uncompressed = gunzipSync(Buffer.from(rawBody.trim(), "base64"));
    try {
      return new TextDecoder("utf-8", { fatal: true }).decode(uncompressed);
    } catch {
      return `Binary payload after gzip decompression (${formatDisplayBytes(uncompressed.byteLength)}). Raw payload is shown below as captured.\n\n${rawBody}`;
    }
  } catch {
    return rawBody;
  }
}

function hasGzipContentEncoding(value: string | null): boolean {
  if (value == null || value.trim().length === 0) return false;
  return value
    .split(/[,\n]/u)
    .map((token) => token.split(";")[0].trim().toLowerCase())
    .some((token) => token === "gzip" || token === "x-gzip");
}

function formatDisplayBytes(byteCount: number): string {
  if (byteCount < 1_000) return `${byteCount} B`;
  if (byteCount < 1_000_000) return `${(byteCount / 1_000).toFixed(1)} KB`;
  if (byteCount < 1_000_000_000) return `${(byteCount / 1_000_000).toFixed(1)} MB`;
  return `${(byteCount / 1_000_000_000).toFixed(1)} GB`;
}

function stringAt(root: Record<string, unknown> | undefined, path: string): string | null {
  const value = valueAt(root, path);
  return typeof value === "string" ? value : null;
}

function numberAt(root: Record<string, unknown> | undefined, path: string): number | null {
  const value = valueAt(root, path);
  return typeof value === "number" ? value : null;
}

function booleanAt(root: Record<string, unknown> | undefined, path: string): boolean | null {
  const value = valueAt(root, path);
  return typeof value === "boolean" ? value : null;
}

function headersAt(root: Record<string, unknown>, path: string): Record<string, string> {
  const value = valueAt(root, path);
  if (!isRecord(value)) return {};
  const headers: Record<string, string> = {};
  for (const [name, rawValue] of Object.entries(value)) {
    headers[name] = typeof rawValue === "string" ? rawValue : String(rawValue);
  }
  return headers;
}

function valueAt(root: Record<string, unknown> | undefined, path: string): unknown {
  let current: unknown = root;
  for (const segment of path.split(".")) {
    if (!isRecord(current)) return null;
    current = current[segment];
  }
  return current;
}

function stringField(record: Record<string, unknown> | undefined, field: string): string | null {
  const value = record?.[field];
  return typeof value === "string" ? value : null;
}

function booleanField(record: Record<string, unknown> | undefined, field: string): boolean | null {
  const value = record?.[field];
  return typeof value === "boolean" ? value : null;
}

function headerValue(headers: Record<string, string>, name: string): string | null {
  const entry = Object.entries(headers).find(([headerName]) => headerName.toLowerCase() === name.toLowerCase());
  return entry?.[1] ?? null;
}

function serverIdentifier(server: ServerRef): string {
  return `${server.deviceId}/${server.socketName}`;
}

function sameServer(left: ServerRef, right: ServerRef): boolean {
  return left.deviceId === right.deviceId && left.socketName === right.socketName;
}

function printJson(value: unknown): void {
  console.log(JSON.stringify(value));
}

function fail(message: string): number {
  printError(message);
  return 1;
}

function printError(message: string): void {
  console.error(`snapo: ${message}`);
}

function printRootHelp(): void {
  console.log(`Snap-O command line tools

Usage:
  snapo network <command> [options]

Commands:
  network    Inspect Snap-O network data`);
}

function printNetworkHelp(): void {
  console.log(`Inspect Snap-O network data

Usage:
  snapo network <command> [options]

Commands:
  list       List available Snap-O link servers
  requests   Emit CDP network events for a server
  show       Show details for a request id`);
}

function printNetworkListHelp(): void {
  console.log(`List available Snap-O link servers

Usage:
  snapo network list [-s <serial> | -d | -e] [--json] [--no-app-info]`);
}

function printNetworkRequestsHelp(): void {
  console.log(`Emit CDP network events for a server

Usage:
  snapo network requests [-s <serial> | -d | -e] [-n <socket>] [--json] [--no-stream]`);
}

function printNetworkShowHelp(): void {
  console.log(`Show details for a request id

Usage:
  snapo network show [-s <serial> | -d | -e] [-n <socket>] -r <request-id> [--json]`);
}

function isHelpFlag(value: string | undefined): boolean {
  return value === "-h" || value === "--help";
}

function containsHelpFlag(args: string[]): boolean {
  return args.some((arg) => isHelpFlag(arg));
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value != null && typeof value === "object" && !Array.isArray(value);
}

class CliSession {
  private readonly records: SnapORecord[] = [];
  private readonly waiters: Array<(record: SnapORecord | null) => void> = [];
  private connection: SnapOLinkConnection | null = null;
  private isClosed = false;

  static async open(adb: AdbClient, server: ServerRef): Promise<CliSession | null> {
    const session = new CliSession();
    try {
      const stream = await adb.openLocalAbstract(server.deviceId, server.socketName);
      session.connection = new SnapOLinkConnection(
        stream,
        (record) => session.pushRecord(record),
        () => session.close()
      );
      session.connection.start();
      return session;
    } catch {
      session.close();
      return null;
    }
  }

  get closed(): boolean {
    return this.isClosed;
  }

  sendFeatureOpened(feature: string): void {
    this.connection?.sendFeatureOpened(feature);
  }

  sendFeatureCommand(message: CdpMessage): void {
    this.connection?.sendFeatureCommand(NetworkFeatureId, message);
  }

  nextRecord(timeoutMs?: number): Promise<SnapORecord | null> {
    const next = this.records.shift();
    if (next != null) return Promise.resolve(next);
    if (this.isClosed) return Promise.resolve(null);

    return new Promise((resolve) => {
      let timeout: NodeJS.Timeout | null = null;
      const waiter = (record: SnapORecord | null): void => {
        if (timeout != null) clearTimeout(timeout);
        resolve(record);
      };
      this.waiters.push(waiter);
      if (timeoutMs != null) {
        timeout = setTimeout(() => {
          const index = this.waiters.indexOf(waiter);
          if (index >= 0) this.waiters.splice(index, 1);
          resolve(null);
        }, timeoutMs);
      }
    });
  }

  close(): void {
    if (this.isClosed) return;
    this.isClosed = true;
    this.connection?.stop();
    this.connection = null;
    for (const waiter of this.waiters.splice(0)) waiter(null);
  }

  private pushRecord(record: SnapORecord): void {
    const waiter = this.waiters.shift();
    if (waiter != null) {
      waiter(record);
      return;
    }
    this.records.push(record);
  }
}

const KnownFlags = new Set(["--json", "--no-app-info", "--no-stream"]);
