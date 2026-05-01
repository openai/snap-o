export function parseNetworkSockets(output: string): Set<string> {
  const result = new Set<string>();
  for (const rawLine of output.split(/\r?\n/u)) {
    const token = rawLine.trim().split(/\s+/u).filter(Boolean).at(-1);
    if (token != null && token.startsWith("@snapo_network_")) {
      result.add(token.slice(1));
    }
  }
  return result;
}

export function pidFromSocketName(socketName: string): number | null {
  const prefix = "snapo_network_";
  if (!socketName.startsWith(prefix)) return null;
  const suffix = socketName.slice(prefix.length);
  return /^\d+$/u.test(suffix) ? Number.parseInt(suffix, 10) : null;
}
