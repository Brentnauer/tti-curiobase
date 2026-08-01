# frozen_string_literal: true

require "rails_helper"

# The spike: a record authored in its own post rather than in a CMS.
RSpec.describe Curiobase::PostRecord do
  def block(body) = "```curiobase\n#{body}\n```\n\nSome prose."

  it "ignores a post that carries no record" do
    expect(described_class.parse("Just a normal reply.")).to be_nil
  end

  it "reads scalars and lists" do
    r = described_class.parse(block(<<~REC))
      type: subject
      slug: rendlesham-forest
      kind: incident
      domain: contact
      status: contested
      period: 1980s
      evidence: firsthand-account, documentary-record
      dek: Three nights in December 1980.
    REC

    expect(r).to be_valid
    expect(r.fields["kind"]).to eq("incident")
    expect(r.fields["period"]).to eq(["1980s"])
    expect(r.fields["evidence"]).to eq(%w[firsthand-account documentary-record])
  end

  # ⚠ AN UNKNOWN KEY IS AN ERROR, NOT SOMETHING TO SKIP. A permissive parser is
  #   exactly what lets a typo save cleanly and render nothing.
  it "reports a key it does not recognise rather than swallowing it" do
    r = described_class.parse(block("type: subject\nslug: x\nkind: idea\ndomain: time\ndek: y\nevidance: no-evidence"))
    expect(r.unknown).to eq(["evidance"])
    expect(r).not_to be_valid
  end

  it "reports what is missing" do
    r = described_class.parse(block("type: subject\nslug: x"))
    expect(r.missing).to contain_exactly("kind", "domain", "dek")
  end

  it "hands back the fixture shape, so nothing downstream can tell the difference" do
    r = described_class.parse(block(<<~REC))
      type: work
      slug: primer-2004
      medium: film
      mode: fiction
      year: 2004
      creator: Shane Carruth
      dek: Two engineers building something in a garage.
    REC

    record = described_class.to_record(r)
    expect(record["type"]).to eq("work")
    expect(record["slug"]).to eq("primer-2004")
    expect(record["year"]).to eq(2004)
    expect(record["creator"]).to eq("Shane Carruth")
  end

  it "tolerates blank lines, comments and stray spacing" do
    r = described_class.parse(block("  type: subject\n\n# a note\n  slug:  x  \nkind: idea\ndomain: time\ndek: y"))
    expect(r).to be_valid
    expect(r.fields["slug"]).to eq("x")
  end
end

# ⚠ This is what replaces the CMS dropdown. Everything it catches is something
#   a select would have made impossible to type.
RSpec.describe Curiobase::RecordValidator do
  def block(body) = "```curiobase\n#{body}\n```"

  def errors(overrides = {})
    fields = {
      "type" => "subject", "slug" => "rendlesham-forest", "kind" => "incident",
      "domain" => "contact", "dek" => "Three nights in December 1980.",
    }.merge(overrides)
    described_class.errors_for(block(fields.map { |k, v| "#{k}: #{v}" }.join("\n")))
  end

  it "passes a good record" do
    expect(errors).to be_empty
  end

  it "names the offending value and the allowed set" do
    e = errors("kind" => "incidnet").first
    expect(e).to include("incidnet")
    expect(e).to include("incident")
  end

  # The underscore-for-hyphen slip, which is the exact shape of the bug this
  # whole validator exists for.
  it "catches a list value that is nearly right" do
    expect(errors("evidence" => "firsthand_account")).not_to be_empty
  end

  it "catches an over-long dek, because the dek is the search snippet" do
    expect(errors("dek" => "x" * 201).first).to include("201")
  end

  it "catches a slug that is not a slug" do
    expect(errors("slug" => "Rendlesham Forest")).not_to be_empty
  end

  it "catches a year that is not a year" do
    expect(errors("type" => "work", "medium" => "film", "year" => "nineteen eighty")).not_to be_empty
  end

  it "says nothing about a post that carries no record" do
    expect(described_class.errors_for("An ordinary post.")).to be_empty
  end
end

