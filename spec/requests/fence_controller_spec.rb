# frozen_string_literal: true

require "rails_helper"

RSpec.describe Curiobase::FenceController do
  fab!(:admin)
  fab!(:user) { Fabricate(:user, trust_level: TrustLevel[2]) }

  before { SiteSetting.curiobase_enabled = true }

  describe "GET /curiobase/schema" do
    it "404s when the plugin is off" do
      SiteSetting.curiobase_enabled = false
      sign_in(admin)
      get "/curiobase/schema.json"
      expect(response.status).to eq(404)
    end

    it "refuses non-staff" do
      sign_in(user)
      get "/curiobase/schema.json"
      expect(response.status).to eq(403)
    end

    it "returns allowlists for staff" do
      sign_in(admin)
      get "/curiobase/schema.json"
      expect(response.status).to eq(200)
      body = response.parsed_body
      expect(body["facets"]["kind"]).to include("incident")
      expect(body["edge_verbs"]).to include("explains")
      expect(body["edge_verbs"]).not_to include("same_as")
      expect(body["edge_cap"]).to eq(Curiobase::PostRecord::EDGE_CAP)
      expect(body["dek_max"]).to eq(200)
    end
  end

  describe "POST /curiobase/fence" do
    def build!(fields)
      post "/curiobase/fence.json", params: { fields: fields }
    end

    it "refuses non-staff" do
      sign_in(user)
      build!(type: "subject", slug: "x", kind: "idea", domain: "time", dek: "A dek.")
      expect(response.status).to eq(403)
    end

    it "writes a Subject fence via RecordWriter" do
      sign_in(admin)
      build!(
        type: "subject",
        slug: "art-bell-faxes",
        kind: "document",
        domain: "time",
        dek: "Faxes that arrived on Coast to Coast.",
        explains: ["no-file-yet"],
      )
      expect(response.status).to eq(200)
      fence = response.parsed_body["fence"]
      expect(fence).to start_with("```curiobase\n")
      expect(fence).to include("slug: art-bell-faxes")
      expect(fence).to include("explains: no-file-yet")
      expect(Curiobase::RecordValidator.errors_for(fence)).to be_empty
    end

    it "accepts a JSON body the way the composer modal sends it" do
      sign_in(admin)
      post "/curiobase/fence.json",
           params: {
             fields: {
               type: "work",
               slug: "primer-2004",
               medium: "film",
               dek: "Two engineers in a garage.",
             },
           }.to_json,
           headers: { "CONTENT_TYPE" => "application/json" }
      expect(response.status).to eq(200)
      expect(response.parsed_body["fence"]).to include("medium: film")
    end

    it "writes a Work fence" do
      sign_in(admin)
      build!(
        type: "work",
        slug: "primer-2004",
        medium: "film",
        mode: "fiction",
        year: "2004",
        dek: "Two engineers in a garage.",
        external: { imdb: "tt0390384" },
      )
      expect(response.status).to eq(200)
      fence = response.parsed_body["fence"]
      expect(fence).to include("medium: film")
      expect(fence).to include("imdb: tt0390384")
    end

    it "returns validation errors without a fence" do
      sign_in(admin)
      build!(type: "subject", slug: "bad slug!", kind: "idea", domain: "time", dek: "x")
      expect(response.status).to eq(422)
      expect(response.parsed_body["errors"].join).to include("slug")
      expect(response.parsed_body["fence"]).to be_blank
    end
  end
end
