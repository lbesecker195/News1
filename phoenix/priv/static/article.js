/*
 * A reading progress indicator.
 *
 * It exists because a long article with no sense of how much is left reads as
 * endless, and endless is what people abandon. The bar answers "how far in am
 * I" without the reader having to guess from a scrollbar.
 *
 * Deliberately tiny and passive: no layout reads inside the scroll handler, no
 * dependency, and nothing happens at all if the element is missing.
 */
(() => {
  "use strict";

  /*
   * Modern browsers drive the bar from CSS with a scroll timeline, which is
   * smoother and cheaper than anything achievable here. This script is only
   * the fallback for the ones that cannot.
   */
  if (window.CSS?.supports?.("animation-timeline", "scroll()")) return;

  const bar = document.getElementById("read-progress");
  const article = document.querySelector(".story .prose");

  if (!bar || !article) return;

  /* Respect a reader who has asked for less motion. */
  const still = window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;

  if (still) bar.style.transition = "none";

  let ticking = false;

  function measure() {
    const start = article.offsetTop;
    const length = article.offsetHeight - window.innerHeight;

    /* Shorter than the viewport: there is no progress to report. */
    if (length <= 0) {
      bar.style.width = "0%";
      return;
    }

    const read = (window.scrollY - start) / length;
    const clamped = Math.min(1, Math.max(0, read));

    bar.style.width = `${(clamped * 100).toFixed(1)}%`;
  }

  function onScroll() {
    if (ticking) return;

    ticking = true;

    window.requestAnimationFrame(() => {
      measure();
      ticking = false;
    });
  }

  window.addEventListener("scroll", onScroll, { passive: true });
  window.addEventListener("resize", onScroll, { passive: true });

  measure();
})();
