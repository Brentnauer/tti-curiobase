# frozen_string_literal: true

require "rails_helper"

RSpec.describe Curiobase::Subjects do
  fab!(:ordinary) { Fabricate(:tag, name: "funny") }
  fab!(:subject_tag) { Fabricate(:tag, name: "causal-loop") }

  before do
    SiteSetting.curiobase_enabled = true
    described_class.reset_cache!
  end

  describe ".vocabulary" do
    it "includes only slugs with a live Subject file" do
      expect(described_class.vocabulary).not_to include("causal-loop")
      claim_subject_file!("causal-loop")
      expect(described_class.vocabulary).to include("causal-loop")
      expect(described_class.vocabulary).not_to include("funny")
    end

    it "drops a slug when its Subject topic is trashed" do
      topic = claim_subject_file!("causal-loop")
      expect(described_class.vocabulary).to include("causal-loop")

      topic.trash!(Discourse.system_user)
      described_class.reset_cache!
      expect(described_class.vocabulary).not_to include("causal-loop")
    end
  end

  describe ".for_topic" do
    it "returns only tags that have Subject files" do
      claim_subject_file!("causal-loop")
      topic = Fabricate(:topic, tags: [subject_tag, ordinary])
      expect(described_class.for_topic(topic)).to eq(["causal-loop"])
    end

    it "ignores tags with no Subject file" do
      topic = Fabricate(:topic, tags: [ordinary])
      expect(described_class.for_topic(topic)).to eq([])
    end
  end

  describe ".file?" do
    it "mirrors vocabulary membership" do
      expect(described_class.file?("causal-loop")).to eq(false)
      claim_subject_file!("causal-loop")
      expect(described_class.file?("causal-loop")).to eq(true)
    end
  end
end
