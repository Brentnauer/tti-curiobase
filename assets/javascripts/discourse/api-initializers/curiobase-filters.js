import { apiInitializer } from "discourse/lib/api";

// Filter the association list in place.
//
// ══════════════════════════════════════════════════════════════════════════
// THE CHIPS ARE LINKS. THIS ONLY STOPS THEM NAVIGATING.
// ══════════════════════════════════════════════════════════════════════════
//
// Every row is already in the baked HTML with a data-kind, so a crawler and a
// reader with no scripting see the complete list and the chips still work as
// links to the filtered tag page. This adds the better behaviour on top:
// staying on the file and hiding the rows that do not match.
//
// ⚠ Why not just let them navigate? Because the association list is ordered by
//   gravity and the tag page is ordered by bumped_at. Clicking "Film" used to
//   take a reader from a ranked list to an unranked one, which is the opposite
//   of what a filter is for.
//
// ⚠ Nothing here is user-specific and nothing is fetched. It is a class toggle
//   over HTML that is already on the page.

const BLOCK = ".cb-assoc";

export default apiInitializer("1.0", (api) => {
  const siteSettings = api.container.lookup("service:site-settings");
  if (!siteSettings.curiobase_enabled) {
    return;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // ON A TAG PAGE THE CHIPS ARE REAL NAVIGATION, AND THIS IS WHAT MAKES THEM
  // WORK.
  // ══════════════════════════════════════════════════════════════════════════
  //
  // ⚠ WITHOUT THIS, CLICKING A CHIP DID NOTHING AT ALL.
  //
  //   `?curiobase=film` filters correctly on the server — measured, 8 topics
  //   down to 2. But Ember owns every internal link inside the app, and the
  //   discovery route only refreshes its model for query params it has been
  //   told about. `curiobase` was not one, so the click was intercepted, the
  //   route transitioned to itself, and the list never reloaded. No error, no
  //   navigation, no change: the third silent failure of this shape.
  //
  //   `add_custom_filter` in plugin.rb made the SERVER accept the param.
  //   This is the other half — the client side of the same fact, and having
  //   only one half is exactly the split that keeps biting this codebase.
  //
  // ⚠ `refreshModel` is the point: it re-fetches the topic list. `replace`
  //   keeps the browser history clean, so filtering three times and hitting
  //   back returns to the page rather than walking back through the filters.
  api.addDiscoveryQueryParam("curiobase", { replace: true, refreshModel: true });

  api.decorateCookedElement(
    (element) => {
      element.querySelectorAll(BLOCK).forEach((block) => {
        if (block.dataset.filtersBound) {
          return;
        }
        block.dataset.filtersBound = "1";

        const chips = [...block.querySelectorAll(".cb-filter")];
        if (chips.length < 2) {
          return;
        }

        chips.forEach((chip) =>
          chip.addEventListener("click", (event) => {
            // Let modified clicks through — someone opening the filtered tag
            // page in a new tab is asking for the tag page, and should get it.
            if (event.metaKey || event.ctrlKey || event.shiftKey || event.button !== 0) {
              return;
            }
            event.preventDefault();
            apply(block, chips, chip.dataset.kind || "all");
          })
        );
      });
    },
    { onlyStream: true, id: "curiobase-filters" }
  );
});

// ══════════════════════════════════════════════════════════════════════════
// MEMBERSHIP, NOT MEDIUM.
// ══════════════════════════════════════════════════════════════════════════
//
// ⚠ THIS USED TO READ `row.dataset.kind === kind`, AND THAT IS NOT A FILTER,
//   IT IS A TYPE MATCH.
//
//   The server bakes the top ten for `all` PLUS the top ten for each medium,
//   deduped — so the list is a union and a row's medium says what it is, not
//   whether it earned a place under that chip. Matching on medium showed every
//   book in the union under "Book", including ones that are only there because
//   they ranked in the overall ten. `data-buckets` is the membership the server
//   actually computed, and it is the only honest thing to match on.
//
// ⚠ And `shown` is READ FROM THE CHIP, not counted from the rows. Counting
//   visible rows would recompute a fact the server already knows, which is how
//   the counts and the list disagreed the first time (D-029's chip that
//   saturated at the page size).
function apply(block, chips, kind) {
  chips.forEach((c) => c.classList.toggle("is-active", (c.dataset.kind || "all") === kind));

  block.querySelectorAll(".cb-assoc-row").forEach((row) => {
    const buckets = (row.dataset.buckets || "").split(" ").filter(Boolean);
    row.hidden = !buckets.includes(kind);
  });

  // ⚠ The chip count is the REAL TOTAL while the list holds the best ten, so
  //   "Book 17" reveals 10 rows. Saying so is the honest move — and the
  //   see-everything link is the answer, so point it at the kind being viewed.
  const all = block.querySelector(".cb-assoc-all-link");
  if (!all) {
    return;
  }
  const chip = chips.find((c) => (c.dataset.kind || "all") === kind);
  const total = parseInt(chip?.dataset.count || "0", 10);
  const shown = parseInt(chip?.dataset.shown || "0", 10);

  all.hidden = total <= shown;
  all.href = kind === "all" ? stripFilter(all.href) : withFilter(all.href, kind);
}

function withFilter(href, kind) {
  const url = new URL(href, window.location.origin);
  url.searchParams.set("curiobase", kind);
  return url.pathname + url.search;
}

function stripFilter(href) {
  const url = new URL(href, window.location.origin);
  url.searchParams.delete("curiobase");
  return url.pathname + url.search;
}
