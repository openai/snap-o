export const supportedProtocolVersion = 7;

export function unsupportedProtocolMessage(protocolVersion: number | undefined): string {
  if (protocolVersion == null) return "The Android app is missing the Tweaks protocol version.";
  return `App reports protocol v${protocolVersion}. This Tweaks tool supports protocol v${supportedProtocolVersion}. Update Snap-O and the Android library together.`;
}
