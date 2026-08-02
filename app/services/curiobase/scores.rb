# frozen_string_literal: true

module Curiobase
  module Scores
    RANGE = (1..5)

    # ══════════════════════════════════════════════════════════════════════════
    # GRAVITY IS WHAT THE MEMBERSHIP SAYS. Nothing sits outside the vote.
    # ══════════════════════════════════════════════════════════════════════════
    #
    #   display = Σ wᵢ·voteᵢ / Σ wᵢ
    #
    # Weights come from Standing — 1.0 for every eligible member, 0.0 otherwise.
    # One vote is one vote.
    #
    # ⚠ TWO THINGS USED TO SIT OUTSIDE THIS AVERAGE AND BOTH WERE WRONG.
    #
    #   First a Bayesian shrinkage: C = 5 imaginary votes at a global mean of
    #   3.0, pulling every young pairing toward the middle. Correct for IMDb,
    #   which has millions of voters and needs to stop four ratings topping the
    #   chart. Wrong here, where a pairing with three votes has three votes and
    #   inventing seventeen more says something false about how contested it is.
    #
    #   Then an "institute" term (and later TL/staff ladders) so some accounts
    #   outranked others by construction. Gravity is what the membership says;
    #   the operator votes like everyone else.
    #
    #   The visible behaviour of one-admin-vote is identical either way — the
    #   number shows immediately, because it is the only vote in the average.
    #   What changed is what happens when the tenth member votes.
    #
    # ⚠ DO NOT ADD A PRIOR BACK. If a pairing with two votes looks
    #   overconfident, that is true and worth showing: two voters is what the
    #   distribution and the count are for. Shrinking it toward 3.0 hides a real
    #   fact behind a fake one.
    def self.blend(votes: [])
      weighted = 0.0
      total = 0.0

      Array(votes).each do |v|
        value = v[:value] || v["value"]
        weight = (v[:weight] || v["weight"]).to_f
        next unless RANGE.cover?(value.to_i)
        # Weight 0 is how a TL0 account participates: recorded, counts for
        # nothing. Skipping it here keeps it out of the denominator too.
        next unless weight.positive?
        weighted += value.to_f * weight
        total += weight
      end

      return nil if total.zero?
      (weighted / total).round(2)
    end

    # Sort key for association lists — best first.
    #
    #   1. what the membership scored it
    #   2. how many members recommend it
    #   3. how much the forum argued about it
    #
    # ⚠ GRAVITY IS PRIMARY AND THE OTHERS ONLY BREAK TIES. Deliberately not a
    #   blended score: a widely-liked 3 must not outrank an unloved 5, because
    #   the two measure different things. Centrality is what the list is
    #   ordered by; recommendation is what settles a draw.
    #
    # ⚠ Ranking on the SAME numbers that are displayed. A hidden rank that
    #   disagrees with the visible score makes the list look broken.
    def self.rank_key(display, recommendations = 0, posts_count = 0)
      [-(display || 0).to_f, -recommendations.to_i, -posts_count.to_i]
    end
  end
end
