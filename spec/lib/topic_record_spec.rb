# frozen_string_literal: true

require "rails_helper"

RSpec.describe Curiobase::TopicRecord do
  fab!(:topic)
  fab!(:post) { Fabricate(:post, topic: topic) }

  def with_raw(raw)
    post.update!(raw: raw)
    described_class.for(topic.reload)
  end

  it "reads a numeric work id" do
    expect(with_raw("[wrap=work id=123]\n[/wrap]")).to eq(kind: "work", id: "123")
  end

  # ⚠ REGRESSION. The original regex was id=(\d+), which matched works and
  #   silently failed on every subject — subjects are keyed by SLUG because the
  #   slug is also the Discourse tag name and the two must be the same string.
  #
  #   Nothing errored. TopicRecord just returned nil, so a Subject topic was not
  #   recognised as a record: it lost its JSON-LD entirely, and it turned up in
  #   its own association list as an ordinary discussion.
  it "reads a slug subject id" do
    expect(with_raw("[wrap=subject id=john-titor]\n[/wrap]")).to eq(kind: "subject", id: "john-titor")
  end

  it "ignores a post with no wrap" do
    expect(with_raw("just a normal post")).to be_nil
  end
end
