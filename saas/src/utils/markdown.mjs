import { escapeHtml } from "./html.mjs";

/*
 * The imported articles are Markdown, and a small deterministic renderer beats
 * a dependency here: the content is ours, its shape is known — headings, bold,
 * italic, links, lists, paragraphs — and everything is escaped before any tag
 * is added, so no source text can introduce markup.
 */
export function renderMarkdown(source) {
  const blocks = String(source ?? "")
    .replace(/\r\n/g, "\n")
    .split(/\n{2,}/)
    .map(block => block.trim())
    .filter(Boolean);

  return blocks.map(renderBlock).join("\n");
}

function renderBlock(block) {
  const heading = block.match(/^(#{1,6})\s+(.*)$/s);

  if (heading) {
    /* h1 is the page title; body headings start one level down. */
    const level = Math.min(6, heading[1].length + 1);

    return `<h${level}>${inline(heading[2].trim())}</h${level}>`;
  }

  if (/^>\s/.test(block)) {
    const quoted = block.split("\n")
      .map(line => line.replace(/^>\s?/, ""))
      .join(" ");

    return `<blockquote><p>${inline(quoted)}</p></blockquote>`;
  }

  const lines = block.split("\n");

  if (lines.every(line => /^\s*[-*]\s+/.test(line))) {
    return list(lines, /^\s*[-*]\s+/, "ul");
  }

  if (lines.every(line => /^\s*\d+[.)]\s+/.test(line))) {
    return list(lines, /^\s*\d+[.)]\s+/, "ol");
  }

  return `<p>${inline(block.replace(/\n/g, " "))}</p>`;
}

const list = (lines, marker, tag) =>
  `<${tag}>${
    lines.map(line => `<li>${inline(line.replace(marker, ""))}</li>`).join("")
  }</${tag}>`;

/*
 * Escaping happens first, so anything in the source that looks like markup is
 * text by the time the inline patterns run. The patterns then add the only
 * tags that reach the page.
 */
function inline(text) {
  return escapeHtml(text)
    .replace(/\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)/g,
      (match, label, href) =>
        `<a href="${href}" rel="noopener noreferrer">${label}</a>`)
    .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
    .replace(/(^|[^*])\*([^*\n]+)\*/g, "$1<em>$2</em>")
    .replace(/`([^`]+)`/g, "<code>$1</code>");
}
