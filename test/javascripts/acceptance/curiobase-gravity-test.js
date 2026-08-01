import { click, visit } from "@ember/test-helpers";
import { test } from "qunit";
import topicFixtures from "discourse/tests/fixtures/topic";
import { acceptance } from "discourse/tests/helpers/qunit-helpers";
import { cloneJSON } from "discourse/lib/object";

// ══════════════════════════════════════════════════════════════════════════════
// THE RATING CONTROL.
// ══════════════════════════════════════════════════════════════════════════════
//
// ⚠ THIS EXISTS BECAUSE THE ONE BUG NOTHING SERVER-SIDE COULD CATCH WAS HERE.
//
//   Every Work baked `data-work=""` after the records were converted, and this
//   file bails on it:
//
//       if (!workId || !subject) { return; }
//
//   So the control never mounted on any record on the site. The card still
//   rendered — poster, dek, badges, the score, the vote count — and the score
//   above the missing buttons was CORRECT the whole time, because the server
//   resolved the same Work by slug. 239 Ruby specs, curiobase:doctor and
//   verify.sh were all green. It took a bug report.
//
//   Everything below is a behaviour that lives only in the browser.

// The markup CardRenderer bakes. Kept verbatim rather than built by a helper:
// the whole point is to assert against what the server actually emits.
function card({ work = "deus-ex-2000", subject = "majestic-12" } = {}) {
  return `
    <div class="curiobase-card curiobase-card--work" data-id="${work}">
      <section class="cb-gravity" data-mode="fiction">
        <div class="cb-row" data-work="${work}" data-subject="${subject}">
          <div class="cb-row-name"><a href="/t/majestic-12/44">Majestic 12</a></div>
          <div class="cb-score"><span class="cb-mean">3.6</span></div>
          <div class="cb-vote" data-mount="gravity"></div>
        </div>
        <p class="cb-anchors">
          <span class="cb-anchor-step" data-step="1">1 mentions it</span> ·
          <span class="cb-anchor-step" data-step="2">2 set dressing</span> ·
          <span class="cb-anchor-step" data-step="3">3 takes it seriously</span> ·
          <span class="cb-anchor-step" data-step="4">4 builds on it</span> ·
          <span class="cb-anchor-step" data-step="5">5 cannot exist without it</span>
        </p>
      </section>
    </div>`;
}

function topicWith(html) {
  const json = cloneJSON(topicFixtures["/t/280/1.json"]);
  json.post_stream.posts[0].cooked = html;
  return json;
}

acceptance("Curiobase | the rating control", function (needs) {
  needs.user({ trust_level: 2 });
  needs.settings({
    curiobase_enabled: true,
    curiobase_member_voting_enabled: true,
    curiobase_min_trust_level: 1,
  });

  needs.pretender((server, helper) => {
    server.get("/t/280.json", () => helper.response(topicWith(card())));
    server.get("/curiobase/gravity.json", () => helper.response({ mine: null }));
    server.post("/curiobase/gravity", () =>
      helper.response({ mine: 4, display: 3.7, voter_count: 10, distribution: [0, 1, 2, 6, 1] })
    );
    server.delete("/curiobase/gravity", () =>
      helper.response({ mine: null, display: 3.5, voter_count: 9, distribution: [0, 1, 2, 5, 1] })
    );
  });

  test("mounts five marks, labelled with the anchors for the Work's mode", async function (assert) {
    await visit("/t/-/280");

    assert.dom(".cb-vote .cb-stars").exists("the control mounted");
    assert.dom(".cb-vote .cb-star").exists({ count: 5 });
    // ⚠ The wording follows data-mode. Hardcoding the fiction set would label a
    //   government report "4 — builds on it", which is not what the button does.
    assert.dom(".cb-vote").hasAttribute("data-anchor-mode", "fiction");
    assert.dom(".cb-stars").hasAttribute("role", "radiogroup");
  });

  test("casting a vote posts and paints the mark", async function (assert) {
    await visit("/t/-/280");
    await click(".cb-star[data-value='4']");

    assert.dom(".cb-vote").hasAttribute("data-mine", "4");
    assert.dom(".cb-star[data-value='4']").hasAttribute("aria-checked", "true");
  });

  // ⚠ Clicking your own mark again takes the vote back. "I no longer have a
  //   view" is a different statement from "I think it is a 3", and a scale with
  //   no way out forces the second when somebody means the first.
  test("clicking your own mark again retracts it", async function (assert) {
    await visit("/t/-/280");
    await click(".cb-star[data-value='4']");
    assert.dom(".cb-vote").hasAttribute("data-mine", "4");

    await click(".cb-star[data-value='4']");

    assert.dom(".cb-vote").doesNotHaveAttribute("data-mine", "the vote is gone");
    assert.dom(".cb-star[data-value='4']").hasAttribute("aria-checked", "false");
  });

  test("clicking a different mark changes the vote rather than retracting", async function (assert) {
    await visit("/t/-/280");
    await click(".cb-star[data-value='4']");
    await click(".cb-star[data-value='2']");

    assert.dom(".cb-vote").hasAttribute("data-mine", "4", "repainted from the server's answer");
  });

  test("the aggregate repaints in place after voting", async function (assert) {
    await visit("/t/-/280");
    assert.dom(".cb-mean").hasText("3.6");

    await click(".cb-star[data-value='4']");

    assert.dom(".cb-mean").hasText("3.7", "the number moved without a reload");
    assert.dom(".cb-dist-note").includesText("votes");
  });

  test("hover previews the anchor before you commit", async function (assert) {
    await visit("/t/-/280");
    const mark = document.querySelector(".cb-star[data-value='4']");
    mark.dispatchEvent(new MouseEvent("mouseenter", { bubbles: true }));

    assert.dom(".cb-vote-status").hasText("builds on it");
    assert.dom('.cb-anchor-step[data-step="4"]').hasClass("is-hot");
  });
});

