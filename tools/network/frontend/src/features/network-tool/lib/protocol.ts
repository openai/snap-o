export const supportedProtocolVersion = 3;

export function hasProtocolWarning(protocolVersion: number | undefined): protocolVersion is number {
  return protocolVersion != null && protocolVersion !== supportedProtocolVersion;
}

export function unsupportedProtocolMessage(protocolVersion: number): string {
  return `App reports protocol v${protocolVersion}. This Snap-O Desktop supports protocol v${supportedProtocolVersion}. Update Snap-O and the Android library together.`;
}
