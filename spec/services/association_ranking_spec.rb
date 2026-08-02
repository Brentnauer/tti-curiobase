# frozen_string_literal: true

require "rails_helper"

# ══════════════════════════════════════════════════════════════════════════════
# RANKING A RECENCY WINDOW IS NOT A RANKING.
# ══════════════════════════════════════════════════════════════════════════════
#
# The association list used to load `ORDER BY bumped_at DESC LIMIT 75` and sort
# by gravity afterwards, in Ruby. So the window decided what was eligible and
# the ranking only sorted the survivors.
#
# Measured on a synthetic subject with 100 works and 60 recently-bumped threads:
# **15 works survived, 2–3 per medium.** Filtering to books gave three rows out
# of seventeen. A five-star film nobody had replied to since 2019 was not ranked
# low — it never entered the list at all.
RSpec.describe "Curiobase · association ranking" do
  fab!(:admin) { Fabricate(:admin) }
  fab!(:voter) { Fabricate(:user, trust_level: TrustLevel[4]) }
  fab!(:tag) { Fabricate(:tag, name: "majestic-12") }

  before do
    SiteSetting.curiobase_enabled = true
    SiteSetting.curiobase_member_voting_enabled = true
    claim_subject_file!("majestic-12")
  end

  # A Work, baked (so `curiobase_kind` exists), optionally aged and rated.
  def work!(slug, medium:, gravity: nil, days_old: 0)
    topic = Fabricate(:topic, title: "The record called #{slug} here", user: admin, tags: [tag])
    post = Fabricate(:post, topic: topic, user: admin, post_number: 1, raw: <<~RAW)
      ```curiobase
      type: work
      slug: #{slug}
      medium: #{medium}
      dek: A treatment of the committee, filed under #{slug} for this test.
      ```
    RAW
    Curiobase.rebake_now!(post)
    topic.update_columns(bumped_at: days_old.days.ago)
    Curiobase::VoteStore.cast(work_id: slug, subject: "majestic-12", user_id: voter.id, value: gravity) if gravity
    topic
  end

  def thread!(i, hours_old: 0)
    topic = Fabricate(:topic, title: "An ordinary thread number #{i} here", user: admin, tags: [tag])
    Fabricate(:post, topic: topic, user: admin, post_number: 1, raw: "Words about the committee.")
    topic.update_columns(bumped_at: hours_old.hours.ago)
    topic
  end

  def assoc = Curiobase::Associations.new("majestic-12")

  # ── the window ──────────────────────────────────────────────────────────────
  describe "the window" do
    # ⚠ THE DEFECT, in miniature. The best Work is the oldest, and every thread
    #   is newer than every Work — which is the normal shape on a 28-year forum,
    #   where threads get replies and records mostly do not.
    it "does not let recent threads evict old Works" do
      work!("the-best-one", medium: "film", gravity: 5, days_old: 900)
      work!("a-weaker-one", medium: "film", gravity: 2, days_old: 800)
      12.times { |i| thread!(i, hours_old: i) }

      titles = assoc.rows.select { |r| r.kind == "work" }.map(&:title)
      expect(titles.first).to include("the-best-one")
      expect(titles.size).to eq(2)
    end

    # ⚠ A discussion is the ABSENCE of a `curiobase_kind`, not "a topic that is
    #   not one of the Works I happened to load". The first version of this fix
    #   subtracted the loaded Works and the Subject's own file — tagged with its
    #   own slug — appeared in its own list as a discussion. A record does not
    #   engage itself.
    it "never lists another record as a discussion" do
      work!("a-work", medium: "book", gravity: 4)
      subject_topic = Fabricate(:topic, title: "Majestic 12, the committee file", user: admin, tags: [tag])
      sp = Fabricate(:post, topic: subject_topic, user: admin, post_number: 1, raw: <<~RAW)
        ```curiobase
        type: subject
        slug: majestic-12
        kind: org
        domain: hidden-history
        dek: A committee of twelve said to have been convened in 1947.
        ```
      RAW
      Curiobase.rebake_now!(sp)

      expect(assoc.rows.map(&:title)).not_to include(subject_topic.title)
      expect(assoc.rows.select { |r| r.kind == "discussion" }).to be_empty
    end

    # Discussions rank by `like_count` then `bumped_at` — indexed SQL sorts —
    # so they are ordered and limited in SQL rather than loaded and sliced.
    it "takes the most-liked threads, in SQL" do
      stub_const(Curiobase::Associations, :PER_BUCKET, 3) do
        5.times do |i|
          topic = thread!(i, hours_old: i)
          topic.update_columns(like_count: i)
        end
        rows = assoc.rows.select { |r| r.kind == "discussion" }

        expect(rows.size).to eq(3)
        expect(rows.map(&:title)).to eq(
          [
            "An ordinary thread number 4 here",
            "An ordinary thread number 3 here",
            "An ordinary thread number 2 here",
          ],
        )
        expect(rows.map(&:buckets).uniq).to eq([["discussion"]])
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # EACH BUCKET IS RANKED SEPARATELY, AND THE CARD HOLDS THE UNION.
  # ══════════════════════════════════════════════════════════════════════════
  describe "top N per bucket" do
    before do
      # Six books and six films, books scored higher across the board — so the
      # overall top is all books and the films only exist inside their own
      # bucket. That is the case the old code got wrong.
      6.times { |i| work!("book-#{i}", medium: "book", gravity: 5 - (i % 2)) }
      6.times { |i| work!("film-#{i}", medium: "film", gravity: 2) }
    end

    it "fills each medium's bucket even when it wins nothing overall" do
      stub_const(Curiobase::Associations, :PER_BUCKET, 3) do
        a = assoc
        expect(a.shown_counts["works"]).to eq(3)
        expect(a.shown_counts["book"]).to eq(3)
        # ⚠ The point. Films score below every book, so under the old shape a
        #   reader clicking "Film" saw whatever films happened to survive — here,
        #   none at all.
        expect(a.shown_counts["film"]).to eq(3)
      end
    end

    it "renders the union, deduped" do
      stub_const(Curiobase::Associations, :PER_BUCKET, 3) do
        works = assoc.rows.select { |r| r.kind == "work" }
        # 3 overall (all books) + 3 books (the same three) + 3 films = 6 rows.
        expect(works.size).to eq(6)
        expect(works.map(&:title).uniq.size).to eq(6)
      end
    end

    # ⚠ MEMBERSHIP, NOT MEDIUM. A row can be #4 overall and #1 among films. The
    #   client filters on `data-buckets` for exactly this reason: matching on
    #   medium would reveal rows that never earned a place under that chip.
    it "labels each row with the buckets it earned, not with its medium" do
      stub_const(Curiobase::Associations, :PER_BUCKET, 3) do
        works = assoc.rows.select { |r| r.kind == "work" }
        top = works.first
        films = works.select { |r| r.medium == "film" }

        expect(top.buckets).to include("works")
        expect(top.buckets).to include("all")
        expect(top.buckets).to include("book")
        expect(films.map(&:buckets).flatten.uniq.sort).to eq(["film"])
      end
    end

    it "orders the union by the overall ranking, not bucket by bucket" do
      stub_const(Curiobase::Associations, :PER_BUCKET, 3) do
        works = assoc.rows.select { |r| r.kind == "work" }
        scores = works.map { |r| r.gravity&.display.to_f }

        expect(scores).to eq(scores.sort.reverse)
      end
    end

    it "bakes the buckets onto the row so a filter needs no request" do
      subject_topic = Fabricate(:topic, title: "Majestic 12, the committee file", user: admin, tags: [tag])
      sp = Fabricate(:post, topic: subject_topic, user: admin, post_number: 1, raw: <<~RAW)
        ```curiobase
        type: subject
        slug: majestic-12
        kind: org
        domain: hidden-history
        dek: A committee of twelve said to have been convened in 1947.
        ```
      RAW
      Curiobase.rebake_now!(sp)
      frag = Nokogiri::HTML5.fragment(sp.reload.cooked)

      rows = frag.css(".cb-assoc-row")
      expect(rows).not_to be_empty
      expect(rows.map { |r| r["data-buckets"] }).to all(be_present)

      # The chip carries the true total AND what clicking it reveals — the gap
      # between them is what the "view all" exit is for.
      chip = frag.at_css('.cb-filter[data-kind="film"]')
      expect(chip["data-count"]).to eq("6")
      expect(chip["data-shown"]).to eq("6")
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # ONE QUERY FOR EVERY PAIRING'S VOTES.
  # ══════════════════════════════════════════════════════════════════════════
  #
  # ⚠ Profiled at forty works: `plugin_store_rows` was **40 of the association
  #   list's 48 queries** — the one cost still growing linearly with the list,
  #   on the surface about to render ten times more rows. It did not show at
  #   seven rows, which is why it survived the batching pass in D-045.
  describe "the vote read" do
    it "costs one query however many Works there are" do
      12.times { |i| work!("w-#{i}", medium: "film", gravity: 3) }

      n = 0
      cb = ->(*args) { n += 1 if args.last[:sql].to_s.include?("plugin_store_rows") }
      ActiveSupport::Notifications.subscribed(cb, "sql.active_record") { assoc.rows }

      expect(n).to eq(1)
    end

    it "gives the batch and the single read the same answer" do
      work!("one", medium: "film", gravity: 4)
      work!("two", medium: "film", gravity: 2)

      batch = Curiobase::Gravity.for_works(%w[one two], "majestic-12")
      expect(batch["one"].display).to eq(Curiobase::Gravity.for({ "slug" => "one" }, "majestic-12").display)
      expect(batch["two"].display).to eq(Curiobase::Gravity.for({ "slug" => "two" }, "majestic-12").display)
    end

    it "returns a key per pairing when voting is off, rather than an empty hash" do
      SiteSetting.curiobase_member_voting_enabled = false

      expect(Curiobase::Gravity.for_works(%w[one two], "majestic-12")).to eq("one" => nil, "two" => nil)
    end
  end
end
