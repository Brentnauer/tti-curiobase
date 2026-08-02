# frozen_string_literal: true

require "rails_helper"

RSpec.describe Curiobase::Associations do
  fab!(:tag) { Fabricate(:tag, name: "john-titor") }

  # Titles are long enough to clear Discourse's own minimum, which is 15
  # characters and a "seems unclear" heuristic.
  fab!(:subject_topic) { Fabricate(:topic, title: "John Titor, the 2036 soldier") }
  fab!(:work_topic) { Fabricate(:topic, title: "Primer (2004) — the garage film") }
  fab!(:chat_topic) { Fabricate(:topic, title: "Did he ever actually come back?") }

  fab!(:subject_post) { Fabricate(:post, topic: subject_topic, raw: "[wrap=subject id=john-titor]\n[/wrap]") }
  fab!(:work_post) { Fabricate(:post, topic: work_topic, raw: "[wrap=work id=123]\n[/wrap]") }
  fab!(:chat_post) { Fabricate(:post, topic: chat_topic, raw: "Nobody knows.") }

  before do
    SiteSetting.curiobase_enabled = true
    [subject_topic, work_topic, chat_topic].each { |t| t.tags = [tag] }

    # The counts are a SQL query over the curiobase_kind cache, which is written
    # at bake time. Fabricators write rows without baking; the server never does.
    # Subject bake also registers the pairing vocabulary.
    [subject_post, work_post].each { |p| Curiobase.rebake_now!(p) }
  end

  let(:assoc) { described_class.new("john-titor") }
  let(:rows) { assoc.rows }

  it "lists the work from the record source and the thread from Discourse's tag index" do
    expect(rows.map(&:kind)).to contain_exactly("work", "discussion")
    expect(rows.find { |r| r.kind == "work" }.title).to eq("Primer (2004) — the garage film")
    expect(rows.find { |r| r.kind == "discussion" }.title).to eq("Did he ever actually come back?")
  end

  # ⚠ REGRESSION. A Subject's own topic carries its own tag, so before
  #   TopicRecord understood slug ids it failed to be recognised as a record and
  #   fell through into the discussions bucket. "John Titor" appeared in the
  #   list of things that engage John Titor.
  it "never lists the subject's own topic" do
    expect(rows.map(&:title)).not_to include("John Titor, the 2036 soldier")
  end

  # A thread is a conversation ABOUT an idea, not a treatment OF one. Scoring
  # the two together would make the mean meaningless.
  it "gives discussions reply counts and no gravity" do
    d = rows.find { |r| r.kind == "discussion" }
    expect(d.gravity).to be_nil
    expect(d.replies).to eq(0)
  end

  it "keeps discussions off the Works bucket" do
    d = rows.find { |r| r.kind == "discussion" }
    expect(d.buckets).to eq(["discussion"])
    expect(rows.find { |r| r.kind == "work" }.buckets).to include("works")
  end

  it "defaults the chip to Works when Works exist" do
    expect(assoc.default_filter).to eq("works")
  end

  # ⚠ Gravity stays primary. Blending would let a widely-liked 3 outrank an
  #   unloved 5, which inverts what the catalogue is for.
  describe "ranking" do
    def work(title, wrap, likes)
      t = Fabricate(:topic, title: title)
      p = Fabricate(:post, topic: t, raw: "[wrap=work id=#{wrap}]\n[/wrap]")
      p.update!(like_count: likes)
      t.tags = [tag]
      Curiobase.rebake_now!(p)
      t
    end

    it "puts the best first: the score, then recommendations, then argument" do
      work("A book about all of this", 130, 0)
      work("A game about all of this", 127, 99)

      staff = Fabricate(:admin)
      Curiobase::VoteStore.cast(
        work_id: "titor-a-time-travelers-tale", subject: "john-titor", user_id: staff.id, value: 5,
      )
      Curiobase::VoteStore.cast(work_id: "steins-gate", subject: "john-titor", user_id: staff.id, value: 4)

      # ⚠ 99 likes on the 4 must not lift it over the 5. Recommendations answer
      #   a different question and only ever settle a draw.
      titles = described_class.new("john-titor").rows.map(&:title)
      expect(titles.first).to eq("A book about all of this")
    end

    it "uses recommendations to break a tie between equal assessments" do
      quiet = work("The quiet one nobody mentions", 130, 1)
      loved = work("The one everybody points at", 130, 40)

      rows = described_class.new("john-titor").rows.select { |r| r.kind == "work" }
      expect(rows.map(&:title).first(2)).to eq([loved.title, quiet.title])
    end

    it "carries the count on the row, from likes on the first post" do
      work("Something worth recommending here", 130, 7)
      row = described_class.new("john-titor").rows.find { |r| r.recommendations.to_i.positive? }
      expect(row.recommendations).to eq(7)
    end
  end

  describe "counts" do
    it "counts the same things the list shows, and not the subject's own file" do
      expect(assoc.counts["all"]).to eq(2)
      expect(assoc.counts["works"]).to eq(1)
      expect(assoc.counts["film"]).to eq(1)
      expect(assoc.counts["discussion"]).to eq(1)
      expect(assoc.counts).not_to have_key("subject")
    end

    # ⚠ THE DEFECT. Counts used to be tallied from the rendered rows, which cap
    #   at MAX_PER_TYPE — so a Subject with 84 tagged topics rendered a chip
    #   reading "Discussions 25". A chip exists to communicate scale; one that
    #   silently saturates at the page size states a wrong number about the
    #   largest part of the list.
    it "counts past the page size" do
      3.times do |i|
        t = Fabricate(:topic, title: "Another thread about all this #{i}")
        Fabricate(:post, topic: t, raw: "Words.")
        t.tags = [tag]
      end

      # Discourse's own stub_const takes (target, const, value) and a block.
      stub_const(described_class, :PER_BUCKET, 1) do
        a = described_class.new("john-titor")
        expect(a.rows.size).to be < a.counts["all"]
        expect(a.counts["discussion"]).to eq(4)
        expect(a).to be_truncated
      end
    end

    it "is not truncated when the list holds everything" do
      expect(assoc).not_to be_truncated
    end
  end
end
