# frozen_string_literal: true

require "rails_helper"

# ══════════════════════════════════════════════════════════════════════════════
# WHAT A CRAWLER GETS ON A SUBJECT'S TAG PAGE.
# ══════════════════════════════════════════════════════════════════════════════
#
# ⚠ THIS EXISTS BECAUSE THE FIRST VERSION WAS A NO-OP THAT LOOKED SHIPPED.
#
#   The tag name sits in a DIFFERENT param on each of three routes:
#
#     /tag/:tag_slug/:tag_id   the canonical one, where tag_id is NUMERIC
#     /tag/:tag_id             the API form, numeric
#     /tag/:tag_name           legacy, 301s to the canonical
#
#   The builder read `params[:tag_id]` and compared it to the subject
#   vocabulary. On the canonical URL that is "13". It matched nothing, returned
#   "" on every page, and nothing said so — the method was written, reviewed and
#   believed for an hour before a curl proved it had never once fired.
#
#   A unit test on the method would have passed. Only the real route catches it.
RSpec.describe "the tag page, for a crawler" do
  fab!(:tag) { Fabricate(:tag, name: "majestic-12") }
  fab!(:tag_group) { Fabricate(:tag_group, name: "Subjects", tags: [tag]) }

  fab!(:file_topic) { Fabricate(:topic, title: "Majestic 12, the committee itself") }
  fab!(:work_topic) { Fabricate(:topic, title: "Deus Ex (2000), the Ion Storm game") }

  before do
    SiteSetting.curiobase_enabled = true
    SiteSetting.curiobase_subject_tag_group = "Subjects"
    Curiobase::Subjects.reset_cache!

    Curiobase.rebake_now!(
      Fabricate(:post, topic: file_topic, post_number: 1, raw: <<~RAW),
        ```curiobase
        type: subject
        slug: majestic-12
        kind: org
        domain: hidden-history
        dek: A committee of twelve scientists and officials named in documents that surfaced in 1984.
        ```
      RAW
    )
    Curiobase.rebake_now!(
      Fabricate(:post, topic: work_topic, post_number: 1, raw: <<~RAW),
        ```curiobase
        type: work
        slug: deus-ex-2000
        medium: game
        dek: Majestic 12 is the antagonist, named and organised much as the documents describe it.
        ```
      RAW
    )
    [file_topic, work_topic].each { |t| t.tags = [tag] }
  end

  def crawl(path)
    get path, headers: { "HTTP_USER_AGENT" => "Mozilla/5.0 (compatible; Googlebot/2.1)" }
    response.body
  end

  def ld_blocks(body)
    body.scan(%r{<script type="application/ld\+json">(.*?)</script>}m).flatten.map { |j| JSON.parse(j) }
  end

  # ⚠ The canonical shape. `params[:tag_id]` here is the NUMERIC tag id.
  it "describes the Subject on the canonical /tag/:slug/:id route" do
    blocks = ld_blocks(crawl("/tag/#{tag.name}/#{tag.id}"))
    page = blocks.find { |b| b["@type"] == "CollectionPage" }

    expect(page).to be_present
    expect(page["description"]).to start_with("A committee of twelve")
  end

  # ⚠ The legacy /tag/:tag_name form 301s to the canonical one, so a crawler
  #   only ever renders the /tag/:tag_slug/:tag_id shape. Asserted so that a
  #   future Discourse change to this redirect is visible here rather than as a
  #   quietly empty head.
  it "redirects the legacy name-only URL to the canonical one" do
    get "/tag/#{tag.name}", headers: { "HTTP_USER_AGENT" => "Mozilla/5.0 (compatible; Googlebot/2.1)" }

    expect(response).to have_http_status(:moved_permanently)
    expect(response.location).to end_with("/tag/#{tag.name}/#{tag.id}")
  end

  # The numeric /tag/:tag_id route is constrained to `format: :json` in
  # Discourse's own routes, so it is an API shape and never renders a crawler
  # page. `tag_name_from` still resolves it, which is what keeps the resolver
  # honest if that constraint ever changes.
  it "resolves a numeric tag id back to its name" do
    expect(Curiobase::JsonLd.tag_name_from({ tag_id: tag.id.to_s })).to eq("majestic-12")
  end

  it "prefers the slug param over a numeric id when both are present" do
    expect(
      Curiobase::JsonLd.tag_name_from({ tag_slug: "majestic-12", tag_id: "13" }),
    ).to eq("majestic-12")
  end

  # ⚠ Points AT the file rather than duplicating it. Canonicalising the tag page
  #   to the record topic would de-index it, which is the opposite of the goal.
  it "names the record topic as the Subject's own page without claiming to be it" do
    page = ld_blocks(crawl("/tag/#{tag.name}/#{tag.id}")).find { |b| b["@type"] == "CollectionPage" }

    expect(page["about"]["@type"]).to eq("Organization")
    expect(page["about"]["mainEntityOfPage"]).to include("/t/#{file_topic.slug}/#{file_topic.id}")
    expect(page["url"]).to include("/tag/majestic-12")
  end

  it "lists the works as an ordered ItemList" do
    page = ld_blocks(crawl("/tag/#{tag.name}/#{tag.id}")).find { |b| b["@type"] == "CollectionPage" }
    list = page["mainEntity"]

    expect(list["@type"]).to eq("ItemList")
    expect(list["numberOfItems"]).to eq(1)
    expect(list["itemListElement"].first["name"]).to eq(work_topic.title)
    expect(list["itemListElement"].first["position"]).to eq(1)
  end

  # ⚠ Two description tags means a crawler reads the first and discards yours.
  it "does not add a second description meta tag" do
    expect(crawl("/tag/#{tag.name}/#{tag.id}").scan(/name="description"/).size).to eq(1)
  end

  # ⚠ Gravity is centrality, not quality. Stars in a search result would be a
  #   lie told to everyone who sees the listing.
  it "publishes no rating on the list" do
    expect(crawl("/tag/#{tag.name}/#{tag.id}")).not_to include("aggregateRating")
  end

  it "says nothing on an ordinary tag that is not a Subject" do
    other = Fabricate(:tag, name: "off-topic-chatter")
    expect(ld_blocks(crawl("/tag/#{other.name}/#{other.id}"))).to be_empty
  end

  it "says nothing when the plugin is disabled" do
    SiteSetting.curiobase_enabled = false
    expect(ld_blocks(crawl("/tag/#{tag.name}/#{tag.id}"))).to be_empty
  end
end
