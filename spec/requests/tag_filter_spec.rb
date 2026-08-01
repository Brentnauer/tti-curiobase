# frozen_string_literal: true

require "rails_helper"

# ?curiobase=film must narrow Discourse's OWN topic list, in SQL. The filter
# chips are real links, so a crawler that follows one has to get a genuinely
# different page.
RSpec.describe "Curiobase tag page filter" do
  fab!(:tag) { Fabricate(:tag, name: "john-titor") }
  fab!(:group) { Fabricate(:tag_group, name: "Subjects", tags: [tag]) }

  fab!(:film_topic) { Fabricate(:topic, title: "Primer (2004) — the garage film") }
  fab!(:film_post) { Fabricate(:post, topic: film_topic, raw: "[wrap=work id=123]\n[/wrap]") }
  fab!(:chat_topic) { Fabricate(:topic, title: "Did he ever actually come back?") }
  fab!(:chat_post) { Fabricate(:post, topic: chat_topic, raw: "Nobody knows.") }

  before do
    SiteSetting.curiobase_enabled = true
    SiteSetting.curiobase_subject_tag_group = "Subjects"
    SiteSetting.tagging_enabled = true
    Curiobase::Subjects.reset_cache!
    [film_topic, chat_topic].each { |t| t.tags = [tag] }
    # The kind is cached at bake time — that is the whole point of the field.
    Curiobase.rebake_now!(film_post)
  end

  def titles(params = {})
    get "/tag/john-titor.json", params: params
    expect(response.status).to eq(200)
    response.parsed_body["topic_list"]["topics"].map { |t| t["title"] }
  end

  it "lists everything with no filter" do
    expect(titles).to contain_exactly(film_topic.title, chat_topic.title)
  end

  it "narrows to records of one medium" do
    expect(titles(curiobase: "film")).to contain_exactly(film_topic.title)
  end

  # A thread is the default state of a topic, so it is defined by absence of a
  # cached kind rather than by a value.
  it "narrows to discussions, meaning everything that is not a record" do
    expect(titles(curiobase: "discussion")).to contain_exactly(chat_topic.title)
  end

  # ⚠ TopicQuery#assert_valid_keys RAISES on an unknown option — an unrecognised
  #   value must be ignored inside the filter, not passed through.
  it "ignores a value that is not a known kind" do
    expect(titles(curiobase: "nonsense")).to contain_exactly(film_topic.title, chat_topic.title)
  end

  it "caches the medium on the topic at bake time" do
    expect(film_topic.reload.custom_fields[Curiobase::TopicKind::FIELD]).to eq("film")
    expect(chat_topic.reload.custom_fields[Curiobase::TopicKind::FIELD]).to be_nil
  end
end
