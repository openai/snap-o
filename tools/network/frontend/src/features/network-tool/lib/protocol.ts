export const supportedProtocolVersion = 4;

export function hasProtocolWarning(protocolVersion: number): boolean {
  return protocolVersion !== supportedProtocolVersion;
}

export function unsupportedProtocolMessage(protocolVersion: number): string {
  return `App reports protocol v${protocolVersion}. This Network tool supports protocol v${supportedProtocolVersion}. Update Snap-O and the Android library together.`;
}