# ⚠ THE BUG THIS EXISTS TO PREVENT: /t/rendlesham-forest rendered the post's
#   record while /tag/rendlesham-forest rendered WordPress's, with a different
#   dek, and nothing anywhere said they disagreed. Three places resolved
#   records and only two of them learned about post-authoring.
# ⚠ If writing and reading ever disagree, converting a record silently changes
#   it — and the new value looks exactly as authoritative as the old one.
RSpec.describe Curiobase::RecordWriter do
  it "round-trips a subject without losing anything" do
    record = {
      "type" => "subject", "slug" => "rendlesham-forest", "kind" => "incident",
      "domain" => "contact", "status" => "contested", "dek" => "Three nights in December 1980.",
      "period" => ["1980s"], "evidence" => %w[firsthand-account documentary-record],
      "also_known_as" => "Britain's Roswell", "coords" => "52.08,1.44",
      "facts" => { "began" => "26 December 1980", "where" => "Suffolk" },
    }

    back = Curiobase::PostRecord.to_record(Curiobase::PostRecord.parse(described_class.fence(record)))

    expect(back["kind"]).to eq("incident")
    expect(back["evidence"]).to eq(%w[firsthand-account documentary-record])
    expect(back["facts"]).to eq("began" => "26 December 1980", "where" => "Suffolk")
    expect(back["coords"]).to eq("52.08,1.44")
  end

  it "round-trips a work, external IDs and all" do
    record = {
      "type" => "work", "slug" => "primer-2004", "medium" => "film", "mode" => "fiction",
      "year" => 2004, "creator" => "Shane Carruth", "runtime" => "77 min",
      "dek" => "Two engineers building something in a garage.",
      "external" => { "imdb" => "tt0390384", "tmdb" => "14337" },
    }

    back = Curiobase::PostRecord.to_record(Curiobase::PostRecord.parse(described_class.fence(record)))

    expect(back["year"]).to eq(2004)
    expect(back["external"]).to eq("imdb" => "tt0390384", "tmdb" => "14337")
  end

  # A newline inside a value would end the field and turn the remainder into an
  # unknown key, which the validator would then refuse — so a record that was
  # fine in the CMS would become unconvertible.
  it "flattens a value that would otherwise break the block" do
    fence = described_class.fence(
      { "type" => "subject", "slug" => "x", "kind" => "idea", "domain" => "time",
        "dek" => "One sentence.\nAnd another." },
    )
    expect(Curiobase::PostRecord.parse(fence)).to be_valid
  end

  it "writes nothing for fields the record does not have" do
    fence = described_class.fence(
      { "type" => "subject", "slug" => "x", "kind" => "idea", "domain" => "time", "dek" => "y" },
    )
    expect(fence).not_to include("runtime")
    expect(fence).not_to include("coords")
  end
end

