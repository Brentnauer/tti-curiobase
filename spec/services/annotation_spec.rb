# frozen_string_literal: true

require "rails_helper"

RSpec.describe Curiobase::Annotation do
  fab!(:tag) { Fabricate(:tag, name: "causal-loop") }
  fab!(:group) { Fabricate(:tag_group, name: "Subjects", tags: [tag]) }
  fab!(:topic)
  fab!(:op) { Fabricate(:post, topic: topic, raw: "[wrap=work id=123]\n[/wrap]\n\nA post.") }

  before do
    SiteSetting.curiobase_enabled = true
    SiteSetting.curiobase_annotation_enabled = true
    SiteSetting.curiobase_subject_tag_group = "Subjects"
    Curiobase::Subjects.reset_cache!
    topic.tags = [tag]
  end

  describe ".ensure!" do
    it "puts the wiki at post 2" do
      post = described_class.ensure!(topic, kind: "work")
      expect(post.post_number).to eq(2)
      expect(post).to be_wiki
    end

    it "is idempotent — running twice does not make a second one" do
      first = described_class.ensure!(topic, kind: "work")
      expect(described_class.ensure!(topic, kind: "work")).to eq(first)
      expect(topic.reload.posts_count).to eq(2)
    end

    it "does nothing at all when the setting is off" do
      SiteSetting.curiobase_annotation_enabled = false
      expect(described_class.ensure!(topic, kind: "work")).to be_nil
      expect(topic.reload.posts_count).to eq(1)
    end

    # ⚠ TTI owns record threads: the card is post 1 and post 2 is free. If that
    #   is not true here, something was merged in before the record was set up.
    #   Appending the wiki at post 47 would produce a page nobody ever finds —
    #   and this project's entire failure history is things going quietly wrong.
    it "refuses rather than appending when post 2 is somebody's reply" do
      Fabricate(:post, topic: topic, raw: "I have thoughts about this.")

      expect(described_class.ensure!(topic, kind: "work")).to be_nil
      expect(topic.reload.posts_count).to eq(2)
    end

    it "seeds different questions for a work and a subject" do
      work = described_class.seed("work")
      subject_seed = described_class.seed("subject")

      expect(work).to include("Is it worth the time?")
      expect(subject_seed).to include("Where the question stands now")
      expect(work).not_to eq(subject_seed)
    end

    # A blank post stays blank forever. Headings are a form to fill in.
    it "seeds headings, and says the edits are public before anyone types" do
      post = described_class.ensure!(topic, kind: "work")
      expect(post.raw).to include("###")
      expect(post.raw).to include("Every edit is public and kept")
    end
  end

  describe ".written?" do
    it "is false for a seed nobody has touched" do
      expect(described_class).not_to be_written(described_class.ensure!(topic, kind: "work"))
    end

    it "is true once a human has edited it" do
      post = described_class.ensure!(topic, kind: "work")
      post.revise(Fabricate(:user), raw: "It is worth the two hours. The IBM 5100 part is wrong.")
      expect(described_class).to be_written(post.reload)
    end

    it "is false for nil" do
      expect(described_class).not_to be_written(nil)
    end
  end

  describe "auto-ensure on new records" do
    it "seeds the wiki when a fenced record is created and the setting is on" do
      raw = <<~RAW
        ```curiobase
        type: work
        slug: auto-annotate-demo
        medium: film
        mode: fiction
        dek: A film that triggers annotation.
        ```
      RAW
      post = create_post(title: "Auto annotate demo film topic here", raw: raw, tags: [tag.name])

      wiki = described_class.for_topic(post.topic)
      expect(wiki).to be_present
      expect(wiki.post_number).to eq(2)
      expect(wiki).to be_wiki
    end

    it "does not seed when the setting is off" do
      SiteSetting.curiobase_annotation_enabled = false
      raw = <<~RAW
        ```curiobase
        type: work
        slug: no-auto-annotate
        medium: film
        mode: fiction
        dek: Should not get a wiki.
        ```
      RAW
      post = create_post(title: "No auto annotate film topic title xx", raw: raw, tags: [tag.name])

      expect(described_class.for_topic(post.topic)).to be_nil
      expect(post.topic.reload.posts_count).to eq(1)
    end
  end

  describe "rebake when subject tags change" do
    it "schedules a rebake when a subject tag is added via DiscourseTagging" do
      other = Fabricate(:tag, name: "john-titor")
      group.tags = [tag, other]
      group.save!
      Curiobase::Subjects.reset_cache!
      Discourse.redis.del("curiobase:rebake:#{topic.id}")

      expect_enqueued_with(job: :curiobase_rebake, args: { post_id: op.id }) do
        DiscourseTagging.tag_topic_by_names(
          topic,
          Guardian.new(Fabricate(:admin)),
          [tag.name, other.name],
        )
      end
    end

    it "also schedules a rebake of the Subject file whose list membership changed" do
      other = Fabricate(:tag, name: "john-titor")
      group.tags = [tag, other]
      group.save!
      Curiobase::Subjects.reset_cache!

      subject_topic = Fabricate(:topic, title: "John Titor file", user: Fabricate(:admin), tags: [other])
      subject_op =
        Fabricate(
          :post,
          topic: subject_topic,
          user: subject_topic.user,
          raw: <<~RAW,
            ```curiobase
            type: subject
            slug: john-titor
            kind: person
            domain: time
            dek: The screen name behind a series of posts.
            ```
          RAW
        )
      Curiobase.rebake_now!(subject_op)
      Discourse.redis.del("curiobase:rebake:#{topic.id}")
      Discourse.redis.del("curiobase:rebake:#{subject_topic.id}")

      expect_enqueued_with(job: :curiobase_rebake, args: { post_id: subject_op.id }) do
        DiscourseTagging.tag_topic_by_names(
          topic,
          Guardian.new(Fabricate(:admin)),
          [tag.name, other.name],
        )
      end
    end
  end

  describe "the link on the card" do
    def cooked
      Curiobase.rebake_now!(op)
      op.reload.cooked
    end

    # ⚠ Linking readers to an empty skeleton promises content that is not there.
    it "is absent while the wiki is still just the seed" do
      described_class.ensure!(topic, kind: "work")
      expect(cooked).not_to include("cb-notes")
    end

    it "appears once somebody has written in it" do
      post = described_class.ensure!(topic, kind: "work")
      post.revise(Fabricate(:user), raw: "Worth it. Loose on the 5100.")

      html = cooked
      expect(html).to include("cb-notes")
      expect(html).to include("/t/#{topic.slug}/#{topic.id}/2")
    end

    # ⚠ THE ORDER RULE. Discourse builds the meta description from the start of
    #   cooked, and "Community notes" is the least useful sentence a record
    #   could open with.
    it "comes last, after the dek and the assessment" do
      post = described_class.ensure!(topic, kind: "work")
      post.revise(Fabricate(:user), raw: "Worth it.")

      html = cooked
      expect(html.index("cb-notes")).to be > html.index("cb-dek")
      expect(html.index("cb-notes")).to be > html.index("cb-gravity")
    end
  end
end
