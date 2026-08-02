# frozen_string_literal: true

require "rails_helper"

# ══════════════════════════════════════════════════════════════════════════════
# THE PATHS THAT FAIL QUIETLY.
# ══════════════════════════════════════════════════════════════════════════════
#
# Every serious defect in this project has been silent: a wrap that rendered
# nothing, a CSS rule that hid 23 assessments, a renamed method that killed
# JSON-LD on 26 Works behind one log line, a card with no vote buttons that
# looked finished.
#
# Every `rescue` below is correct — a broken card must not take a page down.
# But an untested rescue is a defect waiting to be invisible, so each one here
# asserts two things: the page survives, AND the failure is recorded.
RSpec.describe "silent failure paths" do
  fab!(:admin) { Fabricate(:admin) }

  before { SiteSetting.curiobase_enabled = true }

  def record_topic!(title, body)
    topic = Fabricate(:topic, title: title, user: admin)
    post = Fabricate(:post, topic: topic, user: admin, post_number: 1, raw: "```curiobase\n#{body}\n```")
    Curiobase.rebake_now!(post)
    [topic, post.reload]
  end

  # ══════════════════════════════════════════════════════════════════════════
  # THE BLANK TITLE, SEVENTH INSTANCE.
  # ══════════════════════════════════════════════════════════════════════════
  #
  # `Source.from_post` applied the topic title AFTER building the record, so
  # anything resolved through Source was fine — but `CardRenderer` builds its
  # record straight from the parsed block and never touches Source. On a
  # record's own topic page the title was still nil, and the symptom was a link
  # reading "Read more about" with nothing after it.
  #
  # The title is applied inside `to_record` now, where the record is MADE, so
  # there is no path that produces one without a title.
  describe "the title, wherever a record is built" do
    it "comes from the topic when PostRecord builds it directly" do
      topic = Fabricate(:topic, title: "The Voynich Manuscript, unread since 1912")
      parsed = Curiobase::PostRecord.parse(<<~RAW)
        ```curiobase
        type: subject
        slug: voynich-manuscript
        kind: document
        domain: esoterica
        dek: A 15th-century codex in an unknown script.
        ```
      RAW

      record = Curiobase::PostRecord.to_record(parsed, topic: topic)
      expect(record["title"]).to eq(topic.title)
    end

    it "is left alone when the block names one" do
      topic = Fabricate(:topic, title: "Voynich — megathread, do not post here")
      parsed = Curiobase::PostRecord.parse(<<~RAW)
        ```curiobase
        type: subject
        slug: voynich-manuscript
        kind: document
        domain: esoterica
        title: The Voynich Manuscript
        dek: A 15th-century codex.
        ```
      RAW

      expect(Curiobase::PostRecord.to_record(parsed, topic: topic)["title"])
        .to eq("The Voynich Manuscript")
    end

    it "renders the landing link with the title in it, not a dangling preposition" do
      topic = Fabricate(:topic, title: "The Voynich Manuscript, unread since 1912", user: admin)
      post = Fabricate(:post, topic: topic, user: admin, post_number: 1, raw: <<~RAW)
        ```curiobase
        type: subject
        slug: voynich-manuscript
        kind: document
        domain: esoterica
        landing_url: https://example.org/voynich
        dek: A 15th-century codex in an unknown script.
        ```
      RAW
      Curiobase.rebake_now!(post)

      link = Nokogiri::HTML5.fragment(post.reload.cooked).at_css(".cb-landing a")
      expect(link.text).to eq("Read more about #{topic.title}")
    end
  end

  # ── Source.from_post ────────────────────────────────────────────────────────
  describe "Source.from_post" do
    it "returns nil and logs rather than raising when the record cannot be read" do
      record_topic!("Majestic 12, the committee itself",
                    "type: subject\nslug: majestic-12\nkind: org\ndomain: hidden-history\ndek: A committee.")
      allow(Curiobase::PostRecord).to receive(:parse).and_raise(ArgumentError, "boom")
      expect(Rails.logger).to receive(:warn).with(/post-authored record majestic-12 unreadable: ArgumentError/)

      expect(Curiobase::Source.from_post("majestic-12", type: :subject)).to be_nil
    end

    # ⚠ And the fallback is the point: an unreadable POST must not take out a
    #   record that still resolves from a fixture. Source.subject stays useful
    #   even when from_post has just failed.
    it "falls through to the fixture rather than losing the record entirely" do
      record_topic!("Majestic 12, the committee itself",
                    "type: subject\nslug: majestic-12\nkind: org\ndomain: hidden-history\ndek: A committee.")
      allow(Curiobase::PostRecord).to receive(:parse).and_raise(ArgumentError, "boom")
      allow(Rails.logger).to receive(:warn)

      expect(Curiobase::Source.subject("majestic-12")&.dig("slug")).to eq("majestic-12")
    end

    it "is silent and cheap for a slug nobody has written" do
      expect(Curiobase::Source.subject("no-such-subject-anywhere")).to be_nil
    end
  end

  # ── Gravity#reading ─────────────────────────────────────────────────────────
  describe "Gravity.for" do
    it "returns nil and logs rather than raising when the vote store is unreachable" do
      SiteSetting.curiobase_member_voting_enabled = true
      # ⚠ `raw_many`, not `raw`. Every read goes through the batch primitive now
      #   — `raw` delegates to it — so stubbing `raw` would leave the real path
      #   untouched and the test would pass while proving nothing.
      allow(Curiobase::VoteStore).to receive(:raw_many).and_raise(Redis::CannotConnectError, "down")
      expect(Rails.logger).to receive(:warn).with(/votes unavailable for primer-2004/)

      expect(Curiobase::Gravity.for({ "slug" => "primer-2004" }, "causal-loop")).to be_nil
    end
  end

  # ── the cook hook ───────────────────────────────────────────────────────────
  #
  # ⚠ The whole point of this rescue is that a post still saves and still cooks
  #   when the card blows up. If that ever stops being true, a bad record takes
  #   down the topic it lives on.
  describe "the render hook" do
    it "still cooks the post when the card renderer raises, and says why" do
      allow_any_instance_of(Curiobase::CardRenderer).to receive(:render!).and_raise(NoMethodError, "gone")
      expect(Rails.logger).to receive(:error).with(/render failed on post .*NoMethodError/)

      topic, post =
        record_topic!("Primer, the garage film about loops",
                      "type: work\nslug: primer-2004\nmedium: film\ndek: Two engineers build a box.")

      expect(post.cooked).to be_present
      expect(topic.reload.first_post).to eq(post)
    end
  end

  # ── JSON-LD ─────────────────────────────────────────────────────────────────
  #
  # ⚠ This rescue has already cost a session. `members?` → `voters?` left a
  #   dangling call, every Work lost its structured data, and the only trace was
  #   one warning in a log nobody was tailing.
  describe "JsonLd.for_controller" do
    let(:controller) do
      topic, = record_topic!("Primer, the garage film about loops",
                             "type: work\nslug: primer-2004\nmedium: film\ndek: Two engineers build a box.")
      double(instance_variable_get: double(topic: topic), params: {})
    end

    it "emits a script tag for a record topic" do
      expect(Curiobase::JsonLd.for_controller(controller)).to include('type="application/ld+json"', "Movie")
    end

    it "returns an empty string and logs the class AND a backtrace when building blows up" do
      allow(Curiobase::JsonLd).to receive(:build).and_raise(TypeError, "nope")
      expect(Rails.logger).to receive(:warn).with(/json-ld FAILED .*TypeError: nope/m)

      expect(Curiobase::JsonLd.for_controller(controller)).to eq("")
    end

    it "never lets a broken record produce a half-written script tag" do
      allow(Curiobase::JsonLd).to receive(:build).and_raise("x")
      allow(Rails.logger).to receive(:warn)

      out = Curiobase::JsonLd.for_controller(controller)
      expect(out).not_to include("<script")
    end
  end

  # ── the rebake job ──────────────────────────────────────────────────────────
  #
  # Every other spec calls Curiobase.rebake_now! directly, so the job Sidekiq
  # actually runs in production was never exercised.
  describe "Jobs::CuriobaseRebake" do
    it "rebakes the post it is given" do
      _, post = record_topic!("Primer, the garage film about loops",
                              "type: work\nslug: primer-2004\nmedium: film\ndek: Two engineers build a box.")
      post.update_columns(cooked: "<p>stale</p>")

      Jobs::CuriobaseRebake.new.execute(post_id: post.id)

      expect(post.reload.cooked).to include("curiobase-card")
    end

    it "does nothing when the plugin is off" do
      _, post = record_topic!("Primer, the garage film about loops",
                              "type: work\nslug: primer-2004\nmedium: film\ndek: Two engineers build a box.")
      SiteSetting.curiobase_enabled = false
      post.update_columns(cooked: "<p>stale</p>")

      Jobs::CuriobaseRebake.new.execute(post_id: post.id)

      expect(post.reload.cooked).to eq("<p>stale</p>")
    end

    it "does not raise on a post that has been deleted since the job was queued" do
      expect { Jobs::CuriobaseRebake.new.execute(post_id: -1) }.not_to raise_error
    end
  end

  # ⚠ rebake! publishes fence-only cooked and enqueues a second ProcessPost.
  #   Outside HTTP that race left Subject files stuck as lang-curiobase blocks.
  describe "Curiobase.rebake_now!" do
    it "does not call Post#rebake! (avoids fence flash + duplicate ProcessPost)" do
      _, post = record_topic!(
        "Primer, the garage film about loops",
        "type: work\nslug: primer-rebake-now\nmedium: film\ndek: Two engineers build a box.",
      )
      expect(post).not_to receive(:rebake!)

      Curiobase.rebake_now!(post)

      expect(post.reload.cooked).to include("curiobase-card")
      expect(post.cooked).not_to include("lang-curiobase")
    end
  end

  # ── PostMedia ───────────────────────────────────────────────────────────────
  #
  # ⚠ This class had no coverage at all. It owns the UploadReference claim, which
  #   is what stops Jobs::CleanUpUploads reaping every poster on the site.
  describe Curiobase::PostMedia do
    fab!(:upload) { Fabricate(:image_upload, width: 1000, height: 1500) }

    def doc_for(html) = Nokogiri::HTML5.fragment(html)

    it "returns nil when the author added no image" do
      _, post = record_topic!("Primer, the garage film about loops",
                              "type: work\nslug: primer-2004\nmedium: film\ndek: A box.")
      expect(described_class.new(doc_for("<p>no image here</p>"), post).take!).to be_nil
    end

    # Emoji and avatars are <img> too.
    it "ignores emoji and avatars" do
      _, post = record_topic!("Primer, the garage film about loops",
                              "type: work\nslug: primer-2004\nmedium: film\ndek: A box.")
      html = '<img class="emoji" src="/e.png"><img class="avatar" src="/a.png">'
      expect(described_class.new(doc_for(html), post).take!).to be_nil
    end

    it "lifts the image out, so the poster never renders twice" do
      _, post = record_topic!("Primer, the garage film about loops",
                              "type: work\nslug: primer-2004\nmedium: film\ndek: A box.")
      doc = doc_for(%(<p><img src="#{upload.url}" width="1000" height="1500"></p>))

      figure = described_class.new(doc, post).take!

      expect(figure["class"]).to eq("cb-poster")
      expect(doc.css("img")).to be_empty
      expect(figure.at_css("img")["loading"]).to eq("lazy")
    end

    # ⚠ A bare <a class="lightbox"> left behind renders as an empty link — the
    #   same "link with no text" defect that hid the missing titles.
    it "takes the whole lightbox wrapper, not just the img" do
      _, post = record_topic!("Primer, the garage film about loops",
                              "type: work\nslug: primer-2004\nmedium: film\ndek: A box.")
      html = %(<div class="lightbox-wrapper"><a class="lightbox" href="/x"><img src="#{upload.url}"></a></div>)
      doc = doc_for(html)

      described_class.new(doc, post).take!

      expect(doc.css("a.lightbox")).to be_empty
      expect(doc.css(".lightbox-wrapper")).to be_empty
    end

    it "survives an upload it cannot resolve rather than raising" do
      _, post = record_topic!("Primer, the garage film about loops",
                              "type: work\nslug: primer-2004\nmedium: film\ndek: A box.")
      doc = doc_for(%(<img src="/broken.png" data-base62-sha1="notreal">))

      expect { described_class.new(doc, post).take! }.not_to raise_error
    end

    it "logs rather than raising when the upload cannot be claimed" do
      _, post = record_topic!("Primer, the garage film about loops",
                              "type: work\nslug: primer-2004\nmedium: film\ndek: A box.")
      allow(UploadReference).to receive(:ensure_exist!).and_raise(ActiveRecord::StatementInvalid, "locked")
      allow(Upload).to receive(:find_by).and_return(upload)
      allow(Upload).to receive(:sha1_from_base62_encoded).and_return("abc")
      expect(Rails.logger).to receive(:warn).with(/could not claim upload/)

      doc = doc_for(%(<img src="#{upload.url}" data-base62-sha1="x">))
      expect { described_class.new(doc, post).take! }.not_to raise_error
    end

    it "logs rather than raising when the variant cannot be generated" do
      _, post = record_topic!("Primer, the garage film about loops",
                              "type: work\nslug: primer-2004\nmedium: film\ndek: A box.")
      allow(Upload).to receive(:find_by).and_return(upload)
      allow(Upload).to receive(:sha1_from_base62_encoded).and_return("abc")
      allow(OptimizedImage).to receive(:create_for).and_raise(StandardError, "imagemagick")
      expect(Rails.logger).to receive(:warn).with(/optimise failed/)

      doc = doc_for(%(<img src="#{upload.url}" data-base62-sha1="x">))
      figure = described_class.new(doc, post).take!

      # Still returns a usable node — an unoptimised poster beats no poster.
      expect(figure.at_css("img")).to be_present
    end
  end

  # ── fixtures ────────────────────────────────────────────────────────────────
  describe "Source::Fixture" do
    it "returns nil and logs on a malformed fixture rather than raising" do
      allow(File).to receive(:exist?).and_return(true)
      allow(File).to receive(:read).and_return("{ not json")
      expect(Rails.logger).to receive(:warn).with(/bad fixture/)

      expect(Curiobase::Source::Fixture.new.subject("anything")).to be_nil
    end
  end
end
