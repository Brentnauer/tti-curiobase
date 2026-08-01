# frozen_string_literal: true

require "rails_helper"

# ══════════════════════════════════════════════════════════════════════════════
# THE CONVERSION THAT REPORTED SUCCESS AND THREW DATA AWAY.
# ══════════════════════════════════════════════════════════════════════════════
#
# `curiobase:convert` rewrote 34 records out of WordPress and into their own
# posts. On six of them it silently discarded a field, and on all 34 it dropped
# the title. Nothing errored, the validator passed, `doctor` was clean and
# `verify.sh` was green — because every check inspected the block that had been
# WRITTEN, and a field the writer could not express simply is not in it.
#
# Each example here is one of those losses.
RSpec.describe "record conversion loses nothing" do
  # ── the title ───────────────────────────────────────────────────────────────
  #
  # Symptom: every association row rendered a link with no text. The dek still
  # rendered underneath, so the row looked populated — a paragraph, a score, a
  # vote count, and nothing to click. Failing to a plausible-looking row is why
  # it survived a full QA pass and needed a screenshot to find.
  describe "the title" do
    # ⚠ Long enough to clear Discourse's own minimum title length. The real
    #   record is "Deus Ex (2000)"; the suffix is a test-environment artefact.
    TITLE = "Deus Ex (2000) — Ion Storm"

    fab!(:topic) { Fabricate(:topic, title: TITLE) }

    def author!(body)
      post = Fabricate(:post, topic: topic, post_number: 1, raw: "```curiobase\n#{body}\n```")
      Curiobase::RecordTopic.remember(topic, "deus-ex-2000")
      post
    end

    it "comes from the topic when the block does not carry one" do
      author!("type: work\nslug: deus-ex-2000\nmedium: game\ndek: Majestic 12 is the antagonist.")

      expect(Curiobase::Source.work("deus-ex-2000")["title"]).to eq(TITLE)
    end

    # The escape hatch: a record whose topic title carries forum noise.
    it "lets the block override the topic" do
      author!("type: work\nslug: deus-ex-2000\nmedium: game\ntitle: Deus Ex\ndek: x")

      expect(Curiobase::Source.work("deus-ex-2000")["title"]).to eq("Deus Ex")
    end

    it "never hands a renderer a record without one" do
      author!("type: work\nslug: deus-ex-2000\nmedium: game\ndek: x")

      expect(Curiobase::Source.work("deus-ex-2000")["title"]).to be_present
    end
  end

  # ── the vote target ─────────────────────────────────────────────────────────
  #
  # `data-work` is the attribute the rating control posts with, and the client
  # bails on an empty one — `if (!workId || !subject) return`. So a Work with no
  # id baked `data-work=""`, the control never mounted, and the card rendered
  # complete: poster, dek, badges, the score, the vote count, no buttons.
  #
  # ⚠ Two places derived one identity and only one of them was updated. Gravity
  #   read `slug || id`; CardRenderer read `id` alone. The score above the
  #   missing control was correct the whole time, resolved by slug.
  describe "how a Work is named to the vote store" do
    it "prefers the slug, because a post-authored record has no id" do
      expect(Curiobase::Gravity.work_id("slug" => "deus-ex-2000")).to eq("deus-ex-2000")
    end

    it "still accepts a legacy record that only has an id" do
      expect(Curiobase::Gravity.work_id("id" => "123")).to eq("123")
    end

    it "prefers the slug when a record carries both, since ids are environment-specific" do
      expect(Curiobase::Gravity.work_id("slug" => "primer-2004", "id" => "7223")).to eq("primer-2004")
    end

    it "is nil rather than an empty string when there is nothing to name" do
      expect(Curiobase::Gravity.work_id({})).to be_nil
    end
  end

  # ── the facts ───────────────────────────────────────────────────────────────
  #
  # `FACTS` was a hand-kept flat list of eight keys. That is a PARTIAL union of
  # the eight kinds — complete for `incident` and complete for nothing else — so
  # John Titor lost `nationality` and `known_for`, Skinwalker Ranch lost
  # `country`, Excalibur lost `whereabouts`, Majestic 12 lost `jurisdiction`.
  describe "the fact vocabulary" do
    it "covers every kind SCHEMA.md defines" do
      expect(Curiobase::PostRecord::FACTS_BY_KIND.keys).to match_array(
        %w[idea incident claim person place object org document],
      )
    end

    it "is the union of the per-kind sets, so no kind can be partially covered" do
      Curiobase::PostRecord::FACTS_BY_KIND.each do |kind, keys|
        next if keys.empty?
        expect(Curiobase::PostRecord::FACTS).to include(*keys), "#{kind} has facts the parser cannot read"
      end
    end

    # The round trip is the real check: a record with every fact its kind takes
    # must survive being written and read back.
    it "round-trips every kind's facts through write and parse" do
      Curiobase::PostRecord::FACTS_BY_KIND.each do |kind, keys|
        next if keys.empty?

        record = {
          "type" => "subject", "slug" => "x-#{kind}", "kind" => kind,
          "domain" => "time", "dek" => "A sentence.",
          "facts" => keys.index_with { |k| "value-for-#{k}" },
        }

        parsed = Curiobase::PostRecord.parse(Curiobase::RecordWriter.fence(record))
        expect(parsed).to be_valid, "#{kind}: #{parsed.unknown.inspect}"
        expect(Curiobase::PostRecord.to_record(parsed)["facts"]).to eq(record["facts"]), "#{kind} lost facts"
      end
    end
  end

  # ── the loss report ─────────────────────────────────────────────────────────
  describe "RecordWriter.losses" do
    def subject_record(extra = {})
      { "type" => "subject", "slug" => "x", "kind" => "org", "domain" => "time", "dek" => "y" }.merge(extra)
    end

    it "is silent on a record the block can express completely" do
      expect(Curiobase::RecordWriter.losses(subject_record("facts" => { "founded" => "1947" }))).to be_empty
    end

    # ⚠ The first version of this method reported `external` and `facts` as lost
    #   on every record, because it looked for the CONTAINER key in ORDER rather
    #   than the member keys. Same blind spot it exists to catch, one level up.
    it "does not mistake a container for a loss" do
      record = subject_record.merge(
        "external" => { "wikipedia" => "Majestic_12" },
        "facts" => { "founded" => "1947", "jurisdiction" => "United States" },
      )

      expect(Curiobase::RecordWriter.losses(record)).to be_empty
    end

    # ⚠ And the mirror: an unknown key INSIDE a container is invisible to a
    #   sweep over top-level keys, because the container itself is known.
    it "finds an unknown key inside a container" do
      record = subject_record.merge("facts" => { "founded" => "1947", "invented" => "yes" })

      expect(Curiobase::RecordWriter.losses(record)).to eq(["facts.invented"])
    end

    it "ignores a field Discourse owns rather than reporting it lost" do
      record = subject_record.merge("title" => "M12", "gravity" => [{ "value" => 5 }], "id" => "44")

      expect(Curiobase::RecordWriter.losses(record)).to be_empty
    end

    it "reports a field with no home anywhere" do
      expect(Curiobase::RecordWriter.losses(subject_record("mystery_field" => "?"))).to eq(["mystery_field"])
    end

    it "is not fooled by an empty value" do
      expect(Curiobase::RecordWriter.losses(subject_record("mystery_field" => ""))).to be_empty
    end
  end

  # ── prose and full_text ─────────────────────────────────────────────────────
  #
  # Too long for a key-value line, so they go in the post body. The Philadelphia
  # Experiment is a `claim`, and its prose — the assertion, what supports it,
  # what contradicts it — IS the record. Conversion dropped all three.
  describe "RecordWriter.body_additions" do
    let(:record) do
      {
        "prose" => [
          { "label" => "The claim", "body" => "That the USS Eldridge was rendered invisible." },
          { "label" => "Contradicts", "body" => "The deck log places her elsewhere." },
        ],
        "full_text" => "Folio 1r, opening lines.",
      }
    end

    it "moves prose into the body as headed markdown, in order" do
      out = Curiobase::RecordWriter.body_additions(record, "")

      expect(out[0]).to start_with("### The claim")
      expect(out[1]).to start_with("### Contradicts")
    end

    it "puts a recovered text last and collapsed, so it cannot take the snippet" do
      expect(Curiobase::RecordWriter.body_additions(record, "").last).to start_with("[details=")
    end

    # Repair has to be safe to run twice.
    it "adds nothing that is already in the body" do
      body = Curiobase::RecordWriter.body_additions(record, "").join("\n\n")

      expect(Curiobase::RecordWriter.body_additions(record, body)).to be_empty
    end

    # ⚠ Matched on the heading, never the text. Matching on the text would
    #   re-append the whole section the moment an editor changed a word.
    it "leaves an edited section alone" do
      body = "### The claim\n\nRewritten by a member.\n\n### Contradicts\n\nAlso rewritten."
      out = Curiobase::RecordWriter.body_additions(record.except("full_text"), body)

      expect(out).to be_empty
    end
  end
end
