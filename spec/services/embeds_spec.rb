# frozen_string_literal: true

require "rails_helper"

RSpec.describe Curiobase::Embeds do
  it "treats a film youtube id as a playable trailer iframe" do
    emb = described_class.for_record("medium" => "film", "external" => { "youtube" => "dQw4w9WgXcQ" })
    expect(emb.provider).to eq("youtube")
    expect(emb).to be_secondary
    expect(emb).to be_iframe
    expect(emb).not_to be_link
    expect(emb.src).to include("youtube.com/embed/")
    expect(emb.href).to include("youtube.com/watch")
  end

  it "treats a video youtube id as an iframe hero" do
    emb = described_class.for_record("medium" => "video", "external" => { "youtube" => "dQw4w9WgXcQ" })
    expect(emb).to be_hero
    expect(emb).to be_iframe
    expect(emb.src).to include("youtube.com/embed/")
  end

  it "bakes archive as an official embed iframe" do
    emb = described_class.for_record("medium" => "document", "external" => { "archive_org" => "nasa" })
    expect(emb.provider).to eq("archive")
    expect(emb).to be_iframe
    expect(emb).not_to be_link
    expect(emb.src).to eq("https://archive.org/embed/nasa")
    expect(emb.href).to include("archive.org/details/nasa")
  end

  it "bakes google books as a preview iframe in the stage" do
    emb =
      described_class.for_record(
        "medium" => "book",
        "external" => { "google_books" => "Zy1FAAAAQBAJ" },
      )
    expect(emb.provider).to eq("google_books")
    expect(emb).to be_iframe
    expect(emb).not_to be_link
    expect(emb.src).to include("books.google.com/books?id=Zy1FAAAAQBAJ")
    expect(emb.src).to include("output=embed")
    expect(emb.href).to include("books.google.com/books?id=")
    expect(emb.thumb).to include("books/content")
    expect(emb.thumb).to include("zoom=0")
  end

  it "prefers an Open Library cover when an ISBN is present" do
    emb =
      described_class.for_record(
        "medium" => "book",
        "external" => { "google_books" => "Zy1FAAAAQBAJ", "isbn" => "9781591964360" },
      )
    expect(emb.thumb).to include("covers.openlibrary.org/b/isbn/9781591964360")
  end

  it "refuses a junk youtube id" do
    expect(described_class.for_record("medium" => "film", "external" => { "youtube" => "x" })).to be_nil
  end
end

RSpec.describe Curiobase::GoogleBooks do
  it "returns an explicit volume id without probing" do
    id =
      described_class.volume_id_for(
        "external" => { "google_books" => "Zy1FAAAAQBAJ", "isbn" => "9780000000000" },
      )
    expect(id).to eq("Zy1FAAAAQBAJ")
  end

  it "probes ISBN and caches none when not embeddable" do
    stub_request(:get, %r{googleapis\.com/books/v1/volumes})
      .to_return(
        status: 200,
        body: {
          items: [{ id: "abc", accessInfo: { embeddable: false } }],
        }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    expect(described_class.volume_id_for("external" => { "isbn" => "9781234567897" })).to be_nil
  end

  it "does not cache a hard none when Google returns 429" do
    stub_request(:get, %r{googleapis\.com/books/v1/volumes}).to_return(status: 429, body: "no")

    expect(described_class.volume_id_for("external" => { "isbn" => "9780387985718" })).to be_nil
    expect(Discourse.cache.read(described_class.cache_key("9780387985718"))).to be_nil
  end

  it "returns a volume id when the API says embeddable" do
    stub_request(:get, %r{googleapis\.com/books/v1/volumes})
      .to_return(
        status: 200,
        body: {
          items: [{ id: "Zy1FAAAAQBAJ", accessInfo: { embeddable: true } }],
        }.to_json,
        headers: { "Content-Type" => "application/json" },
      )

    expect(described_class.volume_id_for("external" => { "isbn" => "9781234567897" })).to eq(
      "Zy1FAAAAQBAJ",
    )
  end
end
