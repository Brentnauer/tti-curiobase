import { apiInitializer } from "discourse/lib/api";

// Season filter + sort for series-hub episode lists.
//
// Baked HTML stays complete for crawlers / no-JS. This only hides rows and
// reorders the ol — same chip vocabulary as Subject association filters.

const ROOT = ".cb-episodes";

export default apiInitializer("1.0", (api) => {
  const siteSettings = api.container.lookup("service:site-settings");
  if (!siteSettings.curiobase_enabled) {
    return;
  }

  api.decorateCookedElement(
    (element) => {
      element.querySelectorAll(ROOT).forEach(bindEpisodes);
    },
    { onlyStream: true, id: "curiobase-episodes" }
  );
});

function bindEpisodes(block) {
  if (block.dataset.episodesBound) {
    return;
  }
  block.dataset.episodesBound = "1";
  block.dataset.season = "all";
  block.dataset.sort = "air";

  block.querySelectorAll(".cb-episodes-seasons .cb-filter").forEach((chip) => {
    chip.addEventListener("click", (event) => {
      event.preventDefault();
      block.dataset.season = chip.dataset.season || "all";
      block
        .querySelectorAll(".cb-episodes-seasons .cb-filter")
        .forEach((c) => c.classList.toggle("is-active", c === chip));
      apply(block);
    });
  });

  block.querySelectorAll(".cb-episodes-sort .cb-filter").forEach((chip) => {
    chip.addEventListener("click", (event) => {
      event.preventDefault();
      block.dataset.sort = chip.dataset.sort || "air";
      block
        .querySelectorAll(".cb-episodes-sort .cb-filter")
        .forEach((c) => c.classList.toggle("is-active", c === chip));
      apply(block);
    });
  });
}

function apply(block) {
  const list = block.querySelector(".cb-episodes-list");
  if (!list) {
    return;
  }

  const season = block.dataset.season || "all";
  const sort = block.dataset.sort || "air";
  const rows = [...list.querySelectorAll(":scope > .cb-episodes-row")];

  rows.forEach((row) => {
    const match = season === "all" || row.dataset.season === season;
    if (match) {
      row.removeAttribute("hidden");
    } else {
      row.hidden = true;
    }
  });

  const visible = rows.filter((row) => !row.hidden);
  visible.sort((a, b) => {
    if (sort === "recommend") {
      const ra = parseInt(a.dataset.recommend || "0", 10) || 0;
      const rb = parseInt(b.dataset.recommend || "0", 10) || 0;
      if (rb !== ra) {
        return rb - ra;
      }
    }
    const sa = parseInt(a.dataset.season || "0", 10) || 0;
    const sb = parseInt(b.dataset.season || "0", 10) || 0;
    if (sa !== sb) {
      return sa - sb;
    }
    const ea = parseInt(a.dataset.episode || "0", 10) || 0;
    const eb = parseInt(b.dataset.episode || "0", 10) || 0;
    if (ea !== eb) {
      return ea - eb;
    }
    return (a.dataset.title || "").localeCompare(b.dataset.title || "");
  });

  const frag = document.createDocumentFragment();
  visible.forEach((row) => frag.appendChild(row));
  // Keep hidden rows at the end so they stay in the list for season switches.
  rows.filter((row) => row.hidden).forEach((row) => frag.appendChild(row));
  list.appendChild(frag);
}
