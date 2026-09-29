export type BodyCoverage = "absent" | "incomplete" | "complete";

export function bodyCoverage(available: boolean, absent: boolean, complete: boolean): BodyCoverage {
  if (available) return complete ? "complete" : "incomplete";
  return absent ? "absent" : "incomplete";
}

export function requestBodyCoverage(
  available: boolean,
  hasBody: boolean | null | undefined,
  truncatedBytes: number | null | undefined
): BodyCoverage {
  return bodyCoverage(available, hasBody === false, truncatedBytes === 0);
}
