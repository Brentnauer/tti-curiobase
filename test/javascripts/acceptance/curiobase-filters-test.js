import { click, visit } from "@ember/test-helpers";
import { test } from "qunit";
import topicFixtures from "discourse/tests/fixtures/topic";
import { acceptance } from "discourse/tests/helpers/qunit-helpers";
import { cloneJSON } from "discourse/lib/object";

// ══════════════════════════════════════════════════════════════════════════════
// THE FILTER CHIPS FILTER ON MEMBERSHIP, NOT ON MEDIUM.
// ══════════════════════════════════════════════════════════════════════════════
//
// The server bakes the top ten for `all` PLUS the top ten for each medium,
// deduped — so the list is a union. A row's medium says what it IS; it does not
// say whether it earned a place under that chip.
//
// ⚠ The first version matched `row.dataset.kind === kind`, which is a type
//   match and not a filter. Under "Book" it revealed every book in the union,
//   including books that are only present because they made the overall ten.
//   That is invisible server-side — the markup is correct, the JS reads it
//   wrong — so it can only be caught here.
//
// The fixture below is the shape the server emits: `film-top` is #1 overall AND
// #1 among films; `book-overall` made the overall ten but NOT the book ten;
// `film-only` made the film ten but not the overall ten.

function assoc() {
  return `
    <div class="curiobase-card curiobase-card--subject" data-id="majestic-12">
      <section class="cb-assoc">
        <nav class="cb-filters">
          <a class="cb-filter is-active" data-kind="all" data-count="40" data-shown="3"
             href="/tag/majestic-12/7">All 40</a>
          <a class="cb-filter" data-kind="film" data-count="12" data-shown="2"
             href="/tag/majestic-12/7?curiobase=film">Film 12</a>
          <a class="cb-filter" data-kind="book" data-count="9" data-shown="1"
             href="/tag/majestic-12/7?curiobase=book">Book 9</a>
        </nav>
        <ol class="cb-assoc-list">
          <li class="cb-assoc-row" data-kind="film" data-buckets="all film">
            <a class="cb-assoc-title" href="/t/a/1">film-top</a>
          </li>
          <li class="cb-assoc-row" data-kind="book" data-buckets="all">
            <a class="cb-assoc-title" href="/t/b/2">book-overall</a>
          </li>
          <li class="cb-assoc-row" data-kind="film" data-buckets="film">
            <a class="cb-assoc-title" href="/t/c/3">film-only</a>
          </li>
          <li class="cb-assoc-row" data-kind="book" data-buckets="book">
            <a class="cb-assoc-title" href="/t/d/4">book-only</a>
          </li>
        </ol>
        <p><a class="cb-assoc-all-link" href="/tag/majestic-12/7">All 40 topics tagged Majestic 12</a></p>
      </section>
    </div>`;
}

function topicWith(html) {
  const json = cloneJSON(topicFixtures["/t/280/1.json"]);
  json.post_stream.posts[0].cooked = html;
  return json;
}

function visibleTitles() {
  return [...document.querySelectorAll(".cb-assoc-row")]
    .filter((r) => !r.hidden)
    .map((r) => r.querySelector(".cb-assoc-title").textContent.trim());
}

acceptance("Curiobase | the association filters", function (needs) {
  needs.user();
  needs.settings({ curiobase_enabled: true });

  needs.pretender((server, helper) => {
    server.get("/t/280.json", () => helper.response(topicWith(assoc())));
  });

  test("shows everything under All, and only the overall top", async function (assert) {
    await visit("/t/-/280");
    await click('.cb-filter[data-kind="all"]');

    assert.deepEqual(
      visibleTitles(),
      ["film-top", "book-overall"],
      "All reveals the overall ranking, not every row in the union"
    );
  });

  // ⚠ THE BUG. `book-overall` is a book and must NOT appear under Book — it is
  //   in the list because it made the overall ten, not the book ten.
  test("a row's medium does not put it in that medium's bucket", async function (assert) {
    await visit("/t/-/280");
    await click('.cb-filter[data-kind="book"]');

    assert.deepEqual(visibleTitles(), ["book-only"], "only the book that earned the book bucket");
    assert.false(visibleTitles().includes("book-overall"), "not merely because it is a book");
  });

  // ⚠ THE POINT OF THE WHOLE FEATURE. A film that loses on every overall
  //   comparison still fills the film chip.
  test("a medium's bucket fills even when it wins nothing overall", async function (assert) {
    await visit("/t/-/280");
    await click('.cb-filter[data-kind="film"]');

    assert.deepEqual(visibleTitles(), ["film-top", "film-only"]);
  });

  test("marks the active chip", async function (assert) {
    await visit("/t/-/280");
    await click('.cb-filter[data-kind="film"]');

    assert.dom('.cb-filter[data-kind="film"]').hasClass("is-active");
    assert.dom('.cb-filter[data-kind="all"]').doesNotHaveClass("is-active");
  });

  // ⚠ Read from the chip, never counted from the rows. The list is a union, so
  //   a count of visible rows is not a count of anything the reader asked about
  //   — and recomputing a fact the server already knows is how the chips and
  //   the list disagreed the first time.
  test("offers the exit when the chip's total exceeds what it reveals", async function (assert) {
    await visit("/t/-/280");
    await click('.cb-filter[data-kind="book"]');

    assert.dom(".cb-assoc-all-link").isVisible();
    assert
      .dom(".cb-assoc-all-link")
      .hasAttribute("href", "/tag/majestic-12/7?curiobase=book", "and it carries the filter");
  });

  test("drops the filter from the exit when All is active", async function (assert) {
    await visit("/t/-/280");
    await click('.cb-filter[data-kind="film"]');
    await click('.cb-filter[data-kind="all"]');

    assert.dom(".cb-assoc-all-link").hasAttribute("href", "/tag/majestic-12/7");
  });

  // The chips stay real links: a crawler follows one and gets a complete,
  // different page, and so does a reader with no scripting.
  test("leaves the chips as working links", async function (assert) {
    await visit("/t/-/280");

    assert
      .dom('.cb-filter[data-kind="film"]')
      .hasAttribute("href", "/tag/majestic-12/7?curiobase=film");
  });
});
