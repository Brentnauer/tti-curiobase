# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Curiobase work media and series" do
  fab!(:admin)
  fab!(:list_thumb) { Fabricate(:image_upload, width: 900, height: 1350) }

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
    # No YouTube still in the poster column — attachment only.
    expect(frag.at_css(".cb-poster--empty, .cb-poster-label")).to be_present
    expect(frag.to_html).not_to include("i.ytimg.com")
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

  # Video keeps a text head + stage player, but a dragged thumbnail (e.g. from a
  # YouTube thumbnail download) is claimed for Subject association lists and
  # lifted out of the body so it does not sit under the card.
  it "claims a dragged video thumbnail for list thumbs without a head poster" do
    topic = Fabricate(:topic, title: "Why Files list thumb demo", user: admin)
    post =
      Fabricate(
        :post,
        topic: topic,
        user: admin,
        post_number: 1,
        raw: <<~RAW,
          ```curiobase
          type: work
          slug: why-files-list-thumb
          medium: video
          youtube: dQw4w9WgXcQ
          dek: Episode with a manual YouTube thumbnail for lists.
          ```

          ![thumb|900x1350](#{list_thumb.short_url})
        RAW
      )
    Curiobase.rebake_now!(post)
    post.reload
    topic.reload

    frag = Nokogiri::HTML.fragment(post.cooked)
    expect(frag.at_css(".cb-head--text")).to be_present
    expect(frag.at_css(".cb-poster, .cb-poster--empty")).to be_nil
    # Lifted out of the body — no free-floating cooked image or empty remnant.
    expect(frag.css("img").reject { |img| img.ancestors(".curiobase-card").any? }).to be_empty
    expect(post.cooked).not_to include("<p></p>")
    expect(topic.custom_fields[Curiobase::CardRenderer::POSTER_FIELD]).to be_present
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
    expect(hub_frag.at_css(".cb-episodes-sort")).to be_present
    expect(hub_frag.at_css(".cb-episodes-row")["data-recommend"]).to be_present
  end

  it "embeds google books as a stage iframe; poster stays author-owned" do
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
    expect(frag.at_css(".cb-head .cb-poster--empty, .cb-head .cb-poster-label")).to be_present
    expect(frag.to_html).not_to include("books.google.com/books/content")
    stage = frag.at_css(".cb-stage .cb-embed--gbooks iframe.cb-embed-frame")
    expect(stage["src"]).to include("books.google.com/books?id=Zy1FAAAAQBAJ")
    expect(stage["src"]).to include("output=embed")
    expect(frag.at_css(".cb-stage a.cb-media-link[data-provider='google_books']")).to be_nil
  end

  it "embeds archive.org as a stage iframe without auto-pulling a cover" do
    post =
      bake!(
        "A document with an Archive embed",
        <<~RAW,
          ```curiobase
          type: work
          slug: archive-embed-demo
          medium: document
          archive_org: chemotaxonomiede05hegn
          dek: A recovered volume on the Internet Archive.
          ```
        RAW
      )

    frag = Nokogiri::HTML.fragment(post.cooked)
    expect(frag.at_css(".cb-head .cb-poster--empty, .cb-head .cb-poster-label")).to be_present
    expect(frag.to_html).not_to include("archive.org/services/img/")
    iframe = frag.at_css(".cb-stage .cb-embed--archive iframe.cb-embed-frame")
    expect(iframe["src"]).to eq("https://archive.org/embed/chemotaxonomiede05hegn")
    expect(frag.at_css(".cb-stage a.cb-media-link")).to be_nil
  end

  it "bakes an empty series hub without an episodes section" do
    post =
      bake!(
        "Empty series hub card",
        <<~RAW,
          ```curiobase
          type: work
          slug: empty-series-hub
          medium: series
          dek: A series with no episodes yet still needs a card.
          ```
        RAW
      )

    frag = Nokogiri::HTML.fragment(post.cooked)
    expect(frag.at_css(".curiobase-card")).to be_present
    expect(frag.at_css(".cb-dek").text).to include("no episodes yet")
    expect(frag.at_css(".cb-episodes")).to be_nil
  end

  it "bakes association sort keys for live reordering" do
    # Subject card path — exercised via a Work that tags a Subject is elsewhere;
    # here we assert the series hub episode tools bake cleanly for two seasons.
    hub =
      bake!(
        "Multi-season series hub for tools",
        <<~RAW,
          ```curiobase
          type: work
          slug: multi-season-hub
          medium: series
          dek: Hub with more than one season of episodes.
          ```
        RAW
      )

    bake!(
      "Season one episode of the multi hub",
      <<~RAW,
        ```curiobase
        type: work
        slug: multi-s1e1
        medium: video
        series: multi-season-hub
        season: 1
        episode: 1
        youtube: dQw4w9WgXcQ
        dek: First season episode.
        ```
      RAW
    )

    bake!(
      "Season two episode of the multi hub",
      <<~RAW,
        ```curiobase
        type: work
        slug: multi-s2e1
        medium: video
        series: multi-season-hub
        season: 2
        episode: 1
        youtube: jNQXAC9IVRw
        dek: Second season episode.
        ```
      RAW
    )

    Curiobase.rebake_now!(hub)
    frag = Nokogiri::HTML.fragment(hub.reload.cooked)
    expect(frag.at_css(".cb-episodes-seasons")).to be_present
    expect(frag.css(".cb-episodes-seasons .cb-filter").map { |n| n["data-season"] }).to include(
      "all",
      "1",
      "2",
    )
    expect(frag.at_css("#cb-episodes-multi-season-hub")).to be_present
    expect(frag.at_css(".cb-episodes-sort a[data-sort='air']")["href"]).to eq(
      "#cb-episodes-multi-season-hub",
    )
  end
end