# ══════════════════════════════════════════════════════════════════════════════
# ⚠ THE REGRESSION SUITE FOR THE BUG THAT HAPPENED FIVE TIMES.
#
#   Every one of these is a caller that once knew about wraps and not about
#   post-authored records. Four of them shipped broken. The fifth —
#   TopicRecord — took every Work out of every association list and turned it
#   into "DISCUSSION · 1 reply", while the filter chips above it still read
#   "Film 2 · Books 2" because they came from a different source.
#
#   A sixth caller will be added one day. This is what will catch it.
# ══════════════════════════════════════════════════════════════════════════════
RSpec.describe "Curiobase · every caller understands both authoring formats" do
  fab!(:tag) { Fabricate(:tag, name: "causal-loop") }
  fab!(:group) { Fabricate(:tag_group, name: "Subjects", tags: [tag]) }

  fab!(:subject_topic) { Fabricate(:topic, title: "Causal loops, the whole idea") }
  fab!(:work_topic) { Fabricate(:topic, title: "Primer (2004), the garage film") }
  fab!(:chat_topic) { Fabricate(:topic, title: "Is the bootstrap paradox coherent?") }

  before do
    SiteSetting.curiobase_enabled = true
    SiteSetting.curiobase_subject_tag_group = "Subjects"
    Curiobase::Subjects.reset_cache!

    Fabricate(:post, topic: subject_topic, raw: <<~RAW)
      ```curiobase
      type: subject
      slug: causal-loop
      kind: idea
      domain: time
      dek: An event that is its own cause.
      ```
    RAW

    Fabricate(:post, topic: work_topic, raw: <<~RAW)
      ```curiobase
      type: work
      slug: primer-2004
      medium: film
      mode: fiction
      year: 2004
      dek: Two engineers building something in a garage.
      ```
    RAW

    Fabricate(:post, topic: chat_topic, raw: "Just arguing about it.")

    [subject_topic, work_topic, chat_topic].each { |t| t.tags = [tag] }
    [subject_topic, work_topic].each { |t| Curiobase.rebake_now!(t.first_post) }
  end

  it "TopicRecord recognises a post-authored record" do
    expect(Curiobase::TopicRecord.for(work_topic)).to eq(kind: "work", id: "primer-2004")
    expect(Curiobase::TopicRecord.for(subject_topic)).to eq(kind: "subject", id: "causal-loop")
    expect(Curiobase::TopicRecord.for(chat_topic)).to be_nil
  end

  # This is the exact screenshot bug.
  it "Associations lists a Work as a work, not as a discussion" do
    rows = Curiobase::Associations.new("causal-loop").rows
    work = rows.find { |r| r.title.start_with?("Primer") }

    expect(work.kind).to eq("work")
    expect(work.medium).to eq("film")
  end

  it "Associations never lists the subject's own topic" do
    titles = Curiobase::Associations.new("causal-loop").rows.map(&:title)
    expect(titles).not_to include("Causal loops, the whole idea")
  end

  # Chips read the curiobase_kind cache and rows read TopicRecord. When only one
  # of them understood the new format they disagreed in public.
  it "the chips agree with the rows" do
    assoc = Curiobase::Associations.new("causal-loop")
    from_rows = assoc.rows.count { |r| r.kind == "work" }

    expect(assoc.counts["film"]).to eq(1)
    expect(from_rows).to eq(1)
    expect(assoc.counts["all"]).to eq(assoc.rows.size)
  end

  it "PostKind.first_posts sweeps both formats" do
    ids = Curiobase::PostKind.first_posts.pluck(:topic_id)
    expect(ids).to include(subject_topic.id, work_topic.id)
    expect(ids).not_to include(chat_topic.id)
  end

  it "JsonLd resolves a post-authored record" do
    expect(Curiobase::JsonLd.build(work_topic)["@type"]).to eq("Movie")
  end

  it "Source resolves a post-authored record" do
    expect(Curiobase::Source.work("primer-2004")["medium"]).to eq("film")
  end

  it "RecordTopic points the tag page at the canonical thread" do
    expect(Curiobase::RecordTopic.find("causal-loop")).to eq(subject_topic.id)
  end

  # ⚠ A broken record cannot normally be SAVED — RecordValidator refuses it in
  #   the composer, which is the whole point of that validator. This state
  #   arises the other way round: a record that was valid when written and
  #   became invalid when the vocabulary moved underneath it. It must degrade to
  #   its previous form rather than vanish from every list on the site, so
  #   update_column is the honest way to reproduce it.
  it "falls back to a wrap when the block is present but no longer valid" do
    t = Fabricate(:topic, title: "A record the vocabulary moved under")
    post = Fabricate(:post, topic: t, raw: "[wrap=work id=primer-2004]\n[/wrap]")
    post.update_column(:raw, "```curiobase\ntype: work\nslug: x\n```\n\n[wrap=work id=primer-2004]")

    expect(Curiobase::TopicRecord.for(t.reload)).to eq(kind: "work", id: "primer-2004")
  end
end

RSpec.describe "Curiobase::Source, one door" do
  fab!(:tag) { Fabricate(:tag, name: "causal-loop") }
  fab!(:group) { Fabricate(:tag_group, name: "Subjects", tags: [tag]) }
  fab!(:topic) { Fabricate(:topic, title: "Causal loops, the whole idea") }

  let(:raw) do
    <<~RAW
      ```curiobase
      type: subject
      slug: causal-loop
      kind: idea
      domain: time
      dek: An event that is its own cause, authored in the post.
      ```
    RAW
  end

  before do
    SiteSetting.curiobase_enabled = true
    SiteSetting.curiobase_subject_tag_group = "Subjects"
    Curiobase::Subjects.reset_cache!
    topic.tags = [tag]
  end

  it "serves WordPress until a record is converted" do
    expect(Curiobase::Source.subject("causal-loop")["dek"]).not_to include("authored in the post")
  end

  it "prefers the post the moment one exists" do
    post = Fabricate(:post, topic: topic, raw: raw)
    Curiobase.rebake_now!(post)

    expect(Curiobase::Source.subject("causal-loop")["dek"]).to include("authored in the post")
  end

  # If the card and the banner ask different questions they get different
  # answers, which is precisely what happened.
  it "gives the tag banner the same record the topic rendered" do
    post = Fabricate(:post, topic: topic, raw: raw)
    Curiobase.rebake_now!(post)

    banner = Curiobase::SubjectCard.for_slug("causal-loop", variant: :banner).to_html
    expect(banner).to include("authored in the post")
    expect(post.reload.cooked).to include("authored in the post")
  end

  it "still points the tag page at the canonical thread" do
    post = Fabricate(:post, topic: topic, raw: raw)
    Curiobase.rebake_now!(post)

    expect(Curiobase::RecordTopic.find("causal-loop")).to eq(topic.id)
  end

  it "falls back rather than blowing up when a converted post goes missing" do
    post = Fabricate(:post, topic: topic, raw: raw)
    Curiobase.rebake_now!(post)
    post.destroy!

    expect { Curiobase::Source.subject("causal-loop") }.not_to raise_error
  end
end
