# frozen_string_literal: true

require "rails_helper"

RSpec.describe Curiobase::CardRenderer do
  fab!(:tag) { Fabricate(:tag, name: "causal-loop") }
  fab!(:noise) { Fabricate(:tag, name: "funny") }
  fab!(:topic)
  fab!(:post) { Fabricate(:post, topic: topic, raw: "[wrap=work id=123]\n[/wrap]\n\nA post.") }

  before do
    SiteSetting.curiobase_enabled = true
    claim_subject_file!("causal-loop")
    topic.tags = [tag, noise]
  end

  # ⚠ REGRESSION. rebake! only ENQUEUES Jobs::ProcessPost, and it is that job
  #   which fires :post_process_cooked. Outside the running server nothing picks
  #   it up, so a rake task calling rebake! stripped the card out and never put
  #   it back — quietly making every record worse.
  def rebake
    Curiobase.rebake_now!(post)
    post.reload.cooked
  end

  it "bakes the card into cooked, not into raw" do
    expect(rebake).to include("curiobase-card")
    expect(post.raw).to include("[wrap=work id=123]")
    expect(post.raw).not_to include("curiobase-card")
  end

  # Discourse builds the meta description from the START of cooked. This has
  # regressed twice: once producing "Medium Film Year 2004 Creator Shane
  # Carruth" and once, from a recovered document, "**** * CONFIDENTIAL * ****".
  it "puts the dek before the fact row" do
    cooked = rebake
    expect(cooked.index("cb-dek")).to be < cooked.index("cb-meta")
  end

  # Empty poster tiles still carry a "FILM · YEAR" label — that text must not
  # lead the meta description.
  it "puts the dek before the poster column in the DOM" do
    cooked = rebake
    expect(cooked.index("cb-dek")).to be < cooked.index("cb-poster")
  end

  # Discourse ExcerptParser uses only `div.excerpt` for topics.excerpt / meta.
  it "wraps the dek so the topic excerpt stops before badges" do
    cooked = rebake
    expect(cooked).to include('class="excerpt"')
    excerpt = PrettyText.excerpt(cooked, 500, strip_links: true, strip_images: true)
    plain = ExcerptParser.to_plain_text(excerpt).to_s
    expect(plain.downcase).to include("engineer") # primer fixture dek
    expect(plain.downcase).not_to include("fiction")
    expect(plain.downcase).not_to match(/\Afilm\b/)
  end

  it "renders a row for a subject tag" do
    expect(rebake).to include('data-subject="causal-loop"')
  end

  # ══════════════════════════════════════════════════════════════════════════
  # The score. Gravity is what members vote — nothing sits outside the average.
  # ══════════════════════════════════════════════════════════════════════════

  def vote(user, value, subject: "causal-loop")
    Curiobase::VoteStore.cast(work_id: "primer-2004", subject: subject, user_id: user.id, value: value)
  end

  it "invites a vote when nobody has rated the pairing" do
    cooked = rebake
    expect(cooked).to include("cb-unrated")
    expect(cooked).to include("—")
    expect(cooked).to include("No rating yet")
  end

  it "shows a lone vote at its own value, with no bar" do
    vote(Fabricate(:admin), 5)
    cooked = rebake

    expect(cooked).to include('<span class="cb-mean">5.0</span>')
    # ⚠ One vote drawn as five segments looks like consensus.
    expect(cooked).not_to include("cb-dist")
  end

  it "draws the split once there is something to disagree about" do
    vote(Fabricate(:admin), 5)
    vote(Fabricate(:user, trust_level: TrustLevel[1]), 1)

    cooked = rebake
    expect(cooked).to include("cb-dist")
    # The count sits against the BAR (headcount). The number is the mean of
    # the same eligible votes.
    expect(cooked).to include("2 votes")
  end

  # ⚠ The second axis. Gravity says how central the subject is; this says
  #   whether the work is worth the time. They come apart constantly.
  describe "the recommendation count" do
    it "shows nothing at all when nobody has recommended it" do
      # "0 recommend" reads as a verdict when it is silence.
      expect(rebake).not_to include("cb-recommend")
    end

    it "counts likes on the record's own first post" do
      post.update!(like_count: 12)
      cooked = rebake
      expect(cooked).to include("cb-recommend")
      expect(cooked).to include("12 members recommend this")
    end

    # Gravity is a property of the pairing; worth is a property of the work.
    # Repeating it per subject row would imply it changed per subject.
    it "appears once, not once per subject row" do
      another = Fabricate(:tag, name: "john-titor")
      claim_subject_file!("john-titor")
      topic.tags = [tag, another]
      post.update!(like_count: 3)

      cooked = rebake
      expect(cooked.scan("cb-row").size).to be >= 2
      expect(cooked.scan("cb-recommend").size).to eq(1)
    end
  end

  describe "the anchors line" do
    it "uses the fiction wording for a film" do
      expect(rebake).to include("load-bearing")
    end

    # ⚠ A government report does not "load-bear" an incident, it investigates
    #   one. Same scale, same numbers, different words.
    it "uses the nonfiction wording for a nonfiction work" do
      post.update!(raw: "[wrap=work id=128]\n[/wrap]")
      titor = Fabricate(:tag, name: "john-titor")
      claim_subject_file!("john-titor")
      topic.tags = [titor]

      cooked = rebake
      expect(cooked).to include("an investigation")
      expect(cooked).not_to include("load-bearing")
    end

    # The client reads this to label its buttons with the same words.
    it "publishes the mode on the block so the control can match it" do
      expect(rebake).to include('data-mode="fiction"')
    end
  end

  # ⚠ 02-IA: "the file is canonical, the tag page is navigation." The renderer
  #   was doing the reverse — every Work card funnelled its internal links into
  #   tag pages while the files, which are the product, received none.
  describe "where a subject row links" do
    it "goes to the Subject's own file when one exists" do
      file = Fabricate(:topic, title: "Causal loops, the whole idea")
      file_post = Fabricate(:post, topic: file, raw: "[wrap=subject id=causal-loop]\n[/wrap]")
      Curiobase.rebake_now!(file_post)

      expect(rebake).to include("/t/#{file.reload.slug}/#{file.id}")
    end

    # ⚠ The common case, not an edge case. The spine is 93 subjects and only a
    #   handful have files — a link that dead-ended until someone wrote the
    #   record would make the catalogue look broken while it is being built.
    it "falls back to the canonical tag URL when the Subject has no file" do
      expect(rebake).to include("/tag/causal-loop/#{tag.id}")
    end

    # ⚠ THE BUG THAT ATE THREE SUBJECT FILES. "No file yet" is cached, because
    #   it is the answer for most of the spine. Writing the file then left the
    #   card silently linking to the tag page, and the only symptom was a URL
    #   that looked slightly off.
    it "stops linking to the tag page as soon as the file is baked" do
      expect(rebake).to include("/tag/causal-loop/#{tag.id}")

      file = Fabricate(:topic, title: "Causal loops, the whole idea")
      Curiobase.rebake_now!(
        Fabricate(:post, topic: file, raw: "[wrap=subject id=causal-loop]\n[/wrap]"),
      )

      expect(rebake).to include("/t/#{file.reload.slug}/#{file.id}")
    end
  end

  it "ignores a tag outside the vocabulary" do
    expect(rebake).not_to include("funny")
  end

  # cooked is ONE blob shared by every reader and cached for months. Anything
  # user-specific baked into it is wrong for everybody but one person.
  it "bakes no user-specific state" do
    cooked = rebake
    expect(cooked).to include("cb-vote")
    expect(cooked).not_to include("your_value")
    expect(cooked).not_to include("mine")
    expect(cooked).not_to include("is-on")
  end

  # ⚠ Voting is now the only source of the number, so switching it off does not
  #   fall back to an editorial score — it removes the score. No control, no
  #   mount point: an empty div is a promise of a widget that never arrives.
  it "bakes no mount point and no score when voting is switched off" do
    SiteSetting.curiobase_member_voting_enabled = false
    cooked = rebake
    expect(cooked).not_to include("cb-vote")
    expect(cooked).not_to include("cb-mean")
  end

  # CookedPostProcessor re-cooks from raw every time, so injection cannot
  # accumulate. Counting ELEMENTS, not string matches — the class attribute is
  # "curiobase-card curiobase-card--work", so a naive scan finds two of them in
  # a single correct card.
  it "is idempotent across rebakes" do
    2.times do
      expect(Nokogiri::HTML5.fragment(rebake).css(".curiobase-card").size).to eq(1)
    end
  end
end
