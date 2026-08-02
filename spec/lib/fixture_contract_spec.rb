# frozen_string_literal: true

require "rails_helper"

# ⚠ THE FIXTURES ARE THE WORDPRESS CONTRACT.
#
#   Whatever fixtures/ returns is what /wp-json/tti/v1/ must return. These specs
#   are the only thing keeping the two honest before WordPress exists, and the
#   only thing that will catch WordPress drifting away from them afterwards.
RSpec.describe "Curiobase fixtures" do
  root = File.expand_path("../../fixtures", __dir__)

  # ⚠ fixtures/gravity.json IS GONE. It held invented distributions so the card
  #   had numbers to draw before real votes existed, and the spec that used to
  #   live here checked that its stated mean matched its stated distribution —
  #   a real bug, caught, in scaffolding that no longer exists.
  #
  #   Assessments now live on each Work as a `gravity` array, the same shape ACF
  #   returns. What replaces that spec is below.
  describe "the institute's assessments" do
    it "puts them on the work, in the shape ACF returns" do
      Dir[File.join(root, "works", "*.json")].each do |f|
        rows = JSON.parse(File.read(f))["gravity"]
        next if rows.nil?
        label = File.basename(f)

        expect(rows).to be_an(Array), "#{label}: gravity must be an array of rows"
        rows.each do |row|
          expect(row["subject"]).to be_present, "#{label}: a gravity row with no subject"
          expect(1..5).to cover(row["value"].to_i),
                          "#{label}: #{row["subject"]} is #{row["value"].inspect}, and the scale is 1–5"
        end
      end
    end

    # A pairing is (work, subject). Two rows for the same subject means two
    # assessments of the same thing, and whichever one `find` reaches first wins
    # silently — the reader has no way to know a second opinion was discarded.
    it "assesses each pairing exactly once" do
      Dir[File.join(root, "works", "*.json")].each do |f|
        slugs = Array(JSON.parse(File.read(f))["gravity"]).map { |r| r["subject"] }
        dupes = slugs.tally.select { |_, n| n > 1 }.keys
        expect(dupes).to be_empty, "#{File.basename(f)}: assessed twice — #{dupes.join(", ")}"
      end
    end

    # An assessment against a subject that does not exist can never render: the
    # row is only drawn for subjects the topic is tagged with, and the tag
    # vocabulary is the subject list. It would sit in WordPress looking done.
    it "only assesses subjects that exist" do
      known = Dir[File.join(root, "subjects", "*.json")].map { |f| File.basename(f, ".json") }
      Dir[File.join(root, "works", "*.json")].each do |f|
        Array(JSON.parse(File.read(f))["gravity"]).each do |row|
          expect(known).to include(row["subject"]),
                           "#{File.basename(f)}: no such subject as #{row["subject"].inspect}"
        end
      end
    end

    # Not a rule, a canary. The fixtures exist to exercise the renderer, and the
    # unassessed state is a state the renderer has to get right — it is what
    # most of the catalogue will look like for a long time.
    it "leaves at least one work unassessed, so the empty state is exercised" do
      all = Dir[File.join(root, "works", "*.json")]
      unassessed = all.reject { |f| JSON.parse(File.read(f))["gravity"].present? }
      expect(unassessed).not_to be_empty,
                                "every work fixture is assessed — nothing renders 'not yet assessed'"
    end
  end

  # ⚠ ADDED AFTER WORDPRESS CAUGHT WHAT THIS FILE DID NOT.
  #
  #   Seeding the live site rejected three of fourteen records: two deks over
  #   the 200 cap (204 and 206 characters) and a `period` of "1940s", which is
  #   not on the scale at all — everything before 1950 collapses into
  #   `pre-1950`.
  #
  #   All three were findable here from the start. A contract spec that only
  #   checks the fields it remembers to check is a contract spec that lets the
  #   next system be the validator.
  describe "the facet vocabularies" do
    FACETS = {
      "kind" => %w[idea incident claim person place object org document],
      "domain" => %w[time reality consciousness contact phenomena hidden-history
                     esoterica science control futures],
      "status" => %w[open contested explained debunked hoax-admitted unfalsifiable],
    }.freeze

    PERIODS = %w[ancient pre-1950 1950s 1960s 1970s 1980s 1990s 2000s 2010s 2020s].freeze
    EVIDENCE = %w[primary-source firsthand-account secondhand-account
                  physical-trace documentary-record no-evidence].freeze
    MEDIA = %w[film series book game video document].freeze
    MODES = %w[fiction nonfiction].freeze

    # The dek IS the meta description. Google truncates display around 155, so
    # an over-long one is guaranteed to cut mid-clause.
    it "keeps every dek inside 200 characters" do
      Dir[File.join(root, "**", "*.json")].each do |f|
        dek = JSON.parse(File.read(f))["dek"]
        next if dek.nil?
        expect(dek.length).to be <= 200, "#{File.basename(f)}: dek is #{dek.length} characters"
      end
    end

    it "uses only real subject facet values" do
      Dir[File.join(root, "subjects", "*.json")].each do |f|
        s = JSON.parse(File.read(f))
        label = File.basename(f)

        FACETS.each do |field, allowed|
          v = s[field]
          next if v.blank?
          expect(allowed).to include(v), "#{label}: #{field} #{v.inspect} is not a real value"
        end

        Array(s["period"]).each do |p|
          expect(PERIODS).to include(p), "#{label}: period #{p.inspect} is not on the scale"
        end
        Array(s["evidence"]).each do |e|
          expect(EVIDENCE).to include(e), "#{label}: evidence #{e.inspect} is not a real value"
        end
      end
    end

    it "uses only real work facet values" do
      Dir[File.join(root, "works", "*.json")].each do |f|
        w = JSON.parse(File.read(f))
        expect(MEDIA).to include(w["medium"]), "#{File.basename(f)}: medium #{w["medium"].inspect}"
        expect(MODES).to include(w["mode"]) if w["mode"].present?
      end
    end

    # Every key here needs a link builder in Curiobase::Identifiers, or the
    # record renders no external link at all — silently, because a key with no
    # builder looks identical to a record that has none.
    #
    # ⚠ It now costs the record its `sameAs` too: the same registry is what tells
    #   Google which entity this is.
    it "uses only external IDs the renderer can build a link for" do
      Dir[File.join(root, "works", "*.json")].each do |f|
        (JSON.parse(File.read(f))["external"] || {}).each_key do |k|
          # ⚠ `asin` is deliberately not in the registry — an Amazon listing is
          #   where to buy the thing, not what the thing is. See Identifiers.
          next if k == "asin"
          expect(Curiobase::Identifiers::REGISTRY).to have_key(k),
                                                      "#{File.basename(f)}: no link builder for #{k.inspect}"
        end
      end
    end
  end

  describe "works and subjects" do
    it "gives every work the fields the card and JSON-LD read" do
      Dir[File.join(root, "works", "*.json")].each do |f|
        w = JSON.parse(File.read(f))
        expect(w["id"]).to be_present, "#{f}: no id"
        expect(w["title"]).to be_present, "#{f}: no title"
        # The dek leads the post and therefore wins the search snippet. A record
        # without one produces "Medium Film Year 2004" as its Google result.
        expect(w["dek"]).to be_present, "#{f}: no dek — the search snippet needs a sentence"
        expect(Curiobase::JsonLd::MEDIUM).to have_key(w["medium"]),
                                             "#{f}: medium #{w["medium"].inspect} has no schema.org mapping"
      end
    end

    it "gives every subject a slug matching its filename, because the slug is the tag name" do
      Dir[File.join(root, "subjects", "*.json")].each do |f|
        s = JSON.parse(File.read(f))
        expect(s["slug"]).to eq(File.basename(f, ".json")),
                             "#{f}: slug must equal the filename — it is also the Discourse tag"
        expect(s["dek"]).to be_present, "#{f}: no dek"
        expect(Curiobase::JsonLd::KIND).to have_key(s["kind"]),
                                           "#{f}: kind #{s["kind"].inspect} has no schema.org mapping"
      end
    end

    it "keeps subject edges on the closed verb set with real targets" do
      known = Dir[File.join(root, "subjects", "*.json")].map { |f| File.basename(f, ".json") }
      Dir[File.join(root, "subjects", "*.json")].each do |f|
        label = File.basename(f)
        Array(JSON.parse(File.read(f))["refs"]).each do |edge|
          expect(edge).to be_a(Hash), "#{label}: refs entries must be hashes"
          verb = edge["verb"].presence || Curiobase::PostRecord::RELATED
          expect(Curiobase::PostRecord::EDGE_VERBS).to include(verb),
                                                       "#{label}: unknown edge verb #{verb.inspect}"
          expect(edge["slug"]).to be_present, "#{label}: edge without slug"
          expect(known).to include(edge["slug"]),
                           "#{label}: edge → #{edge["slug"].inspect} has no subject fixture"
        end
      end
    end
  end
end
