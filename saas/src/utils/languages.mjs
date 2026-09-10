/*
 * The twelve languages the archive publishes in.
 *
 * Names are endonyms — what each language calls itself — because a reader
 * scanning for their own language recognises "Español" instantly and "Spanish"
 * only if they already read English.
 *
 * `dir` matters more than it looks: Arabic and Urdu are right-to-left, and
 * without it those two locales render with the text ragged down the wrong
 * edge, which is the difference between an article someone reads and one they
 * abandon in the first line.
 */
export const LANGUAGE_NAMES = {
  ar: { name: "العربية", english: "Arabic", dir: "rtl" },
  bn: { name: "বাংলা", english: "Bengali", dir: "ltr" },
  en: { name: "English", english: "English", dir: "ltr" },
  es: { name: "Español", english: "Spanish", dir: "ltr" },
  fr: { name: "Français", english: "French", dir: "ltr" },
  hi: { name: "हिन्दी", english: "Hindi", dir: "ltr" },
  it: { name: "Italiano", english: "Italian", dir: "ltr" },
  la: { name: "Latina", english: "Latin", dir: "ltr" },
  pt: { name: "Português", english: "Portuguese", dir: "ltr" },
  ru: { name: "Русский", english: "Russian", dir: "ltr" },
  ur: { name: "اردو", english: "Urdu", dir: "rtl" },
  zh: { name: "中文", english: "Chinese", dir: "ltr" }
};

export const languageName = code =>
  LANGUAGE_NAMES[code]?.name ?? String(code ?? "").toUpperCase();

export const directionOf = code =>
  LANGUAGE_NAMES[code]?.dir ?? "ltr";
