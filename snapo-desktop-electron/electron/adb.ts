import { Adb, type Client, type Device as AdbDevice } from "@devicefarmer/adbkit";
import type { Duplex } from "node:stream";

export interface Device {
  id: string;
  model: string;
  displayTitle: string;
}

export class AdbClient {
  private readonly client: Client = Adb.createClient();

  async devicesList(): Promise<Device[]> {
    const devices = await this.client.listDevices();
    const online = devices.filter((device: AdbDevice) => device.type === "device" || device.type === "emulator");
    return Promise.all(
      online.map(async (device: AdbDevice) => {
        const model = await this.deviceModel(device.id);
        return {
          id: device.id,
          model,
          displayTitle: model
        };
      })
    );
  }

  async runShellString(deviceId: string, command: string): Promise<string> {
    const stream = await this.client.getDevice(deviceId).shell(command);
    const output = await Adb.util.readAll(stream);
    return output.toString("utf8");
  }

  async listUnixSockets(deviceId: string): Promise<string> {
    return this.runShellString(deviceId, "cat /proc/net/unix");
  }

  async openLocalAbstract(deviceId: string, abstractSocket: string): Promise<Duplex> {
    return this.client.getDevice(deviceId).openLocal(`localabstract:${abstractSocket}`);
  }

  private async deviceModel(deviceId: string): Promise<string> {
    try {
      const properties = await this.client.getDevice(deviceId).getProperties();
      return (
        cleanProperty(properties["ro.boot.qemu.avd_name"]) ??
        cleanProperty(properties["ro.product.vendor.model"]) ??
        cleanProperty(properties["ro.product.model"]) ??
        deviceId
      ).replace(/_/g, " ");
    } catch {
      return deviceId;
    }
  }
}

function cleanProperty(value: unknown): string | null {
  return typeof value === "string" && value.trim().length > 0 ? value.trim() : null;
}
