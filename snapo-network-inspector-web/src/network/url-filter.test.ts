import { describe, expect, it } from "vitest";
import urlFilterFixture from "../../../contracts/network/v1/url-filter.json";
import { matchesUrlFilter, parseUrlFilterTokens } from "./url-filter";

interface UrlFilterContractCase {
  id: string;
  searchText: string;
  tokens: {
    includes: string[];
    excludes: string[];
  };
  matches: Array<{
    url: string;
    expected: boolean;
  }>;
}

describe("url filter contract", () => {
  it("parses and matches the shared URL filter contract", () => {
    expect(urlFilterFixture.version).toBe(1);

    for (const testCase of urlFilterFixture.cases as UrlFilterContractCase[]) {
      const tokens = parseUrlFilterTokens(testCase.searchText);
      expect(tokens, `Unexpected tokens for ${testCase.id}`).toEqual(testCase.tokens);

      for (const match of testCase.matches) {
        expect(matchesUrlFilter(match.url, tokens), `Unexpected match for ${testCase.id} url=${match.url}`).toBe(
          match.expected
        );
      }
    }
  });
});
