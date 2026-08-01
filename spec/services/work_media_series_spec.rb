# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Curiobase work media and series" do
  fab!(:admin)

  before do
    SiteSetting.curiobase_enabled = true
    SiteSetting.curiobase_member_voting_enabled = true
  end

  def bake!(title, body)
    topic = Fabricate(:topic, title: title, user: admin)
    post = Fabricate(:post, topic: topic, user: admin, raw: body)
    Curiobase.rebake_now!(post)
    post.reload
  end

  it "bakes a film poster slot and a youtube trailer iframe below the head" do
    post =
      bake!(
        "Primer film card for embeds",
        <<~RAW,
          ```curiobase
          type: work
          slug: primer-embed-demo
          medium: film
          mode: fiction
          year: 2004
          youtube: dQw4w9WgXcQ
          dek: Two engineers build a box that does something odd.
          ```
        RAW
      )

    frag = Nokogiri::HTML.fragment(post.cooked)
    expect(frag.at_css(".cb-poster, .cb-poster--empty")).to be_present
    stage = frag.at_css(".cb-stage")
    expect(stage).to be_present
    iframe = stage.at_css(".cb-embed--trailer iframe, .cb-embed--trailer .cb-embed-frame")
    expect(iframe["src"]).to include("youtube.com/embed/")
    expect(frag.at_css(".cb-head iframe")).to be_nil
    expect(frag.at_css("a.onebox")).to be_nil
  end

  it "bakes a video as a stage iframe without a poster column" do
    post =
      bake!(
        "Why Files episode card for embeds",
        <<~RAW,
          ```curiobase
          type: work
          slug: why-files-embed-demo
          medium: video
          youtube: dQw4w9WgXcQ
          dek: An episode that is the work itself, not a trailer.
          ```
        RAW
      )

    frag = Nokogiri::HTML.fragment(post.cooked)
    expect(frag.at_css(".cb-head--text")).to be_present
    stage = frag.at_css(".cb-stage")
    expect(stage.at_css(".cb-embed--hero iframe, .cb-embed--hero .cb-embed-frame")["src"]).to include(
      "youtube.com/embed/",
    )
    expect(frag.at_css(".cb-poster, .cb-poster--empty")).to be_nil
  end

  it "links an episode to its series hub and lists it on the hub" do
    hub =
      bake!(
        "The Why Files series hub",
        <<~RAW,
          ```curiobase
          type: work
          slug: the-why-files-hub
          medium: series
          dek: A catalogue hub for individual episodes people actually rate.
          ```
        RAW
      )

    ep =
      bake!(
        "John Titor episode of Why Files",
        <<~RAW,
          ```curiobase
          type: work
          slug: why-files-titor-ep
          medium: video
          series: the-why-files-hub
          season: 1
          episode: 12
          youtube: dQw4w9WgXcQ
          dek: The episode entry people rate against Subjects.
          ```
        RAW
      )

    ep_frag = Nokogiri::HTML.fragment(ep.cooked)
    expect(ep_frag.at_css(".cb-series").text).to include("Part of")
    expect(ep_frag.at_css(".cb-series-link").text).to include("Why Files")

    Curiobase.rebake_now!(hub)
    hub_frag = Nokogiri::HTML.fragment(hub.reload.cooked)
    expect(hub_frag.at_css(".cb-episodes")).to be_present
    expect(hub_frag.at_css(".cb-episodes-title").text).to include("John Titor")
    expect(hub_frag.at_css(".cb-episodes-num").text).to match(/S1E12/)
  end

  it "embeds google books as a poster cover plus a preview link in the stage" do
    post =
      bake!(
        "A book with a Google Books preview",
        <<~RAW,
          ```curiobase
          type: work
          slug: book-gbooks-demo
          medium: book
          google_books: Zy1FAAAAQBAJ
          isbn: 9781591964360
          dek: A book whose preview we know is embeddable.
          ```
        RAW
      )

    frag = Nokogiri::HTML.fragment(post.cooked)
    expect(frag.at_css(".cb-head .cb-poster")).to be_present
    link = frag.at_css(".cb-stage a.cb-media-link[data-provider='google_books']")
    expect(link["href"]).to include("books.google.com")
    expect(frag.at_css(".cb-embed--hero iframe")).to be_nil
  end
end
