/*
 * The section menu on a news site scrolls horizontally when there are more
 * sections than fit, and fades its trailing edge to say so. The fade used to be
 * unconditional, which meant a site with three sections permanently dimmed its
 * last one for no reason.
 *
 * This is the whole of it: add a class while the row actually overflows. No JS,
 * or JS that fails, leaves the menu unfaded — the honest default, because the
 * fade is a claim that there is more to see.
 */
(() => {
  "use strict";

  const row = document.querySelector(".topics");

  if (!row) return;

  function sync() {
    /*
     * An unlaid-out row — a hidden tab, a collapsed pane, display:none on an
     * ancestor — measures zero wide against a non-zero scrollWidth, which reads
     * as overflow and is not. Treat it as "do not know" and leave the fade off;
     * the observer below re-runs the moment it has a width.
     */
    if (row.clientWidth === 0) return;

    /*
     * A pixel of slack: sub-pixel layout routinely leaves scrollWidth a hair
     * above clientWidth on a row that visibly fits, and fading on that would
     * reintroduce the bug at a smaller scale.
     */
    row.classList.toggle("is-scrollable", row.scrollWidth - row.clientWidth > 1);
  }

  sync();

  /* A resize changes the answer; so does a web font landing after first paint. */
  if (window.ResizeObserver) {
    new ResizeObserver(sync).observe(row);
  } else {
    window.addEventListener("resize", sync, { passive: true });
  }

  document.fonts?.ready.then(sync).catch(() => {});
})();
