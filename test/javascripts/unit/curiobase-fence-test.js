import {
  parseFence,
  subjectStub,
  workStub,
  FENCE_RE,
} from "discourse/plugins/tti-curiobase/discourse/lib/curiobase-fence";

QUnit.module("tti-curiobase | fence helpers");

QUnit.test("parseFence reads typed edges and dek", function (assert) {
  const fields = parseFence(`intro

\`\`\`curiobase
type: subject
slug: john-titor
kind: person
domain: time
dek: A soldier from 2036.
explains: art-bell-faxes, titor-irc-logs
refs: causal-loop
\`\`\`

body`);

  assert.strictEqual(fields.type, "subject");
  assert.strictEqual(fields.slug, "john-titor");
  assert.strictEqual(fields.dek, "A soldier from 2036.");
  assert.deepEqual(
    fields.refs.map((r) => `${r.verb}:${r.slug}`),
    [
      "explains:art-bell-faxes",
      "explains:titor-irc-logs",
      "related:causal-loop",
    ]
  );
});

QUnit.test("stubs are valid fence shells", function (assert) {
  assert.true(FENCE_RE.test(subjectStub()));
  assert.true(FENCE_RE.test(workStub()));
  assert.true(subjectStub().includes("type: subject"));
  assert.true(workStub().includes("type: work"));
});
