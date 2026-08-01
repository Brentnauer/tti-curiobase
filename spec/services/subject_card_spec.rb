# frozen_string_literal: true

require "rails_helper"

RSpec.describe Curiobase::SubjectCard do
  fab!(:tag) { Fabricate(:tag, name: "john-titor") }
  fab!(:group) { Fabricate(:tag_group, name: "Subjects", tags: [tag]) }
  fab!(:record_topic) { Fabricate(:topic, title: "John Titor, the 2036 soldier") }
  fab!(:record_post) { Fabricate(:post, topic: record_topic, raw: "[wrap=subject id=john-titor]\n[/wrap]") }

  # Something has to engage the subject or there are no chips to test.
  fab!(:chat_topic) { Fabricate(:topic, title: "Did he ever actually come back?") }
  fab!(:chat_post) { Fabricate(:post, topic: chat_topic, raw: "Nobody knows.") }

  before do
    SiteSetting.curiobase_enabled = true
    SiteSetting.curiobase_subject_tag_group = "Subjects"
    Curiobase::Subjects.reset_cache!
    [record_topic, chat_topic].each { |t| t.tags = [tag] }

    # ⚠ BAKING IS SETUP, NOT AN ASSERTION.
    #
    #   What a topic IS — its medium, and which record it carries — is cached on
    #   the topic by CardRenderer at bake time. The filter counts and the "open
    #   the record" link both read that cache, because the alternative is an
    #   unindexable ILIKE across 125,297 posts on a route crawlers hammer.
    #
    #   In the running server every post is baked on creation, so this is free.
    #   Here the fabricators write rows directly, so nothing has been baked and
    #   the cache is empty. Fabricating without baking is a state production
    #   never sees.
    #
    #   On the live forum the equivalent is: topics baked before this shipped
    #   have no cache either. `bin/rake curiobase:rebake` fills it.
    Curiobase.rebake_now!(record_post)
  end

  def html(variant, filter: nil)
    described_class.for_slug("john-titor", variant: variant, active_filter: filter).to_html
  end

  describe "the full card" do
    it "leads with the dek and includes the association list" do
      h = html(:full)
      expect(h).to include("cb-dek")
      expect(h).to include("cb-assoc")
      expect(h.index("cb-dek")).to be < h.index("cb-assoc")
    end

    it "marks the All chip active when no filter is selected" do
      expect(html(:full)).to include('data-kind="all"').and include("cb-filter is-active")
      # The active class sits on the All chip specifically.
      frag = Nokogiri::HTML5.fragment(html(:full))
      expect(frag.at_css('.cb-filter.is-active')["data-kind"]).to eq("all")
    end

    it "invites a pairing when nothing engages the Subject yet" do
      chat_topic.tags = []
      expect(html(:full)).to include("cb-assoc--empty")
      expect(html(:full)).to include(I18n.t("curiobase.assoc_empty"))
    end
  end

  describe "the banner" do
    # ⚠ The record topic is the canonical page for a Subject. If the banner
    #   repeated the full card the tag page would be a near-duplicate competing
    #   for the same query, and the two would split their own ranking.
    it "is a summary, not a second copy of the card" do
      expect(html(:banner)).not_to include("cb-assoc-list")
    end

    it "points at the record topic" do
      expect(html(:banner)).to include("/t/#{record_topic.slug}/#{record_topic.id}")
    end

    it "still leads with the dek, because the banner is first on the page" do
      h = html(:banner)
      expect(h.index("cb-dek")).to be < h.index("cb-filters")
    end
  end

  describe "filter chips" do
    # /tag/<slug> works but 301s to /tag/<slug>/<id>. Linking the redirecting
    # form spends crawl budget on a hop for nothing.
    it "links the canonical tag URL, not the redirecting one" do
      expect(html(:banner)).to include("/tag/john-titor/#{tag.id}")
    end

    it "marks the active filter" do
      expect(html(:banner, filter: "discussion")).to include("cb-filter is-active")
    end

    it "escapes record data rather than interpolating it" do
      allow(Curiobase::Source).to receive(:subject).and_return(
        { "slug" => "john-titor", "title" => "x", "kind" => "person", "dek" => "<script>alert(1)</script>" },
      )
      expect(html(:banner)).to include("&lt;script&gt;")
      expect(html(:banner)).not_to include("<script>")
    end

    # "All 0" is a control that does nothing sitting beside a number saying so.
    it "shows no chips at all when nothing engages the subject" do
      chat_topic.tags = []
      expect(html(:banner)).to include("cb-filters--empty")
      expect(html(:banner)).not_to include("cb-filter\"")
    end
  end

  # The chips stay anchors with working hrefs — that is the crawler and no-JS
  # path — and carry what the script needs to filter in place instead.
  describe "filter chips" do
    it "carries the kind and the real total on every chip" do
      h = html(:full)
      expect(h).to include('data-kind="all"')
      expect(h).to include('data-kind="discussion"')
      expect(h).to match(/data-count="\d+"/)
    end

    it "still links the canonical filtered tag URL, for crawlers and no-JS" do
      expect(html(:full)).to include("/tag/john-titor/#{tag.id}?curiobase=discussion")
    end

    it "marks every row with its kind, so nothing has to be fetched to filter" do
      expect(html(:full)).to include('data-kind="discussion"')
    end
  end

  # ⚠ Two different questions deserve two different surfaces. The curated list
  #   answers "what should I look at"; this answers "no, show me all of it".
  describe "the see-everything exit" do
    before do
      2.times do |i|
        t = Fabricate(:topic, title: "Yet another Titor argument #{i}")
        Fabricate(:post, topic: t, raw: "Words.")
        t.tags = [tag]
      end
    end

    # Discourse's own stub_const takes (target, const, value) and a block.
    def capped(variant)
      stub_const(Curiobase::Associations, :PER_BUCKET, 1) { html(variant) }
    end

    it "appears when the list is holding things back, and names the real total" do
      h = capped(:full)
      expect(h).to include("cb-assoc-all")
      expect(h).to include("All 3 topics tagged John Titor")
      expect(h).to include("/tag/john-titor/#{tag.id}")
    end

    it "is absent when the list already shows everything" do
      expect(html(:full)).not_to include("cb-assoc-all")
    end

    # The banner IS the tag page. Linking a page to itself is not an exit.
    it "never appears on the banner" do
      expect(capped(:banner)).not_to include("cb-assoc-all")
    end
  end
end
