# frozen_string_literal: true

module Curiobase
  # Which subjects a topic engages.
  #
  # ⚠ DISCOURSE TAGS ARE THE SOURCE OF TRUTH FOR ASSOCIATIONS.
  #
  # Tagging a work with a subject IS creating the pairing. There is no reply
  # post to compose, no poll markup, nothing to author. The previous design made
  # a pairing a reply carrying a wrap and two [poll] blocks — 23 pairings cost
  # 23 composed replies and 46 hand-written poll definitions.
  #
  # A WordPress relationship field would be a second source of truth and the two
  # would drift within a month.
  #
  # ⚠ VOCABULARY = SUBJECT FILES, NOT A TAG GROUP.
  #
  #   A tag becomes a catalogue Subject by carrying a Subject file
  #   (`type: subject` / `slug: …` baked onto the topic). Ordinary tags stay
  #   ordinary until that file exists — tagging a Work with `funny` creates no
  #   gravity row. Any Discourse tag can become a Subject; nothing has to be
  #   pre-seeded into a Subjects group.
  module Subjects
    CACHE_KEY = "curiobase:vocabulary"
    CACHE_TTL = 5.minutes

    # Every tag on this topic that is a known subject, in a stable order so the
    # cooked HTML does not churn between rebakes for no reason.
    def self.for_topic(topic)
      return [] unless topic
      vocab = vocabulary
      return [] if vocab.empty?
      topic.tags.map(&:name).select { |t| vocab.include?(t) }.sort
    end

    # Slugs that have a live Subject file (kind + slug claim on an open topic).
    #
    # Indexed custom fields only — same bake-time writes as RecordTopic /
    # TopicKind. Stale claims are verified on single-slug lookup elsewhere;
    # this set is the pairing gate and must stay cheap.
    def self.vocabulary
      Discourse.cache.fetch(CACHE_KEY, expires_in: CACHE_TTL) do
        kind = TopicKind::FIELD
        slug = RecordTopic::FIELD
        rows =
          Topic
            .joins(
              "INNER JOIN topic_custom_fields kind_cf
                 ON kind_cf.topic_id = topics.id
                AND kind_cf.name = #{ActiveRecord::Base.connection.quote(kind)}
                AND kind_cf.value = 'subject'",
            )
            .joins(
              "INNER JOIN topic_custom_fields slug_cf
                 ON slug_cf.topic_id = topics.id
                AND slug_cf.name = #{ActiveRecord::Base.connection.quote(slug)}",
            )
            .where(deleted_at: nil, visible: true)
            .where("slug_cf.value IS NOT NULL AND slug_cf.value <> ''")
            .distinct
            .pluck(Arel.sql("slug_cf.value"))
        rows.to_set
      end
    end

    def self.reset_cache!
      Discourse.cache.delete(CACHE_KEY)
    end

    # True when this slug has a Subject file — same fact as vocabulary membership.
    def self.file?(slug)
      vocabulary.include?(slug.to_s)
    end
  end
end
