# frozen_string_literal: true

module Curiobase
  # Whether a member's vote counts in the average.
  #
  # ══════════════════════════════════════════════════════════════════════════
  # ONE VOTE IS ONE VOTE. Every eligible member weighs the same.
  # ══════════════════════════════════════════════════════════════════════════
  #
  # Eligibility is decided here and nowhere else:
  #
  #   * active account
  #   * not suspended / silenced
  #   * trust_level ≥ `curiobase_min_trust_level`
  #
  # Weight is always 1.0 or 0.0 — applied on read, never stored. Votes from
  # accounts that later fall below the floor (or get suspended) stop counting
  # without deleting the cast; they resume when standing recovers.
  module Standing
    ELIGIBLE = 1.0
    INELIGIBLE = 0.0

    def self.weight_for(user_id)
      weights_for([user_id])[user_id.to_i].to_f
    end

    # { user_id => weight }. One query for a whole pairing.
    def self.weights_for(user_ids)
      ids = Array(user_ids).map(&:to_i).uniq
      return {} if ids.empty?

      min_tl = SiteSetting.curiobase_min_trust_level.to_i

      User
        .where(id: ids)
        .pluck(:id, :trust_level, :active, :suspended_till, :silenced_till)
        .to_h do |id, tl, active, suspended_till, silenced_till|
          [id, weight(tl, active, suspended_till, silenced_till, min_tl)]
        end
    end

    def self.weight(tl, active, suspended_till, silenced_till, min_tl)
      return INELIGIBLE unless active
      return INELIGIBLE if suspended_till&.future?
      return INELIGIBLE if silenced_till&.future?
      return INELIGIBLE if tl.to_i < min_tl

      ELIGIBLE
    end
  end
end
