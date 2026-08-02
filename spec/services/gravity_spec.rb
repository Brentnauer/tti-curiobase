# frozen_string_literal: true

require "rails_helper"

# Gravity is what the membership votes. Nothing sits outside the average.
RSpec.describe Curiobase::Scores do
  describe ".blend" do
    it "is the weighted mean of the votes and nothing else" do
      # ⚠ THE HEADLINE CHANGE. This used to take an `institute:` argument
      #   weighted at 5, so the operator's number outranked the membership by
      #   construction. It votes through the same control now.
      votes = [{ value: 5, weight: 5 }, { value: 1, weight: 1 }]
      expect(described_class.blend(votes: votes)).to eq(4.33)
    end

    it "shows one voter's value exactly, because it is the only vote" do
      # A staff vote on a fresh pairing displays immediately — not because it
      # wins, but because there is nothing else in the average yet.
      expect(described_class.blend(votes: [{ value: 5, weight: 5 }])).to eq(5.0)
    end

    it "moves as the membership arrives" do
      votes = [{ value: 5, weight: 5 }] + Array.new(5) { { value: 1, weight: 1 } }
      expect(described_class.blend(votes: votes)).to eq(3.0)
    end

    it "ignores weight-zero votes entirely, including in the denominator" do
      # A TL0 vote is recorded and counts for nothing. Reaching the denominator
      # would drag the number down while claiming not to.
      votes = [{ value: 4, weight: 1 }, { value: 1, weight: 0 }]
      expect(described_class.blend(votes: votes)).to eq(4.0)
    end

    it "ignores out-of-range values rather than clamping them" do
      votes = [{ value: 4, weight: 1 }, { value: 9, weight: 1 }]
      expect(described_class.blend(votes: votes)).to eq(4.0)
    end

    it "returns nil when there is nothing to average" do
      # Not 0.0, and not 3.0. An absence is not a verdict.
      expect(described_class.blend(votes: [])).to be_nil
      expect(described_class.blend(votes: [{ value: 4, weight: 0 }])).to be_nil
    end

    it "accepts string keys, because JSON hands them over" do
      expect(described_class.blend(votes: [{ "value" => 4, "weight" => 2 }])).to eq(4.0)
    end

    # ⚠ There is no prior any more, and there must not be one again. A pairing
    #   with two votes has two votes; inventing seventeen imaginary ones at 3.0
    #   says something false about how contested it is.
    it "does not shrink a thinly-voted pairing toward the middle" do
      expect(described_class.blend(votes: [{ value: 5, weight: 1 }])).to eq(5.0)
    end
  end

  describe ".rank_key" do
    it "orders by the displayed value, highest first" do
      rows = [[3.0, 0, 10], [4.5, 0, 2], [4.0, 0, 99]]
      expect(rows.sort_by { |d, r, p| described_class.rank_key(d, r, p) }.map(&:first)).to eq([4.5, 4.0, 3.0])
    end

    it "breaks ties on recommendations, then on argument" do
      rows = [[4.0, 1, 90], [4.0, 40, 3], [4.0, 40, 80]]
      expect(rows.sort_by { |d, r, p| described_class.rank_key(d, r, p) }).to eq(
        [[4.0, 40, 80], [4.0, 40, 3], [4.0, 1, 90]],
      )
    end

    it "sorts unrated last without dropping it" do
      rows = [[nil, 0, 500], [1.0, 0, 1]]
      expect(rows.sort_by { |d, r, p| described_class.rank_key(d, r, p) }.first).to eq([1.0, 0, 1])
    end
  end
end

RSpec.describe Curiobase::Standing do
  fab!(:tl1) { Fabricate(:user, trust_level: TrustLevel[1]) }
  fab!(:tl3) { Fabricate(:user, trust_level: TrustLevel[3]) }
  fab!(:tl0) { Fabricate(:user, trust_level: TrustLevel[0]) }
  fab!(:admin)

  before { SiteSetting.curiobase_min_trust_level = 1 }

  it "gives every eligible member weight 1" do
    expect(described_class.weight_for(tl1.id)).to eq(1.0)
    expect(described_class.weight_for(tl3.id)).to eq(1.0)
    expect(described_class.weight_for(admin.id)).to eq(1.0)
  end

  # Recorded, counts for nothing until the account meets the floor — because
  # weight is read at display time, not cast time.
  it "gives under-floor accounts weight zero rather than refusing the vote" do
    expect(described_class.weight_for(tl0.id)).to eq(0.0)
  end

  it "respects a raised min trust level" do
    SiteSetting.curiobase_min_trust_level = 3
    expect(described_class.weight_for(tl1.id)).to eq(0.0)
    expect(described_class.weight_for(tl3.id)).to eq(1.0)
  end

  # Standing is present-tense: a vote stops counting while its owner is out.
  it "drops to zero while an account is suspended or silenced" do
    tl3.update!(suspended_till: 1.week.from_now, suspended_at: Time.now)
    expect(described_class.weight_for(tl3.id)).to eq(0.0)

    tl1.update!(silenced_till: 1.week.from_now)
    expect(described_class.weight_for(tl1.id)).to eq(0.0)
  end

  it "weighs a whole pairing in one query" do
    expect(described_class.weights_for([tl1.id, tl3.id, admin.id])).to eq(
      tl1.id => 1.0,
      tl3.id => 1.0,
      admin.id => 1.0,
    )
  end
end

