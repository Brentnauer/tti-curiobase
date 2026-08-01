import { apiInitializer } from "discourse/lib/api";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { iconHTML } from "discourse/lib/icon-library";
import I18n from "discourse-i18n";

// The gravity rating control.
//
// ══════════════════════════════════════════════════════════════════════════
// THIS FILE ONLY ADDS. It never rewrites what the server baked.
// ══════════════════════════════════════════════════════════════════════════
//
// The mean, the voter count and the distribution bar are already in the HTML,
// put there by CardRenderer. If this script fails to load, is blocked, or
// throws, the reader still sees every number — they simply cannot cast one.
//
// That is the correct failure mode and it is why the control mounts into an
// empty div rather than replacing the row. An earlier generation of this system
// painted the whole card client-side, which meant Google saw nothing at all.
//
// ⚠ The DOM is the source of truth for WHAT is being rated. work id and subject
//   come off the row's data attributes, which the server wrote from the topic's
//   own tags. The client is not trusted to name a pairing — the endpoint
//   re-derives and re-checks it regardless.

const MOUNT = ".cb-vote[data-mount='gravity']";

export default apiInitializer("1.0", (api) => {
  const siteSettings = api.container.lookup("service:site-settings");
  if (!siteSettings.curiobase_enabled) {
    return;
  }

  // Mount points are absent from the HTML when voting is off. Bailing here as
  // well means the control cannot appear from a stale bundle against a fresh page.
  if (!siteSettings.curiobase_member_voting_enabled) {
    return;
  }

  const currentUser = api.getCurrentUser();

  api.decorateCookedElement(
    (element, helper) => {
      const post = helper?.getModel?.();
      const topicId = post?.topic_id;
      if (!topicId) {
        return;
      }

      element.querySelectorAll(MOUNT).forEach((mount) => {
        if (mount.dataset.mounted) {
          return;
        }
        mount.dataset.mounted = "1";

        const row = mount.closest(".cb-row");
        const workId = row?.dataset.work;
        const subject = row?.dataset.subject;
        if (!workId || !subject) {
          return;
        }

        // Logged out: say what the scale is and leave. Rendering a control that
        // bounces to a login page on click is a worse experience than not
        // rendering one.
        if (!currentUser) {
          mount.classList.add("cb-vote--anon");
          mount.textContent = I18n.t("curiobase.sign_in_to_rate");
          return;
        }

        if (currentUser.trust_level < siteSettings.curiobase_min_trust_level) {
          mount.classList.add("cb-vote--locked");
          mount.textContent = I18n.t("curiobase.trust_level_to_rate");
          return;
        }

        buildControl(mount, { topicId, subject });
      });
    },
    { onlyStream: true, id: "curiobase-gravity" }
  );
});

function buildControl(mount, ctx) {
  // ⚠ The anchor wording follows the Work's mode, and the server baked it onto
  //   the gravity section. Hardcoding the fiction set here would label a
  //   government report "4 — builds on it", which is not what the button does.
  const mode = mount.closest("[data-mode]")?.dataset.mode || "neutral";

  const stars = document.createElement("div");
  stars.className = "cb-stars";
  stars.setAttribute("role", "radiogroup");
  stars.setAttribute("aria-label", I18n.t("curiobase.gravity_heading"));

  for (let v = 1; v <= 5; v++) {
    const b = document.createElement("button");
    b.type = "button";
    b.className = "cb-star";
    b.dataset.value = String(v);
    b.setAttribute("role", "radio");
    b.setAttribute("aria-checked", "false");
    b.setAttribute("tabindex", v === 1 ? "0" : "-1");
    // The anchor is the label. A star with no stated meaning is a popularity
    // contest; "4 — builds on it" is a judgement someone can disagree with.
    labelButton(b, mode, v, false);
    b.innerHTML = iconHTML("circle");
    // ⚠ Clicking your own mark again takes the vote back. "I no longer have a
    //   view" is a different statement from "I think it is a 3", and a scale
    //   with no way out forces the second when somebody means the first.
    b.addEventListener("click", () => {
      const mine = parseInt(mount.dataset.mine || "", 10);
      return mine === v ? retract(mount, ctx) : cast(mount, ctx, v);
    });
    b.addEventListener("mouseenter", () => preview(mount, v));
    b.addEventListener("focus", () => preview(mount, v));
    b.addEventListener("keydown", (event) => onKey(event, mount, ctx, v));
    stars.appendChild(b);
  }

  stars.addEventListener("mouseleave", () => clearPreview(mount));

  const status = document.createElement("span");
  status.className = "cb-vote-status";

  mount.dataset.anchorMode = mode;
  mount.append(stars, status);

  // Your own rating is fetched, never baked — see CardRenderer#gravity_row.
  ajax("/curiobase/gravity.json", {
    data: { topic_id: ctx.topicId, subject: ctx.subject },
  })
    .then((r) => paint(mount, r?.mine))
    .catch(() => {
      // A failed read of the personal half is not worth a popup. The public
      // numbers are already on screen and correct.
    });
}

