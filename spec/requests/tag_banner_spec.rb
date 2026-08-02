# frozen_string_literal: true

require "rails_helper"

# The banner must travel WITH the topic list, not arrive in a second request.
#
# ⚠ The flash this prevents was not a slow load. The banner is server-rendered
#   into Discourse's preload-content block and is on screen before any JS runs;
#   Ember then replaces #main-outlet and discards it. An earlier version fetched
#   it back, so it appeared, vanished and returned.
RSpec.describe "Curiobase tag banner" do
  fab!(:tag) { Fabricate(:tag, name: "john-titor") }
  fab!(:plain_tag) { Fabricate(:tag, name: "funny") }

  fab!(:record_topic) { Fabricate(:topic, title: "John Titor, the 2036 soldier") }
  fab!(:record_post) { Fabricate(:post, topic: record_topic, raw: "[wrap=subject id=john-titor]\n[/wrap]") }
  fab!(:chat_topic) { Fabricate(:topic, title: "Did he ever actually come back?") }
  fab!(:chat_post) { Fabricate(:post, topic: chat_topic, raw: "Nobody knows.") }

  before do
    SiteSetting.curiobase_enabled = true
    SiteSetting.tagging_enabled = true
    record_topic.tags = [tag]
    chat_topic.tags = [tag, plain_tag]

    # Bake writes the Subject-file claim — that is the pairing vocabulary.
    Curiobase.rebake_now!(record_post)
  end

  def banner(path)
    get path
    expect(response.status).to eq(200)
    response.parsed_body["topic_list"]["curiobase_banner"]
  end

  it "ships the rendered banner on a Subject's tag list" do
    b = banner("/tag/john-titor.json")
    expect(b["slug"]).to eq("john-titor")
    expect(b["html"]).to include("cb-dek")
    expect(b["html"]).to include("cb-banner-title")
    expect(b["html"]).to include("John Titor")
    expect(b["html"]).not_to include("cb-banner-thumb")
    expect(b["html"]).to include("/t/#{record_topic.slug}/#{record_topic.id}")
  end

  # ⚠ ON THE LIST, NOT THE ITEM. Gravity belongs to the (work, subject) pairing,
  #   and topic_list_item has no idea which tag page it is being rendered on.
  describe "the scores that ride along with the list" do
    def scores(path)
      get path
      response.parsed_body["topic_list"]["curiobase_scores"]
    end

    it "keys the score and the recommendations by topic id" do
      work = Fabricate(:topic, title: "Primer, the garage picture")
      wp = Fabricate(:post, topic: work, raw: "[wrap=work id=123]\n[/wrap]")
      wp.update!(like_count: 9)
      work.tags = [Fabricate(:tag, name: "causal-loop")]
      claim_subject_file!("causal-loop")
      Curiobase.rebake_now!(wp)

      Curiobase::VoteStore.cast(
        work_id: "primer-2004", subject: "causal-loop", user_id: Fabricate(:admin).id, value: 5,
      )

      s = scores("/tag/causal-loop.json")[work.id.to_s]
      expect(s["medium"]).to eq("film")
      expect(s["gravity"]).to eq(5.0)
      expect(s["recommend"]).to eq(9)
    end

    it "is absent on a tag that is not a Subject" do
      expect(scores("/tag/funny.json")).to be_nil
    end

    it "is absent on /latest, where there is no subject to score against" do
      expect(scores("/latest.json")).to be_nil
    end
  end

  it "reflects the active filter, so the chips are right on first paint" do
    expect(banner("/tag/john-titor.json?curiobase=discussion")["html"]).to include("is-active")
  end

  # It runs on every list in the site — /latest, every category, every tag.
  it "is absent on a tag that is not a Subject" do
    expect(banner("/tag/funny.json")).to be_nil
  end

  it "is absent on /latest" do
    expect(banner("/latest.json")).to be_nil
  end

  it "is absent when the plugin is off" do
    SiteSetting.curiobase_enabled = false
    expect(banner("/tag/john-titor.json")).to be_nil
  end
end
