# frozen_string_literal: true

require "rails_helper"

RSpec.describe Curiobase::SubjectEdges do
  fab!(:rendlesham_tag) { Fabricate(:tag, name: "rendlesham-forest") }
  fab!(:orford_tag) { Fabricate(:tag, name: "orfordness-lighthouse") }

  before do
    SiteSetting.curiobase_enabled = true
    # Edge targets must have Subject files (pairing vocabulary).
    claim_subject_file!("rendlesham-forest")
    claim_subject_file!("orfordness-lighthouse")
  end

  def subject_topic!(title, slug, raw_extra = "")
    topic = Fabricate(:topic, title: title, tags: [Tag.find_by(name: slug)].compact)
    Fabricate(
      :post,
      topic: topic,
      raw: <<~RAW.strip,
        ```curiobase
        type: subject
        slug: #{slug}
        kind: place
        domain: contact
        dek: A subject file for #{slug}.
        #{raw_extra}
        ```
      RAW
    )
    Curiobase.rebake_now!(topic.first_post)
    topic.reload
  end

  describe ".replace!" do
    it "writes one custom-field row per edge and fans out only on change" do
      source = subject_topic!("Orfordness Lighthouse", "orfordness-lighthouse")

      first =
        described_class.replace!(
          source,
          [{ "verb" => "explains", "slug" => "rendlesham-forest" }],
        )
      expect(first).to contain_exactly("rendlesham-forest")
      expect(TopicCustomField.where(topic_id: source.id, name: described_class::FIELD).pluck(:value))
        .to contain_exactly("explains:rendlesham-forest")

      # Unchanged → no fan-out (avoids stampede on every hub rebake).
      expect(
        described_class.replace!(
          source,
          [{ "verb" => "explains", "slug" => "rendlesham-forest" }],
        ),
      ).to eq([])

      changed =
        described_class.replace!(
          source,
          [
            { "verb" => "explains", "slug" => "rendlesham-forest" },
            { "verb" => "contradicts", "slug" => "rendlesham-forest" },
          ],
        )
      # Same target twice under different verbs — still one slug in fan-out.
      expect(changed).to contain_exactly("rendlesham-forest")
    end

    it "never indexes same_as" do
      source = subject_topic!("Orfordness Lighthouse", "orfordness-lighthouse")
      described_class.replace!(
        source,
        [{ "verb" => "same_as", "slug" => "rendlesham-forest" }],
      )
      expect(TopicCustomField.where(topic_id: source.id, name: described_class::FIELD)).to be_empty
    end
  end

  describe ".inbound" do
    it "finds who explains / contradicts this slug" do
      target = subject_topic!("Rendlesham Forest", "rendlesham-forest")
      source =
        subject_topic!(
          "Orfordness Lighthouse",
          "orfordness-lighthouse",
          "explains: rendlesham-forest",
        )

      # replace! runs at bake via CardRenderer
      rows = described_class.inbound("rendlesham-forest")
      expect(rows.map(&:from_slug)).to include("orfordness-lighthouse")
      expect(rows.map(&:verb)).to include("explains")
      expect(rows.map(&:from_title).join).to include("Orfordness")

      # Target topic itself is not a source of inbound to itself from empty edges.
      expect(described_class.inbound("orfordness-lighthouse")).to be_empty
      expect(target).to be_present
      expect(source).to be_present
    end

    # ⚠ QUERY BUDGET. inbound used to call TopicRecord.for per source → N+1
    #   on first_post. A Subject with many inbound explains must stay O(1)
    #   SQL shape (CF + topics + one first-post pluck).
    it "does not open one first_post query per inbound source" do
      subject_topic!("Rendlesham Forest", "rendlesham-forest")
      5.times do |i|
        Fabricate(:tag, name: "inbound-src-#{i}")
        claim_subject_file!("inbound-src-#{i}")
        subject_topic!("Inbound Source #{i}", "inbound-src-#{i}", "explains: rendlesham-forest")
      end

      post_queries = 0
      counter =
        lambda do |*args|
          sql = args.last[:sql].to_s
          # Count first-post fetches; the batch is one WHERE topic_id IN (...) AND post_number = 1.
          post_queries += 1 if sql.include?("posts") && sql.include?("post_number")
        end

      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
        rows = described_class.inbound("rendlesham-forest")
        expect(rows.size).to eq(5)
      end

      expect(post_queries).to be <= 1
    end
  end

  describe ".schedule_fan_out!" do
    it "enqueues a debounced rebake for each edged target" do
      target = subject_topic!("Rendlesham Forest", "rendlesham-forest")
      source =
        subject_topic!(
          "Orfordness Lighthouse",
          "orfordness-lighthouse",
          "explains: rendlesham-forest",
        )

      Discourse.redis.del("curiobase:rebake:#{target.id}")

      expect_enqueued_with(job: :curiobase_rebake, args: { post_id: target.first_post.id }) do
        described_class.schedule_fan_out!(source)
      end
    end
  end

  describe "card + bake integration" do
    it "shows attribution inbound on the explained subject" do
      subject_topic!("Rendlesham Forest", "rendlesham-forest")
      subject_topic!(
        "Orfordness Lighthouse",
        "orfordness-lighthouse",
        "explains: rendlesham-forest",
      )

      # Rebake target so inbound block lands in cooked (fan-out is debounced;
      # force it for the example).
      target = Topic.find_by(title: "Rendlesham Forest")
      Curiobase.rebake_now!(target.first_post)

      html = target.first_post.reload.cooked
      expect(html).to include("cb-inbound")
      expect(html).to include("Other files point here")
      expect(html).to include("explains this")
      expect(html).to include("Orfordness Lighthouse")
    end

    # ⚠ remember_edges MUST run after every save_custom_fields. Writing edge
    #   rows then letting kind/slug/poster sync wipe them was the silent
    #   production failure for this feature.
    it "keeps curiobase_edge rows after a full rebake that also writes kind/slug" do
      subject_topic!("Rendlesham Forest", "rendlesham-forest")
      source =
        subject_topic!(
          "Orfordness Lighthouse",
          "orfordness-lighthouse",
          "explains: rendlesham-forest",
        )

      edges =
        TopicCustomField
          .where(topic_id: source.id, name: described_class::FIELD)
          .pluck(:value)
      expect(edges).to contain_exactly("explains:rendlesham-forest")

      Curiobase.rebake_now!(source.first_post.reload)
      expect(
        TopicCustomField
          .where(topic_id: source.id, name: described_class::FIELD)
          .pluck(:value),
      ).to contain_exactly("explains:rendlesham-forest")
    end

    it "enqueues the target rebake when a new edge is baked, not on a no-op rebake" do
      target = subject_topic!("Rendlesham Forest", "rendlesham-forest")
      Discourse.redis.del("curiobase:rebake:#{target.id}")

      expect_enqueued_with(job: :curiobase_rebake, args: { post_id: target.first_post.id }) do
        subject_topic!(
          "Orfordness Lighthouse",
          "orfordness-lighthouse",
          "explains: rendlesham-forest",
        )
      end

      source = Topic.find_by(title: "Orfordness Lighthouse")
      Discourse.redis.del("curiobase:rebake:#{target.id}")

      # Same edges again → replace! returns [] → no schedule.
      expect_not_enqueued_with(job: :curiobase_rebake, args: { post_id: target.first_post.id }) do
        Curiobase.rebake_now!(source.first_post.reload)
      end
    end
  end
end
