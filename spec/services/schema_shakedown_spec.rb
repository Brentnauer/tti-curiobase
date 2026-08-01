# frozen_string_literal: true

require "rails_helper"

# Everything here comes from rendering all eight Subject kinds and all six media
# at once. Two fixtures had been enough to hide every one of these.
RSpec.describe "Curiobase schema shakedown" do
  fab!(:tag) { Fabricate(:tag, name: "causal-loop") }
  fab!(:group) { Fabricate(:tag_group, name: "Subjects", tags: [tag]) }
  fab!(:topic)
  fab!(:op) { Fabricate(:post, topic: topic, raw: "[wrap=work id=126]\n[/wrap]") }

  before do
    SiteSetting.curiobase_enabled = true
    SiteSetting.curiobase_subject_tag_group = "Subjects"
    Curiobase::Subjects.reset_cache!
    topic.tags = [tag]
  end

  def work(id)
    op.update!(raw: "[wrap=work id=#{id}]\n[/wrap]")
    Curiobase.rebake_now!(op)
    op.reload.cooked
  end

  def subject_html(slug)
    Curiobase::SubjectCard.for_slug(slug).to_html
  end

  # ⚠ THE ORDER RULE, THIRD REGRESSION. Discourse builds the meta description
  #   from the start of cooked, and stripping tags leaves badge words with no
  #   spaces between them. Every record's snippet began "seriesfiction …",
  #   "incidentcontactcontested …", "documenthidden historydebunked …".
  #
  #   The badges still LOOK first — .cb-badges carries order: -1.
  describe "the dek leads the document, always" do
    it "on a work" do
      c = work(125)
      expect(c.index("cb-dek")).to be < c.index("cb-badges")
    end

    # ⚠ ONE SUBJECT PER KIND, AND EACH IS A REAL SUBJECT WITH REAL WORKS.
    #
    #   An earlier set had `the-2036-claim` standing in for `claim` beside
    #   `john-titor` — the same story, the same works, a schema kind exercised at
    #   the cost of a record that told a reader nothing new. Coverage that only
    #   exists to satisfy the matrix is coverage of a system nobody will build.
    KINDS = {
      "causal-loop" => "idea",
      "rendlesham-forest" => "incident",
      "philadelphia-experiment" => "claim",
      "john-titor" => "person",
      "skinwalker-ranch" => "place",
      "excalibur" => "object",
      "majestic-12" => "org",
      "voynich-manuscript" => "document",
    }.freeze

    it "covers all eight kinds, with no two subjects sharing one" do
      kinds = KINDS.keys.map { |s| Curiobase::Source.subject(s)&.dig("kind") }
      expect(kinds).to match_array(KINDS.values)
      expect(kinds.uniq.size).to eq(8)
    end

    it "on every subject kind" do
      KINDS.each_key do |slug|
        h = subject_html(slug)
        expect(h.index("cb-dek")).to be < h.index("cb-badges"), "#{slug} leads with badges"
      end
    end
  end

  # Only imdb and tmdb were handled, so four of the six media rendered no
  # external link at all — silently, because a missing key looks identical to a
  # record that simply has none.
  describe "external links" do
    {
      126 => "openlibrary.org",
      127 => "igdb.com",
      128 => "youtube.com",
      130 => "archive.org",
    }.each do |id, host|
      it "builds a link for work #{id}" do
        expect(work(id)).to include(host)
      end
    end
  end

  describe "fields that are not short scalars" do
    # A ref points at another Subject. It printed as the literal "causal-loop".
    it "renders a ref as a link to the subject, not as a slug" do
      h = subject_html("john-titor")
      expect(h).to include("Causal Loop")
      expect(h).to match(%r{href="/t(ag)?/causal-loop})
      expect(h).not_to match(/<dd>causal-loop</)
    end

    # supports and contradicts are the reason the claim kind exists. In a
    # two-column definition list they read as trivia.
    it "renders prose as paragraphs, in the authored order" do
      h = subject_html("philadelphia-experiment")
      expect(h).to include("cb-prose-body")
      expect(h.index("Supports")).to be < h.index("Contradicts")
    end

    # A recovered document can run to tens of thousands of words. One exhibit's
    # meta description was, verbatim, "**** * CONFIDENTIAL * ****".
    it "puts full_text last and collapsed" do
      h = subject_html("voynich-manuscript")
      expect(h).to include("<details")
      expect(h.index("cb-fulltext")).to be > h.index("cb-facts")
    end

    it "turns coordinates into a map link" do
      expect(subject_html("skinwalker-ranch")).to include("openstreetmap.org")
    end
  end

  # Period, evidence and status are how the site is navigated, and the card
  # showed none of them until every kind was rendered side by side.
  it "renders the navigational facets" do
    h = subject_html("majestic-12")
    # ⚠ pre-1950, not 1940s. The scale is deliberately coarse and everything
    #   before 1950 collapses into one bucket — this fixture said "1940s" until
    #   WordPress rejected it on seed.
    expect(h).to include("pre-1950")
    expect(h).to include("documentary record")
    expect(h).to include("MJ-12")
  end

  # "The full The Voynich Manuscript story". A third of Subject titles begin
  # with an article and no template can know.
  it "does not double the article in the landing link" do
    expect(subject_html("voynich-manuscript")).not_to match(/full The /)
  end

  # Excalibur is not a creative work. It is a thing people made claims about.
  it "maps object to Thing rather than CreativeWork" do
    expect(Curiobase::JsonLd::KIND["object"]).to eq("Thing")
  end
end
