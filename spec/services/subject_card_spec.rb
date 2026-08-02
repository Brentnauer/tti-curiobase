# frozen_string_literal: true

require "rails_helper"

RSpec.describe Curiobase::SubjectCard do
  fab!(:tag) { Fabricate(:tag, name: "john-titor") }
  fab!(:record_topic) { Fabricate(:topic, title: "John Titor, the 2036 soldier") }
  fab!(:record_post) { Fabricate(:post, topic: record_topic, raw: "[wrap=subject id=john-titor]\n[/wrap]") }

  # Something has to engage the subject or there are no chips to test.
  fab!(:chat_topic) { Fabricate(:topic, title: "Did he ever actually come back?") }
  fab!(:chat_post) { Fabricate(:post, topic: chat_topic, raw: "Nobody knows.") }
  fab!(:work_topic) { Fabricate(:topic, title: "Primer (2004) — the garage film") }
  fab!(:work_post) { Fabricate(:post, topic: work_topic, raw: "[wrap=work id=123]\n[/wrap]") }

  before do
    SiteSetting.curiobase_enabled = true
    [record_topic, chat_topic, work_topic].each { |t| t.tags = [tag] }

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
    Curiobase.rebake_now!(work_post)
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

    it "marks the Works chip active when no filter is selected" do
      expect(html(:full)).to include('data-kind="works"').and include("cb-filter is-active")
      frag = Nokogiri::HTML5.fragment(html(:full))
      expect(frag.at_css('.cb-filter.is-active')["data-kind"]).to eq("works")
      expect(frag.at_css(".cb-assoc")["data-default"]).to eq("works")
    end

    it "hides discussions under the default Works view" do
      frag = Nokogiri::HTML5.fragment(html(:full))
      discussion = frag.css(".cb-assoc-row").find { |r| r["data-kind"] == "discussion" }
      expect(discussion).to be_present
      expect(discussion["hidden"]).to eq("hidden")
      expect(discussion["data-buckets"]).to eq("discussion")
    end

    it "invites a pairing when nothing engages the Subject yet" do
      chat_topic.tags = []
      work_topic.tags = []
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
      expect(h.index("cb-dek")).to be < h.index("cb-banner-title")
      expect(h).to include("John Titor")
      expect(h).to include('class="excerpt"')
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
      work_topic.tags = []
      expect(html(:banner)).to include("cb-filters--empty")
      expect(html(:banner)).not_to include("cb-filter\"")
    end
  end

  # The chips stay anchors with working hrefs — that is the crawler and no-JS
  # path — and carry what the script needs to filter in place instead.
  describe "filter chips" do
    it "carries the kind and the real total on every chip" do
      h = html(:full)
      expect(h).to include('data-kind="works"')
      expect(h).to include('data-kind="discussion"')
      expect(h).not_to include('data-kind="all"')
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
      expect(h).to include("All 4 topics tagged John Titor")
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

  describe "typed edges" do
    it "groups verbs under one dt each" do
      html =
        described_class.new(
          {
            "slug" => "rendlesham-forest",
            "title" => "Rendlesham Forest",
            "dek" => "Three nights.",
            "kind" => "incident",
            "domain" => "contact",
            "status" => "contested",
            "refs" => [
              { "verb" => "explains", "label" => "Explains", "slug" => "orfordness-lighthouse", "title" => "Orfordness Lighthouse" },
              { "verb" => "explains", "label" => "Explains", "slug" => "other-account", "title" => "Other" },
              { "verb" => "related", "label" => "Related", "slug" => "bentwaters", "title" => "Bentwaters" },
            ],
          },
        ).to_html

      frag = Nokogiri::HTML5.fragment(html)
      expect(frag.at_css(".cb-dek")).to be_present
      expect(frag.to_html.index("cb-dek")).to be < frag.to_html.index("cb-refs")
      expect(frag.css('dt[data-verb="explains"]').size).to eq(1)
      # One dd per verb — multiple targets share it (· separated), so the
      # facts grid cannot drop a second dd under the label.
      explains = frag.at_css('dd[data-verb="explains"]')
      expect(explains).to be_present
      expect(explains.css("a").map(&:text)).to eq(["Orfordness Lighthouse", "Other"])
      expect(explains.text).to include(" · ")
      expect(frag.css('dt[data-verb="related"]').size).to eq(1)
      expect(frag.css('dd[data-verb="related"]').size).to eq(1)
    end

    it "omits edges from the banner" do
      record = {
        "slug" => "rendlesham-forest",
        "title" => "Rendlesham Forest",
        "dek" => "Three nights.",
        "kind" => "incident",
        "domain" => "contact",
        "refs" => [
          { "verb" => "explains", "label" => "Explains", "slug" => "orfordness-lighthouse", "title" => "Orfordness" },
        ],
      }
      html = described_class.new(record, variant: :banner).to_html
      expect(html).not_to include("cb-refs")
      expect(html).to include("cb-banner-title")
      expect(html).to include("Rendlesham Forest")
      expect(html).not_to include("cb-banner-thumb")
      expect(described_class.new(record, variant: :full).to_html).to include("cb-refs")
    end

    it "attributes inbound explains without mirror verbs" do
      orford = Fabricate(:tag, name: "orfordness-lighthouse")

      fab_topic = Fabricate(:topic, title: "Orfordness Lighthouse", tags: [orford])
      Fabricate(
        :post,
        topic: fab_topic,
        raw: <<~RAW.strip,
          ```curiobase
          type: subject
          slug: orfordness-lighthouse
          kind: place
          domain: contact
          dek: The lighthouse on Orford Ness.
          ```
        RAW
      )
      Curiobase.rebake_now!(fab_topic.first_post)
      Curiobase::SubjectEdges.replace!(
        fab_topic,
        [{ "verb" => "explains", "slug" => "rendlesham-forest" }],
      )

      html =
        described_class.new(
          {
            "slug" => "rendlesham-forest",
            "title" => "Rendlesham Forest",
            "dek" => "Three nights.",
            "kind" => "incident",
            "domain" => "contact",
          },
        ).to_html

      expect(html).to include("cb-inbound")
      expect(html).to include("Other files point here")
      expect(html).to include("explains this")
      expect(html).not_to include("Explained by")
      expect(html).to include("Orfordness Lighthouse")
    end
  end

  describe "computed disagreement" do
    before do
      SiteSetting.curiobase_member_voting_enabled = true
      2.times do
        Curiobase::VoteStore.cast(
          work_id: "primer-2004",
          subject: "john-titor",
          user_id: Fabricate(:user, trust_level: TrustLevel[1]).id,
          value: 1,
        )
      end
      2.times do
        Curiobase::VoteStore.cast(
          work_id: "primer-2004",
          subject: "john-titor",
          user_id: Fabricate(:user, trust_level: TrustLevel[1]).id,
          value: 5,
        )
      end
    end

    it "marks split pairings on association gravity cells" do
      frag = Nokogiri::HTML5.fragment(html(:full))
      cell = frag.at_css(".cb-assoc-gravity--split")
      expect(cell).to be_present
      expect(cell["data-disagree"]).to eq("1")
      expect(cell["title"]).to include(I18n.t("curiobase.members_disagree"))
    end

    it "notes when staff status is settled but members still split" do
      # Fixture status is hoax-admitted — a settled staff mark.
      expect(html(:full)).to include("cb-status-signal")
      expect(html(:full)).to include(I18n.t("curiobase.status_membership_split", status: "hoax admitted"))
    end
  end
end
