# frozen_string_literal: true

require "rails_helper"

RSpec.describe Curiobase::SubjectEdges do
  fab!(:group) { Fabricate(:tag_group, name: "Subjects") }
  fab!(:rendlesham_tag) { Fabricate(:tag, name: "rendlesham-forest") }
  fab!(:orford_tag) { Fabricate(:tag, name: "orfordness-lighthouse") }

  before do
    SiteSetting.curiobase_enabled = true
    SiteSetting.curiobase_subject_tag_group = "Subjects"
    TagGroupMembership.create!(tag: rendlesham_tag, tag_group: group)
    TagGroupMembership.create!(tag: orford_tag, tag_group: group)
    Curiobase::Subjects.reset_cache!
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
  end
end
