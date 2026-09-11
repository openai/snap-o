export const supportedProtocolVersion = 7;

export function unsupportedProtocolMessage(protocolVersion: number): string {
  return `App reports protocol v${protocolVersion}. This Tweaks inspector supports protocol v${supportedProtocolVersion}. Update Snap-O and the Android library together.`;
}
