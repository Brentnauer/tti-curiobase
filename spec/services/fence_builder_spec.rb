# frozen_string_literal: true

require "rails_helper"

RSpec.describe Curiobase::FenceBuilder do
  it "exposes schema from the Ruby allowlists" do
    schema = described_class.schema
    expect(schema[:facets]).to eq(Curiobase::RecordValidator::FACETS)
    expect(schema[:edge_verbs]).not_to include("same_as")
  end

  it "round-trips through RecordWriter without losses" do
    result =
      described_class.build(
        {
          "type" => "subject",
          "slug" => "john-titor",
          "kind" => "person",
          "domain" => "time",
          "dek" => "A soldier from 2036.",
          "refs" => [{ "verb" => "involves", "slug" => "art-bell-faxes" }],
        },
      )

    expect(result).to be_ok
    back = Curiobase::PostRecord.to_record(Curiobase::PostRecord.parse(result.fence))
    expect(back["slug"]).to eq("john-titor")
    expect(back["refs"].map { |r| r["slug"] }).to include("art-bell-faxes")
  end
end
