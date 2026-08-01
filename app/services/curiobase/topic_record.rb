# frozen_string_literal: true

module Curiobase
  # What record does this topic carry?
  #
  # ⚠ Production authoring is the fenced ```curiobase block. Wraps remain
  #   readable so legacy topics keep resolving until converted; do not add new
  #   wraps. See PostKind.first_posts and Source.from_post.
  module TopicRecord
    # Legacy wrap marker. Prefer the fenced block when both are present.
    RE = /\[wrap=(work|subject)\s+id=([\w-]+)\]/i

    def self.for(topic)
      raw = topic&.first_post&.raw
      return nil if raw.blank?

      # Fenced block answers first — a converted topic may still carry a wrap
      # in older revisions.
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
