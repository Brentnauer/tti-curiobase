import { visit } from "@ember/test-helpers";
import { test } from "qunit";
import topicFixtures from "discourse/tests/fixtures/topic";
import { acceptance } from "discourse/tests/helpers/qunit-helpers";
import { cloneJSON } from "discourse/lib/object";

acceptance("Curiobase | subject-file tags", function (needs) {
  needs.user();
  needs.settings({ curiobase_enabled: true, tagging_enabled: true });
  needs.site({ curiobase_subject_slugs: ["causal-loop"] });

  needs.pretender((server, helper) => {
    const json = cloneJSON(topicFixtures["/t/280/1.json"]);
    json.tags = [
      { id: 11, name: "causal-loop", slug: "causal-loop" },
      { id: 12, name: "funny", slug: "funny" },
    ];
    server.get("/t/280.json", () => helper.response(json));
  });

  test("adds cb-subject-tag only for Subject-file slugs", async function (assert) {
    await visit("/t/-/280");

    assert
      .dom('.discourse-tag[data-tag-name="causal-loop"]')
      .hasClass("cb-subject-tag");
    assert
      .dom('.discourse-tag[data-tag-name="funny"]')
      .doesNotHaveClass("cb-subject-tag");
  });
});