function onKey(event, mount, ctx, value) {
  const keys = {
    ArrowRight: 1,
    ArrowUp: 1,
    ArrowLeft: -1,
    ArrowDown: -1,
  };
  const delta = keys[event.key];
  if (delta) {
    event.preventDefault();
    const next = Math.min(5, Math.max(1, value + delta));
    focusMark(mount, next);
    preview(mount, next);
    return;
  }
  if (event.key === "Home") {
    event.preventDefault();
    focusMark(mount, 1);
    preview(mount, 1);
    return;
  }
  if (event.key === "End") {
    event.preventDefault();
    focusMark(mount, 5);
    preview(mount, 5);
    return;
  }
  if (event.key === " " || event.key === "Enter") {
    event.preventDefault();
    const mine = parseInt(mount.dataset.mine || "", 10);
    return mine === value ? retract(mount, ctx) : cast(mount, ctx, value);
  }
}

function focusMark(mount, value) {
  mount.querySelectorAll(".cb-star").forEach((b) => {
    const on = parseInt(b.dataset.value, 10) === value;
    b.setAttribute("tabindex", on ? "0" : "-1");
    if (on) {
      b.focus();
    }
  });
}

function preview(mount, value) {
  mount.dataset.preview = String(value);
  paintMarks(mount, parseInt(mount.dataset.mine || "", 10) || null, value);
  const status = mount.querySelector(".cb-vote-status");
  if (status) {
    status.textContent = anchor(mount.dataset.anchorMode || "neutral", value);
  }
  highlightLegend(mount, value);
}

function clearPreview(mount) {
  delete mount.dataset.preview;
  const mine = parseInt(mount.dataset.mine || "", 10) || null;
  paintMarks(mount, mine, null);
  const status = mount.querySelector(".cb-vote-status");
  if (status) {
    status.textContent = mine ? anchor(mount.dataset.anchorMode || "neutral", mine) : "";
  }
  highlightLegend(mount, mine);
}

function highlightLegend(mount, step) {
  const legend =
    mount.closest(".cb-gravity")?.querySelector(".cb-anchors") ||
    mount.closest(".curiobase-card")?.querySelector(".cb-anchors");
  if (!legend) {
    return;
  }
  legend.querySelectorAll(".cb-anchor-step").forEach((s) => {
    s.classList.toggle("is-hot", step != null && s.dataset.step === String(step));
  });
}

function cast(mount, ctx, value) {
  mount.classList.add("cb-vote--saving");

  ajax("/curiobase/gravity", {
    type: "POST",
    data: { topic_id: ctx.topicId, subject: ctx.subject, value },
  })
    .then((r) => {
      paint(mount, r?.mine ?? value);
      updateAggregate(mount, r);
      broadcastReading(mount, ctx, r);
    })
    .catch(popupAjaxError)
    .finally(() => mount.classList.remove("cb-vote--saving"));
}

function retract(mount, ctx) {
  mount.classList.add("cb-vote--saving");

  ajax("/curiobase/gravity", {
    type: "DELETE",
    data: { topic_id: ctx.topicId, subject: ctx.subject },
  })
    .then((r) => {
      paint(mount, null);
      updateAggregate(mount, r);
      broadcastReading(mount, ctx, r);
    })
    .catch(popupAjaxError)
    .finally(() => mount.classList.remove("cb-vote--saving"));
}

// Same-tab Subject lists (and any other listener) without waiting on MessageBus.
function broadcastReading(mount, ctx, r) {
  const workId = mount.closest(".cb-row")?.dataset.work;
  if (!workId || !ctx?.subject) {
    return;
  }
  document.dispatchEvent(
    new CustomEvent("curiobase:reading", {
      detail: {
        subject: ctx.subject,
        work_id: workId,
        display: r?.display,
        voter_count: r?.voter_count,
      },
    })
  );
}

function paint(mount, value) {
  const chosen = parseInt(value, 10) || null;
  // Remembered so the next click on the same mark knows to retract.
  if (chosen) {
    mount.dataset.mine = String(chosen);
  } else {
    delete mount.dataset.mine;
  }
  delete mount.dataset.preview;
  paintMarks(mount, chosen, null);
  highlightLegend(mount, chosen);

  const status = mount.querySelector(".cb-vote-status");
  if (status) {
    const mode = mount.dataset.anchorMode || "neutral";
    status.textContent = chosen ? anchor(mode, chosen) : "";
  }
}

function paintMarks(mount, mine, previewValue) {
  const mode = mount.dataset.anchorMode || "neutral";
  const fillTo = previewValue || mine;
  mount.querySelectorAll(".cb-star").forEach((b) => {
    const v = parseInt(b.dataset.value, 10);
    const isMine = mine != null && v === mine;
    b.classList.toggle("is-on", !!fillTo && v <= fillTo);
    b.classList.toggle("is-mine", isMine);
    b.classList.toggle("is-preview", previewValue != null && v === previewValue);
    b.setAttribute("aria-checked", isMine ? "true" : "false");
    labelButton(b, mode, v, isMine);
    // Roving tabindex: focused mark, else the chosen vote, else 1.
    const focusTarget = previewValue || mine || 1;
    b.setAttribute("tabindex", v === focusTarget ? "0" : "-1");
  });
}

