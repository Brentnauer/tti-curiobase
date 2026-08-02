# frozen_string_literal: true

module Curiobase
  # One pairing's score, as the membership has it.
  #
  # A pairing is (work, subject) and it is created by TAGGING the work's topic
  # in Discourse. Gravity is then what members vote it — how central that
  # subject is to that work, on the published 1–5 anchors.
  #
  # ⚠ Returns nil for a pairing nobody has voted on. That is a normal state and
  #   an invitation, not a defect: the card asks the reader to be the first.
  #
  # ⚠ NOBODY SITS OUTSIDE THE AVERAGE. An earlier version read an "institute"
  #   assessment off the Work and blended it in at a fixed weight of 5. Later
  #   TL/staff ladders did the same more quietly. Every eligible vote now
  #   weighs 1. See Standing / Scores.
  class Gravity
    Reading =
      Struct.new(:display, :voter_count, :distribution, keyword_init: true) do
        def rated? = display.present?
        def voters? = voter_count.to_i.positive?

        # ⚠ One vote drawn as five bars looks like consensus. Below two voters
        #   the number alone is the honest presentation.
        def distributed? = voter_count.to_i >= 2

        # Membership split: real weight on both ends of the scale. Independent
        # of staff `status:` — that is the editorial signal; this is the vote.
        def disagree? = distributed? && Gravity.disagree?(distribution)
      end

    # Low (1–2) and high (4–5) each have at least two votes. Same rule as the
    # Work card's "members disagree" note — one definition for bake + API + JS.
    def self.disagree?(distribution)
      return false unless distribution.is_a?(Array) && distribution.size == 5

      low = distribution[0].to_i + distribution[1].to_i
      high = distribution[3].to_i + distribution[4].to_i
      low >= 2 && high >= 2
    end

    # ══════════════════════════════════════════════════════════════════════════
    # EVERY READ GOES THROUGH `readings`. TWO QUERIES, WHATEVER THE SHAPE.
    # ══════════════════════════════════════════════════════════════════════════
    #
    # There are three call shapes and all three were one-at-a-time:
    #
    #   Associations   many works, ONE subject      — one per row
    #   CardRenderer   one work, many SUBJECTS      — one per row
    #   JsonLd         one work, many SUBJECTS      — one per subject
    #
    # Two batch helpers would have been two implementations of the same thing,
    # so the primitive is keyed by the pairing itself and the three helpers are
    # one line each. `Associations` is the one that scales — a subject with 100
    # works spent 100 queries here.
    #
    # { [work_id, subject] => Reading|nil }
    def self.readings(pairs)
      wanted =
        Array(pairs).filter_map do |work_id, subject|
          w = work_id.to_s
          s = subject.to_s
          [w, s] unless w.blank? || s.blank?
        end.uniq
      return {} if wanted.empty?
      # ⚠ Still returns a key per pairing when voting is off, so a caller cannot
      #   tell "no votes" from "feature disabled" by a missing key and quietly
      #   fall back to a per-row read.
      return wanted.index_with { nil } unless SiteSetting.curiobase_member_voting_enabled

      raws = VoteStore.raw_many(wanted)
      weights = Standing.weights_for(raws.values.flat_map(&:keys).uniq)

      wanted.index_with { |pair| reading_from(raws[pair], weights) }
    rescue StandardError => e
      Rails.logger.warn(
        "[curiobase] votes unavailable for " \
          "#{Array(pairs).first(3).map { |w, s| "#{w}/#{s}" }.join(", ")}: #{e.class}",
      )
      {}
    end

    def self.for(work, subject_slug)
      readings([[work_id(work), subject_slug]])[[work_id(work).to_s, subject_slug.to_s]]
    end

    # Many works, one subject — the association list.
    def self.for_works(work_ids, subject_slug)
      s = subject_slug.to_s
      readings(Array(work_ids).map { |id| [id, s] })
        .each_with_object({}) { |((w, _), reading), out| out[w] = reading }
    end

    # One work, many subjects — a Work card's rows, and its JSON-LD.
    def self.for_subjects(work, subject_slugs)
      w = work_id(work)
      readings(Array(subject_slugs).map { |s| [w, s] })
        .each_with_object({}) { |((_, s), reading), out| out[s] = reading }
    end

    # ⚠ The ONE place raw votes become a Reading. `reading` on the instance is
    #   gone: two implementations of this is how the mean and the bar were once
    #   drawn from different datasets (D-006).
    def self.reading_from(raw, weights)
      return nil if raw.blank?

      display = Scores.blend(votes: VoteStore.weigh(raw, weights))
      return nil if display.nil?

      Reading.new(
        display: display,
        # Counts and the bar are headcounts of cast values. Eligibility (weight
        # 0 vs 1) only affects the mean — suspended / under-floor votes drop
        # out of the average without rewriting history.
        voter_count: raw.size,
        distribution: distribution_of(raw.values),
      )
    end

    def self.distribution_of(values)
      dist = [0, 0, 0, 0, 0]
      values.each { |v| dist[v.to_i - 1] += 1 if Scores::RANGE.cover?(v.to_i) }
      dist
    end

    # ══════════════════════════════════════════════════════════════════════════
    # HOW A WORK IS IDENTIFIED TO THE VOTE STORE. ONE DEFINITION.
    # ══════════════════════════════════════════════════════════════════════════
    #
    # ⚠ SLUG FIRST. A WordPress post id is environment-specific — Primer is 7223
    #   on the live CMS and 123 in the fixtures — and a post-authored record has
    #   no id at all. The slug is the only identifier that exists everywhere and
    #   means the same thing.
    #
    # ⚠ THIS USED TO BE DERIVED IN TWO PLACES AND VOTING BROKE WHEN THEY
    #   DISAGREED.
    #
    #   `Gravity` read `slug || id`. `CardRenderer` baked `data-work` from
    #   `record["id"]` alone. After conversion the records have no id, so the
    #   card rendered `data-work=""` — the attribute the client posts with —
    #   while the score above it still read 3.58, because Gravity was resolving
    #   the same Work by slug. The card looked completely finished and the
    #   button did nothing.
    #
    #   Anything that needs to name a Work to the vote store calls this.
    def self.work_id(record)
      r = record || {}
      r["slug"].presence || r["id"].to_s.presence
    end

  end
end
