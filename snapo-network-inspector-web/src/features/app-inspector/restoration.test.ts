import { describe, expect, it } from "vitest";
import type { AppInspectorKind, InspectableApp } from "../../network/bridge-types";
import { InspectorRestoration } from "./restoration";

function app(
  pid = 10,
  kinds: AppInspectorKind[] = ["network", "tweaks"],
  processName = "com.example.demo",
  deviceId = "phone",
  androidUserId = 0
): InspectableApp {
  return {
    id: `${deviceId}:pid:${pid}`,
    name: "Demo",
    packageName: processName.split(":")[0],
    processName,
    androidUserId,
    deviceId,
    deviceDisplayTitle: "Phone",
    inspectors: kinds.map((kind) => ({ kind, server: { deviceId, socketName: `snapo_${kind}_${pid}` } }))
  };
}

function selected(kind: AppInspectorKind = "network") {
  const owner = new InspectorRestoration();
  const initial = app();
  owner.reconcile([initial]);
  owner.selectInspector(initial, initial.inspectors.find((option) => option.kind === kind)!);
  return owner;
}

describe("inspector restoration", () => {
  it("keeps the live selection object stable across unchanged scans", () => {
    const owner = selected();
    const current = owner.snapshot().selection;
    expect(owner.reconcile([app()]).selection).toBe(current);
  });

  it("waits through an empty scan and Tweaks-first discovery, then restores Network", () => {
    const owner = selected();
    const displayedNetwork = owner.snapshot().selection;
    const saved = owner.serialize();
    expect(owner.reconcile([])).toMatchObject({ selection: null, displayedNetwork, isRestoring: true });
    expect(owner.reconcile([app(20, ["tweaks"])])).toMatchObject({
      selection: null,
      preferredKind: "network",
      isRestoring: true
    });
    expect(owner.serialize()).toBe(saved);
    expect(owner.snapshot().displayedNetwork).toBe(displayedNetwork);
    expect(owner.reconcile([app(20)])).toMatchObject({
      selection: { kind: "network", server: { socketName: "snapo_network_20" } },
      isRestoring: false
    });
  });

  it("does not show the previous app's history after an explicit app change", () => {
    const owner = selected();
    const other = app(20, ["network", "tweaks"], "com.example.other");
    expect(owner.selectApp({ ...other, processName: null }).displayedNetwork).toBeNull();
    expect(owner.reconcile([other]).displayedNetwork?.appId).toBe(other.id);
    expect(owner.selectInspector(other, other.inspectors[1]).displayedNetwork).toBeNull();
  });

  it("keeps known inspector types through empty and partial scans", () => {
    const owner = selected();
    const kinds = () => owner.snapshot().selectedApp?.inspectors.map((option) => option.kind);
    owner.reconcile([]);
    expect(kinds()).toEqual(["network", "tweaks"]);
    owner.reconcile([app(20, ["tweaks"])]);
    expect(kinds()).toEqual(["network", "tweaks"]);
    expect(owner.snapshot().selection).toBeNull();
    owner.reconcile([app(20)]);
    expect(owner.snapshot().selectedApp?.inspectors).toEqual(app(20).inspectors);
  });

  it("treats cached inspector choices as intent without reconnecting stale sockets", () => {
    const owner = selected();
    const network = owner.snapshot().displayedNetwork;
    owner.reconcile([]);
    const cached = owner.snapshot().selectedApp!;
    expect(owner.selectInspector(cached, cached.inspectors[1])).toMatchObject({
      selection: null,
      displayedNetwork: null,
      preferredKind: "tweaks",
      isRestoring: true
    });
    expect(owner.selectInspector(cached, cached.inspectors[0])).toMatchObject({
      selection: null,
      displayedNetwork: network,
      preferredKind: "network",
      isRestoring: true
    });
    owner.reconcile([app(20, ["tweaks"])]);
    const partial = owner.snapshot().selectedApp!;
    expect(owner.selectInspector(partial, partial.inspectors[0]).selection).toBeNull();
    expect(owner.selectInspector(partial, partial.inspectors[1]).selection?.server.socketName).toBe("snapo_tweaks_20");
    expect(owner.reconcile([app(20)]).selection?.kind).toBe("tweaks");
  });

  it("does not carry cached types to another app", () => {
    const owner = selected();
    const other = app(20, ["network"], "com.example.other");
    owner.reconcile([other]);
    expect(owner.selectApp(other).selectedApp?.inspectors).toEqual(other.inspectors);
  });

  it("retains the displayed Tweaks endpoint through disconnect and a new PID", () => {
    const owner = selected("tweaks");
    const displayedTweaks = owner.snapshot().selection;
    expect(owner.reconcile([])).toMatchObject({ selection: null, displayedTweaks, isRestoring: true });
    expect(owner.reconcile([app(20, ["network"])])).toMatchObject({ selection: null, displayedTweaks });
    expect(owner.reconcile([app(20)]).displayedTweaks?.server.socketName).toBe("snapo_tweaks_20");
    const other = app(30, ["network"], "com.example.other");
    owner.reconcile([app(20), other]);
    expect(owner.selectApp(other).displayedTweaks).toBeNull();
  });

  it("restores after restarting the host, without saving a PID or socket", () => {
    const saved = selected("tweaks").serialize();
    expect(saved).not.toContain("snapo_");
    expect(saved).not.toContain("pid:");
    const owner = new InspectorRestoration(saved);
    expect(owner.reconcile([]).selection).toBeNull();
    const other = app(20, ["network"], "com.example.other");
    expect(owner.reconcile([other, app(30)]).selection).toMatchObject({ appId: "phone:pid:30", kind: "tweaks" });
    expect(owner.serialize()).toBe(saved);
  });

  it("does not switch to another process, device, or app while restoring", () => {
    const owner = selected();
    const others = [
      app(10, ["network"], "com.example.other"),
      app(20, ["network"], "com.example.demo:worker"),
      app(10, ["network"], "com.example.demo", "tablet")
    ];
    expect(owner.reconcile(others).selection).toBeNull();
    expect(owner.reconcile([...others, app(40)]).selection?.server.socketName).toBe("snapo_network_40");
  });

  it("lets an explicit inspector choice cancel pending restoration", () => {
    const owner = selected();
    const partial = app(20, ["tweaks"]);
    owner.reconcile([partial]);
    owner.selectInspector(partial, partial.inspectors[0]);
    expect(owner.reconcile([app(20)]).selection?.kind).toBe("tweaks");
    expect(new InspectorRestoration(owner.serialize()).reconcile([app(30)]).selection?.kind).toBe("tweaks");
  });

  it("remembers a different inspector for each app", () => {
    const owner = selected();
    const other = app(20, ["network", "tweaks"], "com.example.other");
    owner.reconcile([app(), other]);
    owner.selectInspector(other, other.inspectors[1]);
    const partial = app(30, ["tweaks"]);
    expect(owner.selectApp(partial)).toMatchObject({ selection: null, preferredKind: "network", isRestoring: true });
    expect(owner.reconcile([app(30), other]).selection?.kind).toBe("network");
    expect(owner.selectApp(other).selection?.kind).toBe("tweaks");
  });

  it("learns identity when metadata arrives without changing inspector kind", () => {
    const owner = new InspectorRestoration();
    const pending = { ...app(), processName: null };
    owner.reconcile([pending]);
    owner.selectInspector(pending, pending.inspectors[1]);
    expect(JSON.parse(owner.serialize()).last).toBeNull();
    expect(owner.reconcile([app()]).selection?.kind).toBe("tweaks");
    expect(new InspectorRestoration(owner.serialize()).reconcile([app(30)]).selection?.kind).toBe("tweaks");
  });

  it("waits for identity before resolving an app-row choice", () => {
    const owner = selected("tweaks");
    const first = app();
    const other = app(20, ["network", "tweaks"], "com.example.other");
    owner.selectInspector(other, other.inspectors[0]);
    const saved = owner.serialize();
    const pending = { ...first, processName: null };

    owner.reconcile([pending, other]);
    expect(owner.selectApp(pending)).toMatchObject({ selection: null, isRestoring: true });
    expect(owner.reconcile([]).isRestoring).toBe(true);
    expect(owner.reconcile([pending, other]).selection).toBeNull();
    expect(owner.serialize()).toBe(saved);
    expect(owner.reconcile([first, other]).selection?.kind).toBe("tweaks");
    expect(JSON.parse(owner.serialize()).last.kind).toBe("tweaks");
  });

  it("lets an inspector icon override a pending app-row preference", () => {
    const owner = selected("tweaks");
    const pending = { ...app(), processName: null };
    owner.selectApp(pending);
    expect(owner.selectInspector(pending, pending.inspectors[0]).selection?.kind).toBe("network");
    expect(owner.reconcile([app()]).selection?.kind).toBe("network");
    expect(JSON.parse(owner.serialize()).last.kind).toBe("network");
  });

  it("uses a spinner for an unidentified first app", () => {
    const owner = new InspectorRestoration();
    expect(owner.reconcile([{ ...app(), processName: null }])).toMatchObject({
      selection: null,
      selectedApp: null,
      isRestoring: true
    });
    expect(JSON.parse(owner.serialize()).last).toBeNull();
    expect(owner.reconcile([app()]).selection?.kind).toBe("network");
  });

  it("selects an identified replacement when an unidentified process exits", () => {
    const owner = new InspectorRestoration();
    owner.reconcile([{ ...app(), processName: null }]);
    expect(owner.reconcile([])).toMatchObject({ selection: null, selectedApp: null, isRestoring: false });
    expect(owner.reconcile([app(20)])).toMatchObject({
      selection: { appId: "phone:pid:20", kind: "network" },
      isRestoring: false
    });
  });

  it("does not let an unidentified process delay another identified app", () => {
    const owner = new InspectorRestoration();
    const ready = app(20);
    expect(owner.reconcile([{ ...app(), processName: null }, ready]).selection?.appId).toBe(ready.id);
  });

  it("ignores identified apps without an available inspector", () => {
    const owner = new InspectorRestoration();
    expect(owner.reconcile([app(10, [])])).toMatchObject({ selection: null, isRestoring: false });
    expect(owner.reconcile([app(10, []), app(20)]).selection?.appId).toBe("phone:pid:20");
  });

  it("does not restore by an unverified display name", () => {
    const owner = new InspectorRestoration(selected().serialize());
    expect(owner.reconcile([{ ...app(20), processName: null }]).selection).toBeNull();
    expect(owner.reconcile([app(20)]).selection?.kind).toBe("network");
  });

  it("selects an available inspector when there is no saved choice", () => {
    const owner = new InspectorRestoration("invalid JSON");
    expect(owner.reconcile([app(20, ["tweaks"])]).selection?.kind).toBe("tweaks");
  });

  it("keeps profile selection and inspector preferences across disconnect and a new PID", () => {
    const personal = app();
    const work = app(20, ["network", "tweaks"], "com.example.demo", "phone", 10);
    const owner = new InspectorRestoration();
    owner.reconcile([personal, work]);
    owner.selectInspector(work, work.inspectors[1]);
    expect(owner.reconcile([personal]).selection).toBeNull();
    expect(owner.snapshot().selectedApp?.androidUserId).toBe(10);
    const replacement = app(40, ["network", "tweaks"], "com.example.demo", "phone", 10);
    expect(owner.reconcile([personal, replacement]).selection?.appId).toBe(replacement.id);
    const restored = new InspectorRestoration(owner.serialize());
    expect(restored.reconcile([personal, replacement]).selection).toMatchObject({
      appId: replacement.id,
      kind: "tweaks"
    });
    expect(restored.selectApp(personal)).toMatchObject({
      selection: { appId: personal.id, kind: "network" },
      displayedTweaks: null
    });
  });

  it("keeps the selected launch target while a scan cannot confirm its Android user", () => {
    const owner = selected();
    const saved = owner.serialize();
    expect(owner.reconcile([{ ...app(), androidUserId: null, packageName: null }]).selection).toBeNull();
    expect(owner.snapshot().selectedApp).toMatchObject({ packageName: "com.example.demo", androidUserId: 0 });
    expect(owner.serialize()).toBe(saved);
  });

  it("learns the Android user for the selected process without restoring another profile", () => {
    const owner = new InspectorRestoration();
    owner.reconcile([{ ...app(), androidUserId: null }]);
    const work = { ...app(), androidUserId: 10 };
    expect(owner.reconcile([work]).selectedApp?.androidUserId).toBe(10);
    expect(JSON.parse(owner.serialize()).last.androidUserId).toBe(10);
    expect(owner.reconcile([app(30)]).selection).toBeNull();
  });

  it.each([undefined, null])("falls back for legacy preferences with Android user %s", (androidUserId) => {
    const legacy = { deviceId: "phone", processName: "com.example.demo", kind: "network", androidUserId };
    const owner = new InspectorRestoration(JSON.stringify({ last: legacy, apps: [legacy] }));
    const work = app(20, ["network"], "com.example.demo", "phone", 10);
    const unknownProfile = { ...app(40), androidUserId: null };
    const first = app(30, ["tweaks"], "com.example.other", "phone", 10);
    expect(owner.reconcile([first, app(), work, unknownProfile]).selection).toMatchObject({
      appId: first.id,
      kind: "tweaks"
    });
    expect(JSON.parse(owner.serialize()).last).toEqual({
      deviceId: "phone",
      processName: "com.example.other",
      androidUserId: 10,
      kind: "tweaks"
    });
  });

  it.each([
    ["another app", app(20, ["network"], "com.example.other")],
    ["another process", app(20, ["network"], "com.example.demo:worker")],
    ["another device", app(20, ["network"], "com.example.demo", "tablet")],
    ["another profile", app(20, ["network"], "com.example.demo", "phone", 10)]
  ])("saves a startup fallback when only %s is available", (_, first) => {
    const owner = new InspectorRestoration(selected("tweaks").serialize());
    const later = app(40, ["tweaks"], "com.example.later");
    expect(owner.reconcile([first, later]).selection).toMatchObject({ appId: first.id, kind: "network" });
    expect(JSON.parse(owner.serialize()).last).toEqual({
      deviceId: first.deviceId,
      processName: first.processName,
      androidUserId: first.androidUserId,
      kind: "network"
    });
    expect(new InspectorRestoration(owner.serialize()).reconcile([later, first]).selection?.appId).toBe(first.id);
    expect(owner.reconcile([app(), first, later]).selection?.appId).toBe(first.id);
  });

  it("uses an available inspector when the saved inspector is missing at startup", () => {
    const owner = new InspectorRestoration(selected("tweaks").serialize());
    expect(owner.reconcile([app(20, ["network"])]).selection?.kind).toBe("network");
    expect(JSON.parse(owner.serialize()).last.kind).toBe("network");
    expect(owner.reconcile([app(20)]).selection?.kind).toBe("network");
  });

  it("falls back to the first usable app instead of waiting for another app's saved inspector", () => {
    const owner = new InspectorRestoration(selected("tweaks").serialize());
    const first = app(20, ["network"], "com.example.other");
    expect(owner.reconcile([first, app(30, ["network"])]).selection?.appId).toBe(first.id);
  });

  it("uses a fallback app's saved inspector only when it is available", () => {
    const owner = selected("tweaks");
    const other = app(20, ["network"], "com.example.other");
    owner.reconcile([app(), other]);
    owner.selectApp(other);
    const saved = owner.serialize();
    expect(new InspectorRestoration(saved).reconcile([app(30)]).selection?.kind).toBe("tweaks");
    const restarted = new InspectorRestoration(saved);
    expect(restarted.reconcile([app(30, ["network"])]).selection?.kind).toBe("network");
    expect(JSON.parse(restarted.serialize()).last.kind).toBe("network");
  });

  it.each([null, selected("tweaks").serialize()])(
    "waits for a usable startup app without losing saved preferences",
    (saved) => {
      const owner = new InspectorRestoration(saved);
      const before = owner.serialize();
      const unidentified = { ...app(), processName: null };
      const empty = app(20, [], "com.example.empty");
      expect(owner.reconcile([]).selection).toBeNull();
      expect(owner.reconcile([unidentified, empty]).selection).toBeNull();
      expect(owner.serialize()).toBe(before);
      const ready = app(30, ["network"], "com.example.ready");
      expect(owner.reconcile([unidentified, empty, ready]).selection?.appId).toBe(ready.id);
      expect(JSON.parse(owner.serialize()).last.processName).toBe(ready.processName);
    }
  );

  it.each(["restored", "fallback", "explicit"])("does not fall back after a %s selection disconnects", (source) => {
    const owner = new InspectorRestoration(source === "restored" ? selected().serialize() : null);
    const target = app(20);
    const other = app(30, ["network"], "com.example.other");
    owner.reconcile(source === "explicit" ? [other, target] : [target, other]);
    if (source === "explicit") owner.selectApp(target);
    const saved = owner.serialize();
    const displayedNetwork = owner.snapshot().displayedNetwork;
    expect(owner.reconcile([]).selection).toBeNull();
    expect(owner.reconcile([other])).toMatchObject({
      selection: null,
      selectedApp: { id: target.id },
      displayedNetwork
    });
    expect(owner.reconcile([app(20, ["tweaks"]), other]).selection).toBeNull();
    expect(owner.serialize()).toBe(saved);
    expect(owner.reconcile([other, app(40)]).selection).toMatchObject({ appId: "phone:pid:40", kind: "network" });
  });

  it("does not override an explicit startup choice while its identity is pending", () => {
    const owner = new InspectorRestoration(selected().serialize());
    const pending = { ...app(20), processName: null };
    owner.reconcile([pending]);
    owner.selectApp(pending);
    const other = app(30, ["network"], "com.example.other");
    expect(owner.reconcile([other, pending]).selection).toBeNull();
    expect(owner.reconcile([other, app(20)]).selection?.appId).toBe(pending.id);
  });
});