function labelButton(b, mode, v, isMine) {
  const text = isMine
    ? I18n.t("curiobase.retract")
    : `${v} — ${anchor(mode, v)}`;
  b.setAttribute("aria-label", text);
  b.title = text;
}

// Move the numbers the server baked, so the row agrees with what was just cast.
//
// ⚠ The baked HTML is now momentarily ahead of the database — the post rebakes
//   within a minute (throttled server-side). Repainting here is what stops the
//   reader from watching their own rating fail to register.
// ⚠ r.display is the BLENDED value, computed server-side by the same code that
//   bakes the card. Do not average anything here. The client used to paint the
//   raw member mean, which meant the number jumped the moment you voted and
//   then jumped back when the rebake landed a minute later.
function updateAggregate(mount, r) {
  if (!r) {
    return;
  }
  const score = mount.closest(".cb-row")?.querySelector(".cb-score");
  if (!score) {
    return;
  }

  // ⚠ Retracting the only vote takes the pairing back to unrated, so this has
  //   to be able to run BACKWARDS. An earlier version bailed whenever display
  //   was null, which left a stale number on screen after the vote behind it
  //   had been withdrawn.
  if (r.display == null) {
    score.querySelector(".cb-mean")?.remove();
    score.querySelector(".cb-dist")?.remove();
    score.querySelector(".cb-dist-note")?.remove();
    if (!score.querySelector(".cb-unrated")) {
      const em = document.createElement("span");
      em.className = "cb-unrated";
      em.textContent = I18n.t("curiobase.unrated");
      score.prepend(em);
    }
    return;
  }

  score.querySelector(".cb-unrated")?.remove();

  let mean = score.querySelector(".cb-mean");
  if (!mean) {
    mean = document.createElement("span");
    mean.className = "cb-mean";
    score.prepend(mean);
  }
  mean.textContent = Number(r.display).toFixed(1);
  pulse(mean);

  const dist = Array.isArray(r.distribution) ? r.distribution : null;
  const total = dist ? dist.reduce((a, b) => a + b, 0) : 0;
  if (!total) {
    // Back below two voters — the bar would be a chart of nothing again.
    score.querySelector(".cb-dist")?.remove();
    score.querySelector(".cb-dist-note")?.remove();
    return;
  }

  // The bar is absent from the baked HTML until somebody votes — five segments
  // drawn from one assessment is a chart of nothing. This vote may be the first,
  // so the bar has to be built, not just updated.
  let bar = score.querySelector(".cb-dist");
  if (!bar) {
    bar = document.createElement("span");
    bar.className = "cb-dist";
    bar.setAttribute("aria-hidden", "true");
    for (let i = 1; i <= 5; i++) {
      const seg = document.createElement("span");
      seg.className = `cb-dist-seg cb-dist-${i}`;
      bar.appendChild(seg);
    }
    score.appendChild(bar);
  }
  bar.querySelectorAll(".cb-dist-seg").forEach((seg, i) => {
    seg.style.flexGrow = ((dist[i] / total) * 100).toFixed(2);
  });

  // ⚠ The count labels the BAR, never the number beside it. The number is
  //   standing-weighted; the bar is an unweighted headcount.
  let note = score.querySelector(".cb-dist-note");
  if (!note) {
    note = document.createElement("span");
    note.className = "cb-dist-note";
    bar.after(note);
  }
  note.textContent = distributionNote(dist, r.voter_count);
  note.title = distributionBreakdown(dist);
}

function distributionNote(dist, count) {
  const base = I18n.t("curiobase.members_rated", { count });
  if (!contested(dist)) {
    return base;
  }
  return `${base} · ${I18n.t("curiobase.members_disagree")}`;
}

function contested(dist) {
  if (!Array.isArray(dist) || dist.length !== 5) {
    return false;
  }
  const low = (dist[0] || 0) + (dist[1] || 0);
  const high = (dist[3] || 0) + (dist[4] || 0);
  return low >= 2 && high >= 2;
}

function distributionBreakdown(dist) {
  if (!Array.isArray(dist)) {
    return "";
  }
  return dist
    .map((c, i) => (c > 0 ? `${c} at ${i + 1}` : null))
    .filter(Boolean)
    .join(" · ");
}

function pulse(el) {
  if (!el || window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
    return;
  }
  el.classList.remove("cb-mean--pulse");
  // Restart the animation if it is already mid-flight.
  void el.offsetWidth;
  el.classList.add("cb-mean--pulse");
}

function anchor(mode, v) {
  const sets = {
    fiction: ["mentions", "dressing", "serious", "builds", "essential"],
    nonfiction: ["mentions", "touches", "covers", "focuses", "entirely"],
    neutral: ["mentions", "passing", "engages", "central", "defining"],
  };
  const key = sets[mode] ? mode : "neutral";
  return I18n.t(`curiobase.anchors.${key}.${sets[key][v - 1]}`);
}
