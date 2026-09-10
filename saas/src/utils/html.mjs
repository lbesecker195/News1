const HTML_ENTITIES = {
  "&": "&amp;",
  "<": "&lt;",
  ">": "&gt;",
  '"': "&quot;",
  "'": "&#39;"
};

export const escapeHtml = value =>
  String(value ?? "").replace(/[&<>"']/g, character => HTML_ENTITIES[character]);

/*
 * Article URLs come from third-party feeds and are rendered into href
 * attributes, so anything that is not plain http(s) is dropped rather than
 * passed through (javascript:, data:, and friends).
 */
export function safeURL(value) {
  try {
    const url = new URL(String(value));
    return ["http:", "https:"].includes(url.protocol) ? url.href : "#";
  } catch {
    return "#";
  }
}
