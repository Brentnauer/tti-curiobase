# frozen_string_literal: true

module Curiobase
  # What record does this topic carry?
  #
  # ══════════════════════════════════════════════════════════════════════════
  # BOTH AUTHORING FORMATS. This is the question, and there is one answer.
  # ══════════════════════════════════════════════════════════════════════════
  #
  # Reads `raw` rather than `cooked` because JSON-LD is built during a request,
  # when cooked may be mid-rebake, and because what the author wrote is the
  # single source of truth for what a topic is.
  #
  # ⚠ THIS ONLY UNDERSTOOD WRAPS, AND IT WAS THE FIFTH TIME.
  #
  #   verify.sh, curiobase:rebake, curiobase:doctor, JsonLd and Source each had
  #   to learn separately that a record can be authored two ways. This was the
  #   last one, and the worst, because Associations is built on it:
  #
  #     record_topics = all_topics.select { |t| TopicRecord.for(t) }
  #
  #   With the wraps gone that selected NOTHING. Every Work fell through into
  #   the discussions bucket and rendered as "DISCUSSION · 1 reply" with no
  #   score, the Subject's own topic appeared in its own association list, and
  #   the filter chips — which read the `curiobase_kind` cache and were
  #   therefore still correct — said "Film 2 · Books 2" above five rows that all
  #   claimed to be discussions.
  #
  #   The lesson is not "remember to update five callers". It is that a
  #   predicate this load-bearing has to be the only one of its kind, and every
  #   caller has to reach it. See PostKind.first_posts and Source.from_post for
  #   the other two halves of the same rule.
  module TopicRecord
    # ⚠ The id is NOT always numeric. Works were once keyed by WordPress post ID
    #   (123), Subjects always by slug because the slug is also the Discourse tag
    #   name. An earlier `id=(\d+)` silently failed on every Subject.
    RE = /\[wrap=(work|subject)\s+id=([\w-]+)\]/i

    def self.for(topic)
      raw = topic&.first_post&.raw
      return nil if raw.blank?

      # A record authored in its own post answers for itself, and answers first
      # — a converted topic may still carry a wrap in older revisions.
      if PostKind.present?(raw)
        result = PostRecord.parse(raw)
        if result&.valid?
          return { kind: result.fields["type"], id: result.fields["slug"] }
        end
        # Present but broken. Fall through to the wrap rather than claiming the
        # topic is not a record at all — a half-edited record should degrade to
        # its previous form, not vanish from every list on the site.
      end

      m = RE.match(raw)
      return nil unless m
      { kind: m[1].downcase, id: m[2] }
    end
  end
end