// ══════════════════════════════════════════════════════════════════════════════
// THE GUARD THAT SILENTLY DISABLED VOTING SITE-WIDE.
// ══════════════════════════════════════════════════════════════════════════════
acceptance("Curiobase | a row the client must refuse", function (needs) {
  needs.user({ trust_level: 2 });
  needs.settings({
    curiobase_enabled: true,
    curiobase_member_voting_enabled: true,
    curiobase_min_trust_level: 1,
  });

  needs.pretender((server, helper) => {
    server.get("/t/280.json", () => helper.response(topicWith(card({ work: "" }))));
  });

  test("renders no control when data-work is empty", async function (assert) {
    await visit("/t/-/280");

    assert.dom(".cb-row").exists("the row is still there — this is the trap");
    assert.dom(".cb-mean").hasText("3.6", "and the score still looks right");
    assert.dom(".cb-star").doesNotExist("but there is nothing to click");
  });
});

acceptance("Curiobase | logged out", function (needs) {
  needs.settings({
    curiobase_enabled: true,
    curiobase_member_voting_enabled: true,
    curiobase_min_trust_level: 1,
  });

  needs.pretender((server, helper) => {
    server.get("/t/280.json", () => helper.response(topicWith(card())));
  });

  // ⚠ A control that bounces to a login page on click is worse than no control.
  test("says what the scale is and offers no buttons", async function (assert) {
    await visit("/t/-/280");

    assert.dom(".cb-vote--anon").exists();
    assert.dom(".cb-star").doesNotExist();
  });
});

acceptance("Curiobase | below the trust threshold", function (needs) {
  needs.user({ trust_level: 0 });
  needs.settings({
    curiobase_enabled: true,
    curiobase_member_voting_enabled: true,
    curiobase_min_trust_level: 2,
  });

  needs.pretender((server, helper) => {
    server.get("/t/280.json", () => helper.response(topicWith(card())));
  });

  test("explains rather than failing on click", async function (assert) {
    await visit("/t/-/280");

    assert.dom(".cb-vote--locked").exists();
    assert.dom(".cb-star").doesNotExist();
  });
});

// ⚠ With voting off the server bakes no mount point at all. Bailing in JS as
//   well means a stale bundle cannot conjure a control against a fresh page.
acceptance("Curiobase | voting switched off", function (needs) {
  needs.user({ trust_level: 2 });
  needs.settings({
    curiobase_enabled: true,
    curiobase_member_voting_enabled: false,
  });

  needs.pretender((server, helper) => {
    server.get("/t/280.json", () => helper.response(topicWith(card())));
  });

  test("mounts nothing even if a mount point is present", async function (assert) {
    await visit("/t/-/280");

    assert.dom(".cb-star").doesNotExist();
  });
});
