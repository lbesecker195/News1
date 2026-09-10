/*
 * The one-line teaser under a headline: the first sentence of the standfirst,
 * ending in an ellipsis so it reads as an opening rather than a summary. A
 * sentence that stops is finished with; one that trails off asks to be opened.
 */

/*
 * A sentence ends at . ! or ? when the character before it is ordinary prose
 * (so "U.S." and "Inc." mid-sentence are left alone) and what follows starts a
 * new sentence or is the end of the text.
 */
const SENTENCE_END =
  /^(.*?[a-z0-9\)\]”"'’][.!?…]+)(?=\s+["“‘(\[]?[A-Z0-9]|\s*$)/su;

const TRAILING_STOPS = /[.!?…\s]+$/u;

export function firstSentence(text, max = 120) {
  const clean = String(text ?? "").replace(/\s+/g, " ").trim();

  if (!clean) return "";

  const match = clean.match(SENTENCE_END);
  let sentence = (match ? match[1] : clean).replace(TRAILING_STOPS, "");

  if (sentence.length > max) {
    const cut = sentence.lastIndexOf(" ", max);

    sentence = sentence.slice(0, cut > max / 2 ? cut : max).replace(/[,;:\s]+$/u, "");
  }

  return `${sentence}…`;
}
