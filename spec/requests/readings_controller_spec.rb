# frozen_string_literal: true

require "rails_helper"

RSpec.describe Curiobase::ReadingsController do
  fab!(:tag) { Fabricate(:tag, name: "causal-loop") }
  fab!(:group) { Fabricate(:tag_group, name: "Subjects", tags: [tag]) }

  before do
    SiteSetting.curiobase_enabled = true
    SiteSetting.curiobase_member_voting_enabled = true
    SiteSetting.curiobase_subject_tag_group = "Subjects"
    Curiobase::Subjects.reset_cache!
    FileUtils.rm_f(Rails.root.join("tmp", "curiobase-votes.json"))
  end

  it "returns batched readings for named works" do
    u1 = Fabricate(:user, trust_level: TrustLevel[1])
    u2 = Fabricate(:user, trust_level: TrustLevel[1])
    Curiobase::VoteStore.cast(work_id: "primer-2004", subject: "causal-loop", user_id: u1.id, value: 4)
    Curiobase::VoteStore.cast(work_id: "primer-2004", subject: "causal-loop", user_id: u2.id, value: 5)

    get "/curiobase/readings.json",
        params: {
          subject: "causal-loop",
          works: "primer-2004,unknown-work",
        }

    expect(response.status).to eq(200)
    body = response.parsed_body
    expect(body["subject"]).to eq("causal-loop")
    expect(body["readings"]["primer-2004"]["display"]).to be_a(Numeric)
    expect(body["readings"]["primer-2004"]["voter_count"]).to eq(2)
    expect(body["readings"]["unknown-work"]["display"]).to be_nil
    expect(body["readings"]["unknown-work"]["voter_count"]).to eq(0)
  end

  it "also accepts works as an array" do
    u1 = Fabricate(:user, trust_level: TrustLevel[1])
    Curiobase::VoteStore.cast(work_id: "primer-2004", subject: "causal-loop", user_id: u1.id, value: 4)

    get "/curiobase/readings.json",
        params: {
          subject: "causal-loop",
          works: %w[primer-2004],
        }

    expect(response.status).to eq(200)
    expect(response.parsed_body["readings"]["primer-2004"]["display"]).to eq(4.0)
  end

  it "404s for a subject outside the vocabulary" do
    get "/curiobase/readings.json", params: { subject: "not-a-subject", works: ["x"] }
    expect(response.status).to eq(404)
  end

  it "returns empty readings when no works are named" do
    get "/curiobase/readings.json", params: { subject: "causal-loop" }
    expect(response.status).to eq(200)
    expect(response.parsed_body["readings"]).to eq({})
  end
end