RSpec.describe Curiobase::VoteStore do
  fab!(:voter) { Fabricate(:user, trust_level: TrustLevel[2]) }
  fab!(:other) { Fabricate(:user, trust_level: TrustLevel[1]) }

  let(:pairing) { { work_id: "primer-2004", subject: "causal-loop" } }

  it "stores a vote and reads it back" do
    described_class.cast(**pairing, user_id: voter.id, value: 4)
    expect(described_class.for_user(**pairing, user_id: voter.id)).to eq(4)
  end

  # Changing your mind is not a new data point.
  it "replaces rather than accumulating" do
    described_class.cast(**pairing, user_id: voter.id, value: 1)
    described_class.cast(**pairing, user_id: voter.id, value: 5)

    expect(described_class.raw(**pairing)).to eq(voter.id => 5)
  end

  it "keeps voters apart" do
    described_class.cast(**pairing, user_id: voter.id, value: 2)
    described_class.cast(**pairing, user_id: other.id, value: 5)

    expect(described_class.raw(**pairing)).to eq(voter.id => 2, other.id => 5)
  end

  it "keeps pairings apart, so a work is scored per subject" do
    described_class.cast(**pairing, user_id: voter.id, value: 5)
    described_class.cast(work_id: "primer-2004", subject: "john-titor", user_id: voter.id, value: 1)

    expect(described_class.raw(**pairing)).to eq(voter.id => 5)
    expect(described_class.raw(work_id: "primer-2004", subject: "john-titor")).to eq(voter.id => 1)
  end

  it "refuses a value off the scale" do
    expect { described_class.cast(**pairing, user_id: voter.id, value: 9) }.to raise_error(ArgumentError)
  end

  it "attaches eligibility on read, never storing a weight" do
    described_class.cast(**pairing, user_id: voter.id, value: 4)
    expect(described_class.weighted_votes(**pairing)).to eq([{ value: 4, weight: 1.0 }])

    SiteSetting.curiobase_min_trust_level = 3
    expect(described_class.weighted_votes(**pairing)).to eq([])
  ensure
    SiteSetting.curiobase_min_trust_level = 1
  end

  # ⚠ "I no longer have a view" is a different statement from "I think it is a
  #   3". A scale with no way out forces the second when somebody means the
  #   first, which quietly inflates every pairing anyone ever changed their mind
  #   about.
  describe "retracting" do
    it "removes only the caller's vote" do
      described_class.cast(**pairing, user_id: voter.id, value: 5)
      described_class.cast(**pairing, user_id: other.id, value: 2)

      expect(described_class.retract(**pairing, user_id: voter.id)).to be true
      expect(described_class.raw(**pairing)).to eq(other.id => 2)
    end

    it "leaves no row behind when the last vote goes" do
      described_class.cast(**pairing, user_id: voter.id, value: 5)
      described_class.retract(**pairing, user_id: voter.id)

      expect(described_class.raw(**pairing)).to eq({})
      # Otherwise the store fills with keys holding {} and the deletion sweep
      # has more to walk every year.
      expect(PluginStore.get("curiobase", described_class.key(*pairing.values))).to be_nil
    end

    it "is a no-op for someone who never voted" do
      expect(described_class.retract(**pairing, user_id: voter.id)).to be false
    end
  end

  # ⚠ PluginStore has no foreign key. Without the sweep a deleted account goes
  #   on scoring every pairing it ever rated, forever, invisibly.
  it "forgets a deleted member's votes" do
    described_class.cast(**pairing, user_id: voter.id, value: 5)
    described_class.cast(**pairing, user_id: other.id, value: 1)

    described_class.forget_user(voter.id)

    expect(described_class.raw(**pairing)).to eq(other.id => 1)
  end
end

RSpec.describe Curiobase::Gravity do
  fab!(:staff) { Fabricate(:admin) }
  fab!(:member) { Fabricate(:user, trust_level: TrustLevel[1]) }

  let(:work) { { "slug" => "primer-2004", "mode" => "fiction" } }

  before { SiteSetting.curiobase_member_voting_enabled = true }

  def vote(user, value, subject: "causal-loop")
    Curiobase::VoteStore.cast(work_id: "primer-2004", subject: subject, user_id: user.id, value: value)
  end

  it "returns nil for a pairing nobody has voted on" do
    expect(described_class.for(work, "causal-loop")).to be_nil
  end

  it "shows a lone staff vote at its own value" do
    vote(staff, 5)
    r = described_class.for(work, "causal-loop")
    expect(r.display).to eq(5.0)
    expect(r.voter_count).to eq(1)
  end

  it "moves when a member disagrees, as an equal partner" do
    vote(staff, 5)
    vote(member, 1)
    expect(described_class.for(work, "causal-loop").display).to eq(3.0)
  end

  # ⚠ One vote drawn as five bars looks like consensus.
  it "draws no distribution below two voters" do
    vote(staff, 5)
    expect(described_class.for(work, "causal-loop")).not_to be_distributed
  end

  it "builds the distribution as a headcount, so disagreement stays visible" do
    vote(staff, 5)
    vote(member, 1)

    r = described_class.for(work, "causal-loop")
    expect(r).to be_distributed
    expect(r.distribution).to eq([1, 0, 0, 0, 1])
    expect(r.voter_count).to eq(2)
    expect(r.display).to eq(3.0)
  end

  it "scores each pairing separately" do
    vote(staff, 5, subject: "causal-loop")
    vote(staff, 2, subject: "john-titor")

    expect(described_class.for(work, "causal-loop").display).to eq(5.0)
    expect(described_class.for(work, "john-titor").display).to eq(2.0)
  end

  it "returns nil when every vote weighs nothing" do
    vote(Fabricate(:user, trust_level: TrustLevel[0]), 5)
    expect(described_class.for(work, "causal-loop")).to be_nil
  end

  # ⚠ With voting off there is no other source for the number — it is not an
  #   optional layer over an editorial score any more.
  it "has no score at all when voting is switched off" do
    vote(staff, 5)
    SiteSetting.curiobase_member_voting_enabled = false
    expect(described_class.for(work, "causal-loop")).to be_nil
  end
end
