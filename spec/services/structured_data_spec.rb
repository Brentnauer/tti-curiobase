# frozen_string_literal: true

require "rails_helper"

# ══════════════════════════════════════════════════════════════════════════════
# WHAT A CRAWLER IS TOLD THESE THINGS ARE.
# ══════════════════════════════════════════════════════════════════════════════
#
# The catalogue's whole search proposition is that a Work is a Movie or a Book
# and a Subject is an Organization or an Event — not a DiscussionForumPosting.
RSpec.describe Curiobase::JsonLd do
  fab!(:admin) { Fabricate(:admin) }
  fab!(:group) { Fabricate(:tag_group, name: "Subjects") }
  fab!(:tag) { Fabricate(:tag, name: "majestic-12") }

  before do
    SiteSetting.curiobase_enabled = true
    SiteSetting.curiobase_subject_tag_group = "Subjects"
    TagGroupMembership.create!(tag: tag, tag_group: group)
  end

  def record!(title, body)
    topic = Fabricate(:topic, title: title, user: admin, tags: [tag])
    post = Fabricate(:post, topic: topic, user: admin, post_number: 1, raw: "```curiobase\n#{body}\n```")
    Curiobase.rebake_now!(post)
    topic.reload
  end

  def ld(topic) = described_class.build(topic)

  # ── works ───────────────────────────────────────────────────────────────────
  describe "a Work" do
    let(:film) do
      record!("Primer (2004), the garage film", <<~R.strip)
        type: work
        slug: primer-2004
        medium: film
        year: 2004
        creator: Shane Carruth
        imdb: tt0390384
        tmdb: 14337
        wikipedia: Primer_(film)
        asin: B0GYQDGWNJ
        dek: Two engineers building something in a garage.
      R
    end

    it "is a Movie, not a forum post" do
      expect(ld(film)["@type"]).to eq("Movie")
    end

    # ══════════════════════════════════════════════════════════════════════════
    # `sameAs` CARRIES EVERY IDENTIFIER, NOT JUST IMDb.
    # ══════════════════════════════════════════════════════════════════════════
    #
    # ⚠ It used to emit IMDb alone, so every ISBN, IGDB id, TMDB id and
    #   archive.org identifier in the catalogue was discarded — and Wikipedia,
    #   the strongest entity signal of the set, with them.
    it "reconciles the entity with everything the record knows" do
      expect(ld(film)["sameAs"]).to contain_exactly(
        "https://www.imdb.com/title/tt0390384/",
        "https://www.themoviedb.org/movie/14337",
        "https://en.wikipedia.org/wiki/Primer_(film)",
      )
    end

    # ⚠ An Amazon listing is where to BUY the thing, not what the thing IS.
    #   Putting it in `sameAs` would tell Google a shop page is the film — and
    #   on this site that URL carries an affiliate tag.
    it "never claims an Amazon listing is the work" do
      expect(ld(film)["sameAs"].join).not_to include("amazon")
      expect(Curiobase::Identifiers::REGISTRY).not_to have_key("asin")
    end

    # ⚠ Google's Movie documentation names `director`; `creator` is valid
    #   schema.org and understood as nothing in particular.
    it "credits a film's creator as its director" do
      expect(ld(film)["director"]).to eq("@type" => "Person", "name" => "Shane Carruth")
      expect(ld(film)).not_to have_key("creator")
    end

    it "credits a book's creator as its author, and sets the ISBN properly" do
      book = record!("The Anubis Gates, Tim Powers 1983", <<~R.strip)
        type: work
        slug: the-anubis-gates
        medium: book
        creator: Tim Powers
        isbn: 9780441004010
        dek: A poet is pulled through a gate into 1810 London.
      R

      expect(ld(book)["@type"]).to eq("Book")
      expect(ld(book)["author"]).to eq("@type" => "Person", "name" => "Tim Powers")
      expect(ld(book)["isbn"]).to eq("9780441004010")
    end

    it "falls back to creator where schema.org names nothing better" do
      game = record!("Steins;Gate, the visual novel 2009", <<~R.strip)
        type: work
        slug: steins-gate
        medium: game
        creator: 5pb. and Nitroplus
        dek: A microwave that sends text messages into the past.
      R

      expect(ld(game)["@type"]).to eq("VideoGame")
      expect(ld(game)["creator"]["name"]).to eq("5pb. and Nitroplus")
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # `image` IS REQUIRED FOR THE RICH RESULT, AND WAS NEVER EMITTED.
  # ══════════════════════════════════════════════════════════════════════════
  describe "the image" do
    it "is absent when the record has no poster, rather than empty" do
      film = record!("Timecrimes (2007), the Spanish one", <<~R.strip)
        type: work
        slug: timecrimes
        medium: film
        dek: A man hides in a field and something goes wrong.
      R

      expect(ld(film)).not_to have_key("image")
    end

    # ⚠ ABSOLUTE. Structured data is read off-site: a relative `/uploads/…` is
    #   legal HTML and useless to a crawler resolving the image.
    it "is absolute when the poster is a site-relative upload" do
      film = record!("Dark (2017), the German series", <<~R.strip)
        type: work
        slug: dark-2017
        medium: series
        dek: Four families and a cave under a nuclear plant.
      R
      film.custom_fields[Curiobase::CardRenderer::POSTER_FIELD] = "/uploads/default/original/1X/abc.jpg"
      film.save_custom_fields

      expect(ld(film.reload)["image"]).to eq("#{Discourse.base_url}/uploads/default/original/1X/abc.jpg")
    end

    it "is left alone when it is already absolute" do
      film = record!("Looper (2012), the Rian Johnson one", <<~R.strip)
        type: work
        slug: looper
        medium: film
        dek: A hitman is sent his own future self.
      R
      film.custom_fields[Curiobase::CardRenderer::POSTER_FIELD] = "https://cdn.example.com/p.jpg"
      film.save_custom_fields

      expect(ld(film.reload)["image"]).to eq("https://cdn.example.com/p.jpg")
    end
  end

  # ── subjects ────────────────────────────────────────────────────────────────
  describe "a Subject" do
    it "takes the schema.org type its kind maps to" do
      org = record!("Majestic 12, the committee file", <<~R.strip)
        type: subject
        slug: majestic-12
        kind: org
        domain: hidden-history
        founded: 1947
        dissolved: 1966
        dek: A committee of twelve said to have been convened in 1947.
      R

      expect(ld(org)["@type"]).to eq("Organization")
      expect(ld(org)["foundingDate"]).to eq("1947")
      expect(ld(org)["dissolutionDate"]).to eq("1966")
    end

    it "gives an incident a start date and a place" do
      event = record!("Rendlesham Forest, the three nights", <<~R.strip)
        type: subject
        slug: rendlesham-forest
        kind: incident
        domain: contact
        began: 1980-12-26
        where: Rendlesham Forest, Suffolk
        dek: Three nights of lights near two USAF bases in December 1980.
      R

      expect(ld(event)["@type"]).to eq("Event")
      expect(ld(event)["startDate"]).to eq("1980-12-26")
      expect(ld(event)["location"]).to eq("@type" => "Place", "name" => "Rendlesham Forest, Suffolk")
    end

    # ══════════════════════════════════════════════════════════════════════════
    # PROSE IN A DATE FIELD IS OMITTED, NOT PASSED THROUGH.
    # ══════════════════════════════════════════════════════════════════════════
    #
    # ⚠ These fields are free text BY DESIGN — `began: 27 December 1980` and
    #   `founded: allegedly 1947` are both things an author will legitimately
    #   write. schema.org's date properties are typed, and an invalid value can
    #   disqualify the whole item, while a missing one merely says less.
    it "omits a date it cannot honestly call a date" do
      event = record!("The Philadelphia Experiment, October 1943", <<~R.strip)
        type: subject
        slug: philadelphia-experiment
        kind: incident
        domain: reality
        began: allegedly 28 October 1943
        dek: A destroyer escort said to have vanished from a Philadelphia dock.
      R

      expect(ld(event)).not_to have_key("startDate")
    end

    it "gives a place real coordinates" do
      place = record!("Skinwalker Ranch, the Utah property", <<~R.strip)
        type: subject
        slug: skinwalker-ranch
        kind: place
        domain: phenomena
        coords: 40.2586, -109.8886
        dek: A 512-acre property in the Uintah Basin.
      R

      expect(ld(place)["@type"]).to eq("Place")
      expect(ld(place)["geo"]).to eq(
        "@type" => "GeoCoordinates",
        "latitude" => 40.2586,
        "longitude" => -109.8886,
      )
    end

    it "omits geo rather than emitting half a coordinate" do
      place = record!("Somewhere vague, the unplotted site", <<~R.strip)
        type: subject
        slug: somewhere-vague
        kind: place
        domain: phenomena
        coords: somewhere in Suffolk
        dek: A location nobody has plotted.
      R

      expect(ld(place)).not_to have_key("geo")
    end

    it "reconciles a subject with Wikipedia too" do
      person = record!("John Titor, the 2036 soldier", <<~R.strip)
        type: subject
        slug: john-titor
        kind: person
        domain: time
        wikipedia: John_Titor
        dek: The screen name behind a series of posts made in 2000 and 2001.
      R

      expect(ld(person)["@type"]).to eq("Person")
      expect(ld(person)["sameAs"]).to eq(["https://en.wikipedia.org/wiki/John_Titor"])
    end
  end

  # ⚠ Gravity is CENTRALITY, not quality. Google renders aggregateRating as
  #   review stars, and stars beside a number that is not a review score is a
  #   lie told to everyone who sees the listing.
  it "never publishes a rating without real voters" do
    SiteSetting.curiobase_member_voting_enabled = true
    film = record!("Coherence (2013), the dinner party", <<~R.strip)
      type: work
      slug: coherence
      medium: film
      dek: A dinner party during the passage of a comet.
    R

    expect(ld(film)).not_to have_key("aggregateRating")
  end

  # ⚠ One registry, read by the card AND by sameAs. Two lists of
  #   "identifier → URL" is the shape that has cost this codebase most.
  it "builds card links and sameAs from the same registry" do
    external = { "isbn" => "9780441004010", "wikipedia" => "Primer_(film)" }

    expect(Curiobase::Identifiers.links(external).values)
      .to match_array(Curiobase::Identifiers.urls(external))
  end
end
