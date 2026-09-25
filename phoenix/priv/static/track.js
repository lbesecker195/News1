/*
 * Click tracking. Every link and every button, on every page that includes
 * the site chrome.
 *
 * What it sends: the path it happened on, what was clicked, and the text on
 * it. What it does not send: any identifier, any cookie, any query string.
 * There is nothing here to tie two clicks to one person, which is the point
 * — the question is what works on the page, not who read it.
 *
 * sendBeacon is what makes this reliable through a navigation: the browser
 * takes ownership of the request before it tears the page down. Where it is
 * missing, a keepalive fetch does the same job, and if both are missing the
 * click is simply not recorded.
 */
(() => {
  "use strict";

  const ENDPOINT = "/e";
  const MAX_LABEL = 160;

  const send = events => {
    if (!events.length) return;

    const body = JSON.stringify({ events });

    try {
      if (navigator.sendBeacon) {
        navigator.sendBeacon(ENDPOINT, new Blob([body], {
          type: "application/json"
        }));

        return;
      }

      fetch(ENDPOINT, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body,
        keepalive: true
      }).catch(() => {});
    } catch {
      /* Analytics must never break the page it is measuring. */
    }
  };

  const text = element => (element.textContent || "")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, MAX_LABEL);

  /*
   * The clicked element is often a <span> inside the link, so the nearest
   * enclosing link or button is what the reader actually clicked.
   */
  const describe = element => {
    const link = element.closest("a[href]");

    if (link) {
      const href = link.getAttribute("href") || "";
      let external = false;
      let path = href;

      try {
        const url = new URL(link.href, window.location.href);

        external = url.host !== window.location.host;
        /* The query is dropped: it is where tokens live. */
        path = external ? `${url.origin}${url.pathname}` : url.pathname;
      } catch {
        /* A relative or malformed href is reported as written. */
      }

      return {
        kind: "link",
        target: path.slice(0, 512),
        label: link.getAttribute("data-track") || text(link),
        external
      };
    }

    const button = element.closest("button, [role=button], input[type=submit]");

    if (!button) return null;

    return {
      kind: "button",
      target: (button.getAttribute("data-track") || button.id ||
        button.getAttribute("name") || text(button) || "button").slice(0, 512),
      label: text(button) || button.value || "",
      external: false
    };
  };

  /*
   * Capture phase, so a handler that calls stopPropagation — the dashboard
   * does, on several buttons — does not hide the click from us.
   */
  document.addEventListener("click", event => {
    /* Only a real primary click; right-clicks open menus, not pages. */
    if (event.button !== 0) return;

    const target = event.target;

    if (!target || typeof target.closest !== "function") return;

    const described = describe(target);

    if (!described) return;

    send([{ ...described, path: window.location.pathname }]);
  }, { capture: true });

  /*
   * SeriouslySimpleAnalytics keeps projects apart, but its own tracker
   * (wa.js, loaded by the layout when an account is configured) knows only
   * the account. So each page view is also reported to its ping endpoint
   * under this host's project — the subdomain, which the layout writes on
   * the tag. Same rules as above: no identifier, no cookie, no query string.
   */
  const tracker = document.querySelector('script[src$="/wa.js"][data-site]');

  if (tracker && tracker.dataset.project) {
    try {
      const home = new URL(tracker.getAttribute("src"), window.location.href);
      const ping = new URL("/api/ping", home.origin);
      const params = ping.searchParams;

      params.set("uid", tracker.dataset.site);
      params.set("type", "web");
      params.set("project", tracker.dataset.project);
      params.set("event", "page_view");
      params.set("path", window.location.pathname);
      params.set("title", (document.title || "").slice(0, 255));

      try {
        const from = document.referrer && new URL(document.referrer);

        if (from) params.set("ref", `${from.origin}${from.pathname}`);
      } catch {
        /* An unparseable referrer is no referrer. */
      }

      try {
        const zone = Intl.DateTimeFormat().resolvedOptions().timeZone;

        if (zone) params.set("tz", zone);
      } catch {
        /* Without a zone the ping still counts. */
      }

      fetch(ping.href, {
        mode: "no-cors",
        credentials: "omit",
        keepalive: true
      }).catch(() => {});
    } catch {
      /* Analytics must never break the page it is measuring. */
    }
  }
})();
