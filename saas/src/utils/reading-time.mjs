/*
 * Minutes to read a body of text.
 *
 * Shown to the reader because an explicit, honest estimate is what lets
 * someone decide to start — an unmarked wall of text is what makes them leave
 * before the first paragraph.
 *
 * Two rates, because words are not comparable across writing systems. Latin
 * script is counted in words at 220 a minute; Chinese and Japanese are counted
 * in characters at 500, since a "word" split on whitespace would count a whole
 * paragraph as one and report every article as a one-minute read.
 */
const WORDS_PER_MINUTE = 220;
const CJK_PER_MINUTE = 500;

const CJK = /[぀-ヿ㐀-䶿一-鿿豈-﫿]/g;

export function readingMinutes(text) {
  const source = String(text ?? "")
    /* Markdown syntax is not read aloud. */
    .replace(/[#*`>_[\]()]/g, " ")
    .trim();

  if (!source) return 0;

  const cjk = (source.match(CJK) ?? []).length;
  const words = source.split(/\s+/).filter(Boolean).length;

  const minutes = cjk > words
    ? cjk / CJK_PER_MINUTE
    : words / WORDS_PER_MINUTE;

  return Math.max(1, Math.round(minutes));
}
