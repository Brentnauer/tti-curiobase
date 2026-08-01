# frozen_string_literal: true

module Curiobase
  # What a member's vote is worth.
  #
  # ══════════════════════════════════════════════════════════════════════════
  # ONE PLACE. Every weight in the system is decided here and nowhere else.
  # ══════════════════════════════════════════════════════════════════════════
  #
  #   TL0        0    reads, cannot move a number
  #   TL1        1
  #   TL2        2
  #   TL3        3
  #   TL4        4
  #   staff      5
  #   supporter  +1   additive, capped at 5
  #
  # ⚠ THERE IS NO SEPARATE "INSTITUTE" TERM, and removing it was the point.
  #
  #   An earlier version gave the institute its own weight of 5 on top of the
  #   ladder, so the operator's judgement sat outside the vote and outranked it
  #   permanently. That inverted what gravity is for. Gravity is what the
  #   membership says a work has to do with a subject; the operator votes like
  #   everybody else and their vote weighs 5 because they are staff, not because
  #   they are the institute. One admin vote on a fresh pairing shows that value
  #   because it is the only vote in the average — not because it wins.
  #
  # ⚠ WEIGHT IS APPLIED ON READ, NEVER STORED. Standing changes: people reach
  #   TL2, become supporters, get suspended. Freezing a weight at cast time
  #   leaves the site scored by who people used to be, and re-weighting history
  #   means a migration every time the policy moves.
  #
  # ⚠ WEIGHT 0 IS NOT A REJECTION. A TL0 vote is recorded, and it starts
  #   counting the moment that account reaches TL1 — precisely because the read
  #   happens at display time. Refusing it outright would make a new member's
  #   first act on the site being told no.
  module Standing
    STAFF = 5.0
    SUPPORTER_BONUS = 1.0
    CAP = 5.0

    # ⚠ Convenience for one user. Production always goes through `weights_for`,
    #   because a pairing needs the whole set and one query beats N. Kept
    #   because it is the readable form in specs and in the console, and it
    #   delegates rather than duplicating the ladder.
    def self.weight_for(user_id)
      weights_for([user_id])[user_id.to_i].to_f
    end

    # { user_id => weight }. One query for a whole pairing rather than one per
    # voter — a busy pairing is otherwise N round trips inside a render.
    def self.weights_for(user_ids)
      ids = Array(user_ids).map(&:to_i).uniq
      return {} if ids.empty?

      supporters = supporter_ids(ids)

      User
        .where(id: ids)
        .pluck(:id, :trust_level, :admin, :moderator, :active, :suspended_till, :silenced_till)
        .to_h do |id, tl, admin, mod, active, suspended_till, silenced_till|
          [id, weight(id, tl, admin, mod, active, suspended_till, silenced_till, supporters)]
        end
    end

    def self.weight(id, tl, admin, mod, active, suspended_till, silenced_till, supporters)
      # Standing is present-tense. Suspended, silenced or deactivated accounts
      # keep their votes on record and stop counting while they are out.
      return 0.0 unless active
      return 0.0 if suspended_till&.future?
      return 0.0 if silenced_till&.future?

      base = (admin || mod) ? STAFF : tl.to_i.clamp(0, 4).to_f
      return 0.0 if base.zero?

      base += SUPPORTER_BONUS if supporters.include?(id)
      base.clamp(0.0, CAP)
    end

    # ⚠ Keep the supporter bonus at +1. A supporter at TL3 weighs 4, not 6. If
    #   money moves the number materially the number stops being worth reading,
    #   and every reader who works that out stops trusting the whole catalogue.
    # ⚠ `curiobase_supporter_group` is `type: group`, so this is a group ID and
    #   not a name. It used to be a typed name resolved with
    #   `Group.find_by(name:)`, where a typo or a later rename returned an empty
    #   set — every supporter silently losing their bonus while the setting
    #   still read as configured. A picker cannot produce a name that is not a
    #   group, which is the point.
    def self.supporter_ids(ids)
      group_id = SiteSetting.curiobase_supporter_group.presence
      return Set.new if group_id.blank?

      Set.new(GroupUser.where(group_id: group_id, user_id: ids).pluck(:user_id))
    end
  end
end
