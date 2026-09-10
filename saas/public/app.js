/*
 * The whole browser layer. No framework and no build step: every page is
 * server-rendered, and this only wires the forms on the marketing page and the
 * dashboard to the JSON API.
 *
 * Every element lookup is optional, so the same file is safe on both pages.
 */
(() => {
  "use strict";

  const $ = selector => document.querySelector(selector);

  const message = $("#message");
  let messageTimer;

  function say(text, isError = false) {
    if (!message) return;

    message.textContent = text;
    message.className = isError ? "error" : "ok";

    clearTimeout(messageTimer);
    messageTimer = setTimeout(() => {
      message.textContent = "";
      message.className = "";
    }, 8000);
  }

  /*
   * One place that knows how to talk to the API. Errors from the server are
   * JSON with an { error } field; anything else (a proxy error page, say)
   * still has to produce a usable message.
   */
  async function api(method, path, body) {
    const response = await fetch(path, {
      method,
      headers: body ? { "content-type": "application/json" } : undefined,
      body: body ? JSON.stringify(body) : undefined
    });

    let data = {};

    try {
      data = await response.json();
    } catch {
      /* Non-JSON response; fall through to the status-based message. */
    }

    if (!response.ok) {
      if (response.status === 401) {
        window.location.href = "/";
      }

      throw new Error(data.error || `Request failed (${response.status})`);
    }

    return data;
  }

  /* Prevents a double submit from queuing two invitations or two checkouts. */
  function busy(element, run) {
    return async (...args) => {
      if (element.disabled) return;

      element.disabled = true;

      try {
        await run(...args);
      } catch (error) {
        say(error.message, true);
      } finally {
        element.disabled = false;
      }
    };
  }


  /* ---- Marketing page --------------------------------------------------- */

  const loginForm = $("#login-form");

  if (loginForm) {
    const submit = loginForm.querySelector("button");

    loginForm.addEventListener("submit", event => {
      event.preventDefault();

      busy(submit, async () => {
        const { message: text } = await api("POST", "/api/login", {
          email: new FormData(loginForm).get("email")
        });

        loginForm.reset();
        say(text);
      })();
    });
  }

  /* ---- Dashboard -------------------------------------------------------- */

  const companyForm = $("#company-form");

  if (!companyForm) return;

  const previewBox = $("#preview");
  const billingStatus = $("#billing-status");
  const subscriberList = $("#subscribers");
  const checkoutButton = $("#checkout");
  const cancelButton = $("#cancel");
  const feedLinks = $("#feed-links");
  const embedCode = $("#embed-code");
  const publishState = $("#publish-state");
  const stakeholderState = $("#stakeholder-state");

  let state = { tenant: null, rss: "", embed: "", stakeholders: null };

  function fillCompanyForm(tenant) {
    if (!tenant) return;

    const fields = companyForm.elements;

    fields.name.value = tenant.name || "";
    fields.domain.value = tenant.domain || "";
    fields.industry.value = tenant.industry || "";
    const [first = "", second = ""] = tenant.keywords || [];

    fields.keyword1.value = first;
    fields.keyword2.value = second;
    fields.language.value = tenant.language || "en";
  }

  /* Mirrors the PayPal subscription states billing.service.mjs stores. */
  const BILLING_TEXT = {
    active: "Subscription active.",
    approval_pending: "Waiting for you to approve the subscription at PayPal.",
    past_due: "A payment failed. Update your payment method at PayPal.",
    suspended: "Subscription suspended at PayPal. Your feed is offline.",
    cancelled: "Renewals stopped. Your feed goes offline at the period end.",
    expired: "Subscription expired. Your feed is offline.",
    inactive: "Not subscribed yet. Your feed is private until you activate."
  };

  function renderSubscribers(rows) {
    if (!subscriberList) return;

    subscriberList.replaceChildren();

    if (!rows.length) {
      const empty = document.createElement("li");
      empty.textContent = "No recipients yet.";
      subscriberList.append(empty);
      return;
    }

    for (const row of rows) {
      const item = document.createElement("li");

      /*
       * textContent, not innerHTML: these addresses are attacker-influenced
       * (anyone can be invited by address) and must never be parsed as markup.
       */
      const label = document.createElement("span");
      label.textContent = `${row.email} — ${row.state}`;

      const remove = document.createElement("button");
      remove.type = "button";
      remove.textContent = "Remove";
      remove.addEventListener("click", busy(remove, async () => {
        await api("DELETE", "/api/subscribers", { email: row.email });
        say("Recipient removed.");
        await load();
      }));

      item.append(label, " ", remove);
      subscriberList.append(item);
    }
  }

  /*
   * The roster is what publishes the feed, so both the invite section and the
   * publish section say where it stands rather than leaving the owner to
   * wonder why their embed URL is not live.
   */
  function renderStakeholders(stakeholders) {
    if (!stakeholders) return;

    const { count, required, remaining, published } = stakeholders;

    if (stakeholderState) {
      stakeholderState.textContent = remaining
        ? `${count} of ${required} stakeholders added — ` +
          `${remaining} more to publish your feed.`
        : `All ${required} stakeholders added.`;
      stakeholderState.className = remaining ? "small" : "small ok";
    }

    if (publishState) {
      publishState.textContent = published
        ? "Your feed is live."
        : remaining
          ? `Not published yet: add ${remaining} more stakeholder${
            remaining === 1 ? "" : "s"
          } to publish these links.`
          : "Not published yet: activate your subscription to publish these links.";
      publishState.className = published ? "small ok" : "small warn";
    }
  }

  function renderFeedLinks() {
    if (feedLinks) {
      feedLinks.replaceChildren();

      for (const [label, href] of [["RSS", state.rss], ["Embed", state.embed]]) {
        const anchor = document.createElement("a");
        anchor.href = href;
        anchor.textContent = `${label} — ${href}`;
        anchor.rel = "noopener";
        feedLinks.append(anchor, document.createElement("br"));
      }
    }

    if (embedCode) {
      embedCode.value =
        `<iframe src="${state.embed}" width="100%" height="600" ` +
        'style="border:0" title="Company news"></iframe>';
    }
  }

  function renderPreview(data) {
    if (!previewBox) return;

    previewBox.replaceChildren();

    if (!data.items?.length) {
      previewBox.textContent = data.refreshed_at
        ? "No coverage matched your topics yet."
        : "Preview is being prepared. Check back in a few minutes.";
      return;
    }

    const stamp = document.createElement("p");
    stamp.className = "small";
    stamp.textContent = `Updated ${new Date(data.refreshed_at).toLocaleString()}`;
    previewBox.append(stamp);

    for (const item of data.items) {
      const article = document.createElement("article");

      const heading = document.createElement("h3");
      heading.textContent = item.title;

      const summary = document.createElement("p");
      summary.textContent = item.summary;

      const source = document.createElement("p");
      source.className = "small";
      source.textContent = `Source: ${item.source}`;

      article.append(heading, summary, source);
      previewBox.append(article);
    }
  }

  async function load() {
    const data = await api("GET", "/api/me");

    state = {
      tenant: data.tenant,
      rss: data.rss,
      embed: data.embed,
      stakeholders: data.stakeholders
    };

    fillCompanyForm(data.tenant);
    renderSubscribers(data.subscribers || []);
    renderStakeholders(data.stakeholders);
    renderFeedLinks();

    const status = data.tenant.billing_status;

    if (billingStatus) {
      billingStatus.textContent =
        BILLING_TEXT[status] || `Billing status: ${status}`;
    }

    /* Only offer the action that is actually available in this state. */
    const subscribed = status === "active";

    if (checkoutButton) checkoutButton.hidden = subscribed;
    if (cancelButton) cancelButton.hidden = !subscribed;

    if (data.tenant.industry) {
      await refreshPreview();
    }
  }

  async function refreshPreview() {
    renderPreview(await api("GET", "/api/preview"));
  }

  companyForm.addEventListener("submit", event => {
    event.preventDefault();

    const submit = companyForm.querySelector("button:not([type=button])");

    busy(submit, async () => {
      const form = new FormData(companyForm);

      const { message: text } = await api("POST", "/api/company", {
        name: form.get("name"),
        domain: form.get("domain"),
        industry: form.get("industry"),
        keywords: [form.get("keyword1"), form.get("keyword2")]
          .map(word => String(word ?? "").trim())
          .filter(Boolean),
        language: form.get("language")
      });

      say(text);
      await load();
    })();
  });

  const suggestButton = $("#suggest");

  suggestButton?.addEventListener("click", busy(suggestButton, async () => {
    const form = new FormData(companyForm);

    const suggestion = await api("POST", "/api/suggest", {
      name: form.get("name") || "",
      domain: form.get("domain") || "",
      industry: form.get("industry") || ""
    });

    companyForm.elements.industry.value = suggestion.industry;
    companyForm.elements.keyword1.value = suggestion.keywords[0] ?? "";
    companyForm.elements.keyword2.value = suggestion.keywords[1] ?? "";

    say("Suggestions filled in. Review them, then save.");
  }));

  const refreshButton = $("#refresh-preview");

  refreshButton?.addEventListener("click", busy(refreshButton, refreshPreview));

  checkoutButton?.addEventListener("click", busy(checkoutButton, async () => {
    const { url } = await api("POST", "/api/checkout");
    window.location.href = url;
  }));

  cancelButton?.addEventListener("click", busy(cancelButton, async () => {
    /*
     * PayPal has no hosted portal to bounce through, so this is the point of no
     * return and it asks first.
     */
    const confirmed = window.confirm(
      "Stop future renewals? Your feed stays up until the paid period ends."
    );

    if (!confirmed) return;

    const { message: text } = await api("POST", "/api/cancel");

    say(text);
    await load();
  }));

  const inviteForm = $("#invite-form");

  inviteForm?.addEventListener("submit", event => {
    event.preventDefault();

    const submit = inviteForm.querySelector("button");

    busy(submit, async () => {
      const form = new FormData(inviteForm);

      const { message: text } = await api("POST", "/api/subscribers", {
        email: form.get("email"),
        authorised: form.get("authorised") === "on"
      });

      inviteForm.reset();
      say(text);
      await load();
    })();
  });

  const copyButton = $("#copy-digest");

  copyButton?.addEventListener("click", busy(copyButton, async () => {
    const { items } = await api("GET", "/api/preview");

    const digest = [
      `${state.tenant?.name || "Company"} news briefing`,
      "",
      ...(items || []).map(item =>
        `${item.title}\n${item.summary}\nSource: ${item.source}\n`
      ),
      `Powered by Rnews1 — ${window.location.origin}`
    ].join("\n");

    await navigator.clipboard.writeText(digest);
    say("Branded digest copied to the clipboard.");
  }));

  const logoutButton = $("#logout");

  logoutButton?.addEventListener("click", busy(logoutButton, async () => {
    await api("POST", "/api/logout");
    window.location.href = "/";
  }));

  const params = new URLSearchParams(window.location.search);

  if (params.get("checkout") === "success") {
    say("Payment received. Activation can take a moment to appear.");
  } else if (params.get("checkout") === "canceled") {
    say("Checkout canceled. Nothing was charged.");
  }

  load().catch(error => say(error.message, true));
})();
