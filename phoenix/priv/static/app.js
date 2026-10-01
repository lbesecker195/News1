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
    const submit = loginForm.querySelector("button:not([type=button])");
    const emailLink = $("#email-link");

    /*
     * One form, two ways in. A password signs you in here; an empty password
     * field means the reader wants the link, which is also the reset path.
     */
    const requestLink = async () => {
      const { message: text } = await api("POST", "/api/login", {
        email: new FormData(loginForm).get("email")
      });

      loginForm.reset();
      say(text);
    };

    loginForm.addEventListener("submit", event => {
      event.preventDefault();

      busy(submit, async () => {
        const form = new FormData(loginForm);
        const password = String(form.get("password") ?? "");

        if (!password) return requestLink();

        const { redirect } = await api("POST", "/api/login/password", {
          email: form.get("email"),
          password
        });

        window.location.href = redirect || "/app";
      })();
    });

    emailLink?.addEventListener("click", busy(emailLink, async () => {
      if (!loginForm.reportValidity()) return;

      await requestLink();
    }));
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

  const siteAddress = $("#site-address");
  const subdomainForm = $("#subdomain-form");
  const sitesDomain = $("#sites-domain");
  const renameNote = $("#rename-note");
  const domainForm = $("#domain-form");
  const domainStatus = $("#domain-status");
  const domainState = $("#domain-state");
  const dnsRows = $("#dns-rows");
  const verifyButton = $("#verify-domain");
  const removeDomainButton = $("#remove-domain");
  const planBadge = $("#plan-badge");
  const passwordForm = $("#password-form");
  const passwordState = $("#password-state");
  const passwordLabel = $("#password-label");
  const currentLabel = $("#current-label");
  const removePasswordButton = $("#remove-password");
  const domainIntro = $("#domain-intro");
  const compedNote = $("#comped-note");

  let state = { tenant: null, rss: "", embed: "", stakeholders: null, site: null, preview: null };

  /* ---- the console shell -------------------------------------------------
   * One pane at a time, selected by the fragment, so a section is linkable and
   * the back button steps between them. Falls back to the overview for an
   * unknown fragment rather than showing nothing.
   */
  const panes = Array.from(document.querySelectorAll("[data-pane]"));
  const paneLinks = Array.from(document.querySelectorAll("[data-pane-link]"));

  function showPane(name) {
    const wanted = panes.some(p => p.dataset.pane === name) ? name : "overview";

    for (const pane of panes) pane.hidden = pane.dataset.pane !== wanted;

    for (const link of paneLinks) {
      const current = link.dataset.paneLink === wanted;
      if (current) link.setAttribute("aria-current", "page");
      else link.removeAttribute("aria-current");
    }

    /*
     * Moving focus to the pane heading is what makes this usable by keyboard
     * and screen reader: without it the reading position stays on the link and
     * the new content is never announced.
     */
    const heading = document.querySelector(`[data-pane="${wanted}"] h1`);
    if (heading && document.activeElement !== document.body) {
      heading.setAttribute("tabindex", "-1");
      heading.focus({ preventScroll: true });
    }
  }

  function currentPane() { return (window.location.hash || "#overview").slice(1); }

  window.addEventListener("hashchange", () => showPane(currentPane()));

  if (panes.length) showPane(currentPane());

  /* ---- what is blocking publication --------------------------------------
   * The old page made a customer infer this by scrolling four screens and
   * comparing a stakeholder count against a sentence. It is now one list, in
   * the order the steps actually have to happen, each linking to the pane that
   * fixes it.
   */
  function requirements() {
    const tenant = state.tenant || {};
    const holders = state.stakeholders || {};
    const comped = Boolean(tenant.comped);
    const items = state.preview?.items?.length ?? 0;

    return [
      {
        done: Boolean(tenant.industry),
        title: "Choose your topics",
        detail: tenant.industry ? `${tenant.industry} + ${(tenant.keywords || []).join(", ")}` : "One industry and two keywords.",
        pane: "content"
      },
      {
        done: items > 0,
        title: "Coverage found",
        detail: items > 0 ? `${items} ${items === 1 ? "story" : "stories"} ready` : "Written automatically once your topics are saved.",
        pane: "overview"
      },
      {
        done: holders.remaining === 0,
        title: "Add 10 stakeholders",
        detail: holders.remaining ? `${holders.count} of ${holders.required} added` : `All ${holders.required || 10} added`,
        pane: "audience"
      },
      {
        done: comped || tenant.billing_status === "active",
        title: "Activate the subscription",
        detail: comped ? "Not billed on this account" : "$25/month, cancel any time.",
        pane: "billing"
      }
    ];
  }

  function renderConsole() {
    const holders = state.stakeholders || {};
    const reqs = requirements();
    const blocking = reqs.filter(r => !r.done);
    const live = Boolean(holders.published);

    const card = $("#status-card");
    const dot = $("#status-dot");
    const headline = $("#status-headline");
    const detail = $("#status-detail");

    if (card && dot && headline && detail) {
      card.className = `status-card ${live ? "live" : blocking.length ? "blocked" : ""}`.trim();
      dot.className = `dot ${live ? "live" : blocking.length ? "blocked" : ""}`.trim();
      headline.textContent = live ? "Your briefing is live." : "Not published yet.";
      detail.textContent = live
        ? "Readers, the RSS feed and the embed are all serving."
        : blocking.length === 1
          ? `One thing left: ${blocking[0].title.toLowerCase()}.`
          : `${blocking.length} things left before it publishes.`;
    }

    const list = $("#checklist");

    if (list) {
      list.replaceChildren();

      for (const r of reqs) {
        const li = document.createElement("li");
        li.className = r.done ? "done" : "todo";

        const mark = document.createElement("span");
        mark.className = "mark";
        mark.textContent = r.done ? "✓" : "•";
        /* The tick is decorative; the state is in the text for a screen reader. */
        mark.setAttribute("aria-hidden", "true");

        const what = document.createElement("span");
        what.className = "what";
        const title = document.createElement("b");
        title.textContent = `${r.title}${r.done ? " — done" : ""}`;
        const sub = document.createElement("span");
        sub.textContent = r.detail;
        what.append(title, sub);

        li.append(mark, what);

        if (!r.done) {
          const go = document.createElement("a");
          go.href = `#${r.pane}`;
          go.textContent = "Fix this";
          li.append(go);
        }

        list.append(li);
      }
    }

    const badge = $("#nav-blockers");

    if (badge) {
      badge.textContent = blocking.length ? String(blocking.length) : "";
      badge.hidden = blocking.length === 0;
    }

    const switcher = $("#site-switcher");

    if (switcher && state.site) {
      /* One site today. The control exists now so that the day an account owns
       * several, nothing about this page has to move. */
      const sites = state.sites?.length ? state.sites : [{ id: "current", label: state.tenant?.name || state.site.subdomain, origin: state.site.origin }];
      switcher.replaceChildren();

      for (const s of sites) {
        const option = document.createElement("option");
        option.value = s.id;
        option.textContent = s.label;
        switcher.append(option);
      }

      switcher.disabled = sites.length < 2;
    }
  }

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

  /*
   * The site card. The address shown is the canonical one — the custom
   * domain once it verifies, the platform subdomain until then — and the
   * rename form says plainly when the next rename is allowed.
   */
  function renderSite(site) {
    if (!site) return;

    state.site = site;

    if (siteAddress) {
      siteAddress.replaceChildren();

      const link = document.createElement("a");
      link.href = site.origin;
      link.textContent = site.origin.replace(/^https?:\/\//, "");
      link.rel = "noopener";
      link.target = "_blank";

      const label = document.createElement("span");
      label.className = "small";
      label.textContent = site.domain?.verified
        ? ` — your custom domain. ${site.platformHost} redirects here.`
        : " — your site address.";

      siteAddress.append(link, label);
    }

    if (subdomainForm) {
      subdomainForm.elements.subdomain.value = site.subdomain;
    }

    if (sitesDomain) sitesDomain.textContent = `.${site.sitesDomain}`;

    if (renameNote) {
      renameNote.textContent = site.rename.allowed
        ? `You can rename once every ${site.rename.intervalHours} hours. ` +
          `The old address redirects for ${site.rename.redirectDays} days.`
        : `Renamed recently. Next rename available ${
          new Date(site.rename.nextAt).toLocaleString()
        }.`;
      renameNote.className = site.rename.allowed ? "small" : "small warn";
    }

    const submit = subdomainForm?.querySelector("button");
    if (submit) submit.disabled = !site.rename.allowed;

    /*
     * A custom domain is the enterprise plan. The form says so rather than
     * disappearing: someone on the $25 plan should be able to see what the
     * upgrade buys without asking.
     */
    const enterprise = site.entitlements?.customDomain !== false;

    if (planBadge) {
      planBadge.textContent = enterprise ? "Enterprise" : "Enterprise plan";
      planBadge.className = enterprise ? "badge ok" : "badge";
      planBadge.hidden = false;
    }

    if (domainIntro && !enterprise) {
      domainIntro.textContent =
        "Hosting your briefing on a hostname you own — news.yourcompany.com — " +
        "is part of the enterprise plan, along with removing our mark from " +
        "the embed. Your site stays live at its address above either way.";
    }

    if (domainForm) {
      domainForm.elements.hostname.value = site.domain?.hostname ?? "";

      for (const field of domainForm.elements) field.disabled = !enterprise;
    }

    if (domainStatus) domainStatus.hidden = !site.domain;

    if (site.domain && domainState) {
      const { hostname, verified, lastError, lastCheckedAt } = site.domain;

      domainState.textContent = verified
        ? `${hostname} is verified and live.`
        : `${hostname} is not verified yet.` +
          (lastError ? ` ${lastError}` : "") +
          (lastCheckedAt ? ` Last checked ${new Date(lastCheckedAt).toLocaleString()}.` : "");
      domainState.className = verified ? "small ok" : "small warn";
    }

    if (site.domain && dnsRows) {
      dnsRows.replaceChildren();

      for (const record of site.domain.records) {
        const row = document.createElement("tr");

        for (const value of [record.type, record.name, record.value]) {
          const cell = document.createElement("td");
          const code = document.createElement("code");
          code.textContent = value;
          cell.append(code);
          row.append(cell);
        }

        row.title = record.purpose;
        dnsRows.append(row);
      }
    }
  }

  /*
   * The password section only ever reflects whether one is set — the server
   * never sends anything else about it, and there is nothing else to show.
   */
  function renderPassword(password) {
    const set = Boolean(password?.set);

    if (passwordState) {
      passwordState.textContent = set
        ? `A password is set${
          password.setAt
            ? ` (${new Date(password.setAt).toLocaleDateString()})`
            : ""
        }. You can sign in with it or with an emailed link.`
        : "No password set. You sign in with an emailed link.";
      passwordState.className = set ? "small ok" : "small";
    }

    if (passwordLabel) passwordLabel.textContent = set ? "New password" : "Password";
    if (currentLabel) currentLabel.hidden = !set;

    const current = currentLabel?.querySelector("input");

    if (current) current.required = set;
    if (removePasswordButton) removePasswordButton.hidden = !set;
  }

  /*
   * Three empty states, not two. A tenant that has never saved its topics has
   * no topic row and so nothing is being prepared for it; telling it to check
   * back in a few minutes points it away from the one form that starts the work.
   */
  function emptyPreviewText(data) {
    if (!state.tenant?.industry) return "Save your topics to prepare a preview.";

    return data.refreshed_at
      ? "No coverage matched your topics yet."
      : "Preview is being prepared. Check back in a few minutes.";
  }

  function renderPreview(data) {
    if (!previewBox) return;

    previewBox.replaceChildren();

    if (!data.items?.length) {
      previewBox.textContent = emptyPreviewText(data);
      return;
    }

    const stamp = document.createElement("p");
    stamp.className = "small";
    stamp.textContent = `Updated ${new Date(data.refreshed_at).toLocaleString()}`;
    previewBox.append(stamp);

    /*
     * A sample, not the archive. Showing every story made the overview two
     * screens tall on its own and buried everything under it; the feed is the
     * place to read them all.
     */
    const shown = data.items.slice(0, 4);

    for (const item of shown) {
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

    if (data.items.length > shown.length) {
      const more = document.createElement("p");
      more.className = "small muted";
      more.textContent = `and ${data.items.length - shown.length} more in the feed`;
      previewBox.append(more);
    }
  }

  async function load() {
    const data = await api("GET", "/api/me");

    state = {
      tenant: data.tenant,
      rss: data.rss,
      embed: data.embed,
      stakeholders: data.stakeholders,
      site: data.site
    };

    fillCompanyForm(data.tenant);
    renderPassword(data.password);
    renderSubscribers(data.subscribers || []);
    renderStakeholders(data.stakeholders);
    renderSite(data.site);
    renderFeedLinks();

    const status = data.tenant.billing_status;

    /*
     * A comped account — platform staff, the demo site — is entitled to the
     * service with nothing behind it to activate or cancel, so it is offered
     * neither button.
     */
    const comped = Boolean(data.tenant.comped);

    if (billingStatus) {
      billingStatus.textContent = comped
        ? ""
        : BILLING_TEXT[status] || `Billing status: ${status}`;
    }

    if (compedNote) {
      compedNote.textContent = comped
        ? "This account is not billed."
        : "";
      compedNote.hidden = !comped;
    }

    /* Only offer the action that is actually available in this state. */
    const subscribed = status === "active";

    if (checkoutButton) checkoutButton.hidden = comped || subscribed;
    if (cancelButton) cancelButton.hidden = comped || !subscribed;

    renderConsole();

    if (data.tenant.industry) {
      await refreshPreview();
    }
  }

  /*
   * The content worker is what fills a preview, so a refresh normally finds
   * exactly what was already on screen. It is the one action here that says
   * nothing back, and an unchanged box is indistinguishable from a dead button,
   * so a deliberate press always gets a word.
   */
  async function refreshPreview({ announce = false } = {}) {
    const data = await api("GET", "/api/preview");

    state.preview = data;
    renderPreview(data);
    renderConsole();

    if (!announce) return;

    const count = data.items?.length ?? 0;

    say(count
      ? `Preview updated — ${count} ${count === 1 ? "story" : "stories"}.`
      : emptyPreviewText(data));
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

  refreshButton?.addEventListener("click", busy(refreshButton, () => refreshPreview({ announce: true })));

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

  subdomainForm?.addEventListener("submit", event => {
    event.preventDefault();

    const submit = subdomainForm.querySelector("button");

    busy(submit, async () => {
      const wanted = new FormData(subdomainForm).get("subdomain");

      /*
       * A rename is one a day and every shared link changes with it, so it
       * asks first.
       */
      const confirmed = window.confirm(
        `Rename your site to ${wanted}.${state.site?.sitesDomain}? ` +
        "You can rename again in 24 hours."
      );

      if (!confirmed) return;

      const { message: text, site } = await api("POST", "/api/site/subdomain", {
        subdomain: wanted
      });

      say(text);
      renderSite(site);
      await load();
    })();
  });

  domainForm?.addEventListener("submit", event => {
    event.preventDefault();

    const submit = domainForm.querySelector("button");

    busy(submit, async () => {
      const { message: text, site } = await api("POST", "/api/site/domain", {
        hostname: new FormData(domainForm).get("hostname")
      });

      say(text);
      renderSite(site);
    })();
  });

  verifyButton?.addEventListener("click", busy(verifyButton, async () => {
    const { message: text, verified, site } = await api(
      "POST",
      "/api/site/domain/verify"
    );

    say(text, !verified);
    renderSite(site);

    if (verified) await load();
  }));

  removeDomainButton?.addEventListener("click", busy(removeDomainButton, async () => {
    if (!window.confirm("Remove the custom domain? Your site returns to its platform address.")) {
      return;
    }

    const { message: text, site } = await api("DELETE", "/api/site/domain");

    say(text);
    renderSite(site);
    await load();
  }));

  passwordForm?.addEventListener("submit", event => {
    event.preventDefault();

    const submit = passwordForm.querySelector("button:not([type=button])");

    busy(submit, async () => {
      const form = new FormData(passwordForm);

      const { message: text, password } = await api("POST", "/api/password", {
        password: form.get("password"),
        current: form.get("current") || undefined
      });

      passwordForm.reset();
      say(text);
      renderPassword(password);
      await load();
    })();
  });

  removePasswordButton?.addEventListener("click", busy(removePasswordButton, async () => {
    const current = passwordForm?.elements.current?.value;

    if (!current) {
      say("Enter your current password to remove it.", true);
      return;
    }

    const { message: text, password } = await api("DELETE", "/api/password", {
      current
    });

    passwordForm.reset();
    say(text);
    renderPassword(password);
  }));

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
