/*
 * How much verbatim text two passages share.
 *
 * This is the objective check on whether a "rewrite" actually rewrote
 * anything. A model handed a source article will sometimes lift a clause or a
 * whole sentence, and the resulting story reads fine — which is exactly why it
 * needs measuring rather than reading.
 *
 * Words are compared with punctuation and case stripped, so re-quoting the same
 * sentence with different curly quotes is still caught.
 */

const words = value => String(value ?? "")
  .toLowerCase()
  .replace(/[^\p{L}\p{N}\s]/gu, " ")
  .split(/\s+/)
  .filter(Boolean);

/*
 * Bare numbers do not count towards a run.
 *
 * Facts are not copyrightable; expression is. "$359.5 million" survives the
 * punctuation strip as three tokens — "359", "5", "million" — so a sentence
 * reporting two figures looked like six words of copied prose. There is no way
 * to report a net loss of $359.5 million in different numbers, and pretending
 * otherwise rejected accurate writing while catching nothing real.
 */
const isNumber = word => /^\d+$/.test(word);

const proseLength = phrase =>
  phrase.split(" ").filter(word => word && !isNumber(word)).length;

/*
 * The longest run of consecutive words that appears in both, capped at `limit`
 * so a pathological pair cannot make this expensive. Returns the run itself,
 * which is what makes a rejection legible in a log, and `prose` — the run
 * length ignoring figures, which is what the threshold is measured against.
 */
export function longestSharedRun(source, candidate, limit = 40) {
  const a = words(source);
  const b = words(candidate);

  if (!a.length || !b.length) return { length: 0, prose: 0, phrase: "" };

  let best = { length: 0, prose: 0, phrase: "" };

  /*
   * Index the source by n-gram, growing n only while matches keep being found.
   * Starting at 5 skips the noise floor: shorter runs are ordinary English and
   * say nothing about copying.
   */
  for (let n = 5; n <= Math.min(limit, a.length, b.length); n++) {
    const seen = new Set();

    for (let i = 0; i + n <= a.length; i++) {
      seen.add(a.slice(i, i + n).join(" "));
    }

    let found = null;

    for (let i = 0; i + n <= b.length; i++) {
      const gram = b.slice(i, i + n).join(" ");

      if (seen.has(gram)) {
        found = gram;
        break;
      }
    }

    if (!found) break;

    best = { length: n, prose: proseLength(found), phrase: found };
  }

  return best;
}

/*
 * Twelve consecutive words of prose is the threshold. Below it you get false
 * positives from stock phrasing — company names, job titles, "according to a
 * statement released on" — and above it real lifting starts slipping through.
 *
 * Measured against `prose`, so a run padded out by figures does not trip it.
 */
export const VERBATIM_LIMIT = 12;

export function isTooClose(source, candidate, limit = VERBATIM_LIMIT) {
  /*
   * The scan still needs headroom above the limit, because a run of twelve
   * prose words may be longer than twelve tokens once figures are in it.
   */
  return longestSharedRun(source, candidate, limit * 2).prose >= limit;
}
