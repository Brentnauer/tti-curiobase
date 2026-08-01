# frozen_string_literal: true

module Curiobase
  # The community's half of a record: post 2, a wiki.
  #
  # ══════════════════════════════════════════════════════════════════════════
  # POST 1 IS THE INSTITUTE'S. POST 2 IS EVERYONE ELSE'S.
  # ══════════════════════════════════════════════════════════════════════════
  #
  # Gravity measures how central a subject is to a work. It cannot say whether
  # the work is any good, and the two genuinely come apart — the Why Files
  # episode on John Titor is a 5 on centrality and a qualified recommendation.
  # A bare 5 reads as an endorsement it has not earned.
  #
  # Two rejected answers, both for the same reason:
  #
  #   * an editorial "verdict" sentence per record
  #   * a `reliability` badge — primary / popular / unreliable
  #
  # Both are per-item decisions by one operator who cannot have read, watched
  # and played everything in the catalogue, and being confidently wrong about a
  # source's standing on a site about contested subjects is worse than silence.
  #
  # So the interpretation belongs to the people who actually consumed the thing,
  # and Discourse already has the primitive: a wiki post. Editable above a trust
  # threshold, full revision history, rollback, staff lock. Nothing to build and
  # nothing to moderate that Discourse does not already moderate.
  #
  # ⚠ POSITIONAL, AND THAT IS SAFE BECAUSE TTI OWNS THE THREAD.
  #
  #   Record threads are created by the institute, or duplicates are merged into
  #   one that is. The card is always post 1 and post 2 is always free. An
  #   earlier draft of this designated the annotation by a custom field to
  #   survive being retrofitted onto a 28-year-old thread where post 2 is a
  #   reply from 2003 — that case does not exist, and the indirection was
  #   complexity bought against an imaginary requirement.
  #
  #   Merging is still safe AFTER this exists: merged posts append at the end.
  #   Merging into a record thread that has no annotation yet would take slot 2,
  #   which is why `ensure!` refuses rather than appending — see below.
  module Annotation
    FIELD = "curiobase_annotation"
    POSITION = 2

    def self.register!
      ::Post.register_custom_field_type(FIELD, :boolean)
    end

    def self.for_topic(topic)
      return nil if topic.blank?
      post = Post.find_by(topic_id: topic.id, post_number: POSITION)
      post&.custom_fields&.[](FIELD) ? post : nil
    end

    # True once a human has actually written something. The seed does not count.
    #
    # ⚠ The card links to this ONLY when it is true. Linking readers to an empty
    #   skeleton is a promise of content that is not there — the same reason the
    #   rating control bakes no mount point when voting is closed.
    def self.written?(post)
      post.present? && post.version.to_i > 1
    end

    # Creates post 2 as a wiki. Returns the post, or nil if it refused.
    def self.ensure!(topic, kind:)
      return nil unless SiteSetting.curiobase_annotation_enabled
      return nil if topic.blank?

      existing = for_topic(topic)
      return existing if existing

      # ⚠ REFUSE, DO NOT APPEND.
      #
      #   If slot 2 is already taken, the invariant this depends on has been
      #   broken — most likely a topic was merged in before the record was set
      #   up. Quietly appending the annotation at post 47 would produce a wiki
      #   nobody ever finds, in a system whose whole failure mode so far has
      #   been things going silently wrong. Say so and let a human look.
      if Post.exists?(topic_id: topic.id, post_number: POSITION)
        Rails.logger.warn(
          "[curiobase] #{topic.slug}/#{topic.id}: post 2 is not an annotation, refusing to append",
        )
        return nil
      end

      post =
        PostCreator.create!(
          Discourse.system_user,
          topic_id: topic.id,
          raw: seed(kind),
          skip_validations: true,
          bypass_bump: true,
        )

      post.custom_fields[FIELD] = true
      post.save_custom_fields
      post.revise(Discourse.system_user, { wiki: true }, skip_revision: true, skip_validations: true)
      post
    end

    # ⚠ SEEDED, NOT BLANK. An empty post is blank-page terror and stays empty
    #   forever. Headings are a form to fill in, and the difference between the
    #   two is most of whether this feature works at all.
    def self.seed(kind)
      I18n.t("curiobase.annotation.seed.#{kind == "work" ? "work" : "subject"}")
    end
  end
end
