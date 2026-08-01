# frozen_string_literal: true

require "rails_helper"

# ══════════════════════════════════════════════════════════════════════════════
# WHICH TOPIC IS THE FILE.
# ══════════════════════════════════════════════════════════════════════════════
#
# Four topics carry the tag `majestic-12` — the file plus three Works that engage
# it. That is what the tag is for. But only one of them claims the SLUG, and the
# lookup is on the claim, never on the tag.
#
# The claim has to be exclusive, because a second claimant means a tag page
# silently serving the wrong record, and there is no tiebreak that is right.
RSpec.describe Curiobase::RecordTopic do
  fab!(:admin) { Fabricate(:admin) }

  fab!(:file) { Fabricate(:topic, title: "Majestic 12, the committee itself") }
  fab!(:work) { Fabricate(:topic, title: "Deus Ex (2000), the Ion Storm game") }

  def block(type:, slug:, extra: "")
    body =
      if type == "subject"
        "type: subject\nslug: #{slug}\nkind: org\ndomain: hidden-history\ndek: A committee of twelve."
      else
        "type: work\nslug: #{slug}\nmedium: game\ndek: Majestic 12 is the antagonist."
      end
    "```curiobase\n#{body}#{extra}\n```"
  end

  before do
    SiteSetting.curiobase_enabled = true
    Fabricate(:post, topic: file, post_number: 1, raw: block(type: "subject", slug: "majestic-12"))
    Fabricate(:post, topic: work, post_number: 1, raw: block(type: "work", slug: "deus-ex-2000"))
    described_class.remember(file, "majestic-12")
    described_class.remember(work, "deus-ex-2000")
  end

  describe "the claim, not the tag" do
    it "resolves the topic whose record claims the slug" do
      expect(described_class.find("majestic-12", type: :subject)).to eq(file.id)
    end

    # ⚠ A Work tagged `majestic-12` claims `deus-ex-2000`, not `majestic-12`.
    #   The tag is the association; the slug is the identity.
    it "does not resolve a Work merely because it carries the Subject's tag" do
      tag = Fabricate(:tag, name: "majestic-12")
      work.tags = [tag]

      expect(described_class.find("majestic-12", type: :subject)).to eq(file.id)
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # BOTH AUTHORING FORMATS. This is the bug that has happened six times.
  # ══════════════════════════════════════════════════════════════════════════
  #
  # Verification was written against the fenced block only, so a wrap-authored
  # record failed to verify, lost its claim, and every link to its file fell
  # back to the tag page — silently, which is how all five previous instances
  # behaved too. `really_claims?` goes through TopicRecord, the one reader that
  # understands both.
  describe "a record still authored with a legacy wrap" do
    let!(:legacy) do
      t = Fabricate(:topic, title: "Rendlesham Forest, three nights in 1980")
      Fabricate(:post, topic: t, post_number: 1, raw: "[wrap=subject id=rendlesham-forest]\n[/wrap]")
      described_class.remember(t, "rendlesham-forest")
      t
    end

    it "still holds its claim" do
      expect(described_class.find("rendlesham-forest", type: :subject)).to eq(legacy.id)
    end

    it "is still type-scoped" do
      expect(described_class.find("rendlesham-forest", type: :work)).to be_nil
    end

    it "still links to its file rather than falling back to the tag page" do
      expect(described_class.href("rendlesham-forest")).to eq("/t/#{legacy.slug}/#{legacy.id}")
    end
  end

  # ⚠ Works and Subjects share ONE slug namespace. Without scoping,
  #   Source.subject("x") and Source.work("x") would be a coin toss.
  describe "type scoping" do
    it "will not answer for a Subject with a Work" do
      expect(described_class.find("deus-ex-2000", type: :subject)).to be_nil
    end

    it "will not answer for a Work with a Subject" do
      expect(described_class.find("majestic-12", type: :work)).to be_nil
    end

    it "keeps Source.subject and Source.work apart" do
      expect(Curiobase::Source.subject("majestic-12")["type"]).to eq("subject")
      expect(Curiobase::Source.work("deus-ex-2000")["type"]).to eq("work")
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # THE ONE THAT WAS REACHABLE IN PRODUCTION.
  # ══════════════════════════════════════════════════════════════════════════
  #
  # Nothing released `curiobase_slug` when a topic stopped being a record, so
  # eight stale claims survived a rebuild — one of them on `majestic-12`, from a
  # deleted draft with a LOWER id than the real file. Lowest-id-won, and deleted
  # topics were the only thing filtering it out. Restore that topic and the tag
  # page flips to the wrong record with no error anywhere.
  describe "a stale claim" do
    let!(:ghost) do
      t = Fabricate(:topic, title: "Majestic 12, an abandoned older draft")
      Fabricate(:post, topic: t, post_number: 1, raw: "Just a thread. No record block at all.")
      t.custom_fields[described_class::FIELD] = "majestic-12"
      t.save_custom_fields
      described_class.forget_cache("majestic-12")
      t
    end

    it "is a claimant on paper" do
      expect(described_class.claimants("majestic-12")).to include(ghost.id, file.id)
    end

    it "cannot win, because the winner is verified against its own post" do
      expect(described_class.find("majestic-12", type: :subject)).to eq(file.id)
    end

    it "is reported by the collision sweep so it can be cleaned up" do
      expect(described_class.claimants_by_slug).to have_key("majestic-12")
    end

    it "is released without touching the real file" do
      described_class.release(ghost)

      expect(described_class.claimants("majestic-12")).to eq([file.id])
      expect(described_class.find("majestic-12", type: :subject)).to eq(file.id)
    end
  end

  # ⚠ Refused in the composer, while somebody is still looking at it — not
  #   discovered later on a tag page serving the wrong file.
  describe "exclusivity at save time" do
    it "refuses a second record claiming a taken slug, and says which topic has it" do
      rival = Fabricate(:topic, title: "Majestic 12, a rival record entirely")
      post = Post.new(topic_id: rival.id, user_id: admin.id, post_number: 1,
                      raw: block(type: "subject", slug: "majestic-12"))

      expect(post).not_to be_valid
      expect(post.errors.full_messages.join).to include("majestic-12").and include(file.title)
    end

    it "lets a Work keep a slug a Subject does not use" do
      other = Fabricate(:topic, title: "Some other game entirely here")
      post = Post.new(topic_id: other.id, user_id: admin.id, post_number: 1,
                      raw: block(type: "work", slug: "half-life-1998"))

      expect(post).to be_valid
    end

    # Editing the file itself must not trip over its own claim.
    it "does not refuse a record for the slug it already owns" do
      post = file.first_post
      post.raw = block(type: "subject", slug: "majestic-12", extra: "\nstatus: debunked")

      expect(post).to be_valid
    end
  end
end
