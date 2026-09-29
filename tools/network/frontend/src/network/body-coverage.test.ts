import { expect, it } from "vitest";
import { requestBodyCoverage } from "./body-coverage";

it.each([
  [false, false, null, "absent"],
  [false, null, null, "incomplete"],
  [false, true, 0, "incomplete"],
  [true, true, null, "incomplete"],
  [true, true, 0, "complete"],
  [true, true, 4, "incomplete"],
  [true, false, null, "incomplete"]
] as const)("coverage for available=%s, hasBody=%s, truncated=%s", (available, hasBody, truncated, expected) => {
  expect(requestBodyCoverage(available, hasBody, truncated)).toBe(expected);
});
