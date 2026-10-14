export interface TextMatch {
  term: string;
  start: number;
  end: number;
}

// Lowercasing can expand a character. Keep offsets in the original text.
export function* findTextMatches(
  text: string,
  terms: readonly string[],
  perTermLimit = Infinity
): Generator<TextMatch> {
  const lower = text.toLowerCase();
  let starts: Int32Array | undefined;
  let ends: Int32Array | undefined;
  for (const term of new Set(terms)) {
    const token = term.toLowerCase();
    if (!token) continue;
    let count = 0;
    for (
      let index = lower.indexOf(token);
      index !== -1 && count < perTermLimit;
      index = lower.indexOf(token, index + 1)
    ) {
      if (!starts && lower.length !== text.length) {
        starts = new Int32Array(lower.length);
        ends = new Int32Array(lower.length);
        let source = 0,
          target = 0;
        for (const character of text) {
          const width = character.toLowerCase().length;
          for (let i = 0; i < width; i++) {
            starts[target + i] = source + (width === character.length ? i : 0);
            ends[target + i] = source + (width === character.length ? i + 1 : character.length);
          }
          source += character.length;
          target += width;
        }
      }
      yield { term, start: starts?.[index] ?? index, end: ends?.[index + token.length - 1] ?? index + token.length };
      count++;
    }
  }
}
