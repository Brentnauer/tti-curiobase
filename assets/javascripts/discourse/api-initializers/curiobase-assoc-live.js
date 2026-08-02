import { apiInitializer } from "discourse/lib/api";
import { ajax } from "discourse/lib/ajax";
import I18n from "discourse-i18n";

// Live gravity on a Subject association list.
//
// ══════════════════════════════════════════════════════════════════════════
// BAKED HTML STAYS. THIS ONLY REFRESHES THE NUMBERS.
// ══════════════════════════════════════════════════════════════════════════
//
// Crawlers and no-JS readers keep the cooked association list. Browsers:
//   1. Fetch one batched reading set on mount (beats a stale cook)
//   2. Subscribe to MessageBus for votes cast in other tabs
//   3. Listen for same-tab votes via `curiobase:reading` (Work card → Subject)

const ASSOC = ".cb-assoc";
const EVENT = "curiobase:reading";

export default apiInitializer("1.0", (api) => {
  const siteSettings = api.container.lookup("service:site-settings");
  if (!siteSettings.curiobase_enabled) {
    return;
  }
  if (!siteSettings.curiobase_member_voting_enabled) {
    return;
  }

  // service:message-bus is a factory for window.MessageBus — fall back raw if
  // the container lookup is unavailable during early boot.
  let messageBus;
  try {
    messageBus = api.container.lookup("service:message-bus");
  } catch {
    messageBus = null;
  }
  messageBus = messageBus || window.MessageBus;

  api.decorateCookedElement(
    (element) => {
      element.querySelectorAll(ASSOC).forEach((block) => bindBlock(block, messageBus));
    },
    { onlyStream: true, id: "curiobase-assoc-live" }
  );

  document.addEventListener(EVENT, (event) => {
    const detail = event.detail;
    if (!detail?.subject || !detail?.work_id) {
      return;
    }
    document.querySelectorAll(ASSOC).forEach((block) => {
      if (block.dataset.liveSubject !== detail.subject) {
        return;
      }
      paintRow(block, detail.work_id, detail);
    });
  });
});

function bindBlock(block, messageBus) {
  if (block.dataset.liveBound) {
    return;
  }

  const subject =
    block.dataset.subject ||
    block.closest(".curiobase-card[data-id]")?.dataset.id ||
    block.querySelector(".cb-assoc-row[data-subject]")?.dataset.subject;
  if (!subject) {
    return;
  }

  const workRows = [...block.querySelectorAll(".cb-assoc-row[data-work]")];
  if (!workRows.length) {
    return;
  }

  block.dataset.liveBound = "1";
  block.dataset.liveSubject = subject;
  if (!block.dataset.subject) {
    block.dataset.subject = subject;
  }

  refresh(block, subject);

  if (messageBus?.subscribe) {
    messageBus.subscribe(`/curiobase/subject/${subject}`, (data) => {
      const reading = normalize(data);
      if (!reading?.work_id) {
        return;
      }
      paintRow(block, reading.work_id, reading);
    });
  }
}

function refresh(block, subject) {
  const works = [...block.querySelectorAll(".cb-assoc-row[data-work]")].map(
    (row) => row.dataset.work
  );
  if (!works.length) {
    return;
  }

  // Comma-separated — avoids Rack collapsing repeated `works=` query keys.
  ajax("/curiobase/readings.json", {
    data: { subject, works: works.join(",") },
  })
    .then((payload) => {
      const readings = payload?.readings || {};
      Object.keys(readings).forEach((workId) => {
        paintRow(block, workId, readings[workId], { skipReorder: true });
      });
      reorderList(block);
    })
    .catch((err) => {
      // eslint-disable-next-line no-console
      console.warn("[curiobase] readings refresh failed", err);
    });
}

function normalize(data) {
  if (!data) {
    return null;
  }
  if (typeof data === "string") {
    try {
      data = JSON.parse(data);
    } catch {
      return null;
    }
  }
  return {
    work_id: data.work_id || data.workId,
    display: data.display,
    voter_count: data.voter_count ?? data.voterCount,
    disagree: !!(data.disagree ?? data.Disagree),
  };
}

function paintRow(block, workId, reading, opts = {}) {
  const row = findWorkRow(block, workId);
  if (!row) {
    return;
  }

  const cell = row.querySelector(".cb-assoc-gravity, .cb-unrated");
  if (!cell || cell.classList.contains("cb-assoc-replies")) {
    return;
  }

  const display = reading?.display;
  if (display == null || display === "") {
    delete row.dataset.gravity;
    cell.className = "cb-assoc-meta cb-unrated";
    cell.removeAttribute("data-strength");
    cell.removeAttribute("data-disagree");
    cell.title = I18n.t("curiobase.unrated");
    cell.textContent = "—";
    if (!opts.skipReorder) {
      reorderList(block);
    }
    return;
  }

  const value = Number(display);
  const disagree = !!reading?.disagree;
  row.dataset.gravity = value.toFixed(2);
  cell.className =
    "cb-assoc-meta cb-assoc-gravity" + (disagree ? " cb-assoc-gravity--split" : "");
  cell.dataset.strength = String(Math.min(5, Math.max(1, Math.round(value))));
  if (disagree) {
    cell.dataset.disagree = "1";
    cell.title = `${I18n.t("curiobase.gravity_heading")} · ${I18n.t("curiobase.members_disagree")}`;
  } else {
    cell.removeAttribute("data-disagree");
    cell.title = I18n.t("curiobase.gravity_heading");
  }
  cell.replaceChildren();

  const dot = document.createElement("span");
  dot.className = "cb-glyph";
  dot.setAttribute("aria-hidden", "true");
  dot.textContent = "●";
  cell.append(dot, document.createTextNode(value.toFixed(1)));
  cell.classList.remove("cb-mean--pulse");
  void cell.offsetWidth;
  cell.classList.add("cb-mean--pulse");
  if (!opts.skipReorder) {
    reorderList(block);
  }
}

// Match Scores.rank_key for Works only. Discussions always follow Works in
// baked HTML (`works + discussion_rows`) and must keep that relative order —
// sorting them with unrated works by posts_count scrambles bumped_at order.
function reorderList(block) {
  const list = block.querySelector(".cb-assoc-list");
  if (!list) {
    return;
  }
  const rows = [...list.querySelectorAll(":scope > .cb-assoc-row")];
  const works = rows.filter((row) => row.dataset.work);
  const discussions = rows.filter((row) => !row.dataset.work);
  if (works.length < 2) {
    return;
  }

  const key = (row) => {
    const g = parseFloat(row.dataset.gravity);
    return [
      Number.isFinite(g) ? -g : 0,
      -(parseInt(row.dataset.recommend || "0", 10) || 0),
      -(parseInt(row.dataset.posts || "0", 10) || 0),
    ];
  };

  works.sort((a, b) => {
    const ka = key(a);
    const kb = key(b);
    for (let i = 0; i < ka.length; i++) {
      if (ka[i] !== kb[i]) {
        return ka[i] - kb[i];
      }
    }
    return 0;
  });

  const frag = document.createDocumentFragment();
  works.forEach((row) => frag.appendChild(row));
  discussions.forEach((row) => frag.appendChild(row));
  list.appendChild(frag);
}

function findWorkRow(block, workId) {
  const want = String(workId);
  return (
    [...block.querySelectorAll(".cb-assoc-row[data-work]")].find(
      (row) => row.dataset.work === want
    ) || null
  );
}
