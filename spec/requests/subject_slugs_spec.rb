# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Curiobase subject slug site payload" do
  fab!(:tag) { Fabricate(:tag, name: "causal-loop") }

  before { SiteSetting.curiobase_enabled = true }

  it "exposes Subject-file slugs for the tag renderer" do
    claim_subject_file!("causal-loop")

    get "/site.json"
    expect(response.status).to eq(200)
    expect(response.parsed_body["curiobase_subject_slugs"]).to include("causal-loop")
  end

  it "is empty when no Subject files exist" do
    get "/site.json"
    expect(response.parsed_body["curiobase_subject_slugs"]).to eq([])
  end
end
