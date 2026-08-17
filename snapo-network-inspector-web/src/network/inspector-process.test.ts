import { describe, expect, it } from "vitest";
import { inspectorProcessId } from "./inspector-process";

describe("inspector process identity", () => {
  it("merges different inspector sockets for the same device and PID", () => {
    expect(inspectorProcessId("network", { deviceId: "phone", socketName: "snapo_network_42" })).toBe("phone:pid:42");
    expect(inspectorProcessId("tweaks", { deviceId: "phone", socketName: "snapo_tweaks_42" })).toBe("phone:pid:42");
  });

  it("keeps devices and processes separate", () => {
    expect(inspectorProcessId("network", { deviceId: "other", socketName: "snapo_network_42" })).toBe("other:pid:42");
    expect(inspectorProcessId("network", { deviceId: "phone", socketName: "snapo_network_43" })).toBe("phone:pid:43");
  });

  it("uses the socket itself when no valid PID is available", () => {
    for (const socketName of [
      "legacy",
      "snapo_network_",
      "snapo_network_0",
      "snapo_network_-1",
      "snapo_network_42_extra"
    ]) {
      expect(inspectorProcessId("network", { deviceId: "phone", socketName })).toBe(`phone:socket:${socketName}`);
    }
  });
});
