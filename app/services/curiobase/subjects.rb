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

    # The synced vocabulary — the tag group mirroring WordPress subjects.
    #
    # A tag outside it is an ordinary tag: adding `funny` to a topic creates no
    # rating row and no association.
    def self.vocabulary
      Discourse.cache.fetch(CACHE_KEY, expires_in: CACHE_TTL) do
        group = TagGroup.find_by(name: SiteSetting.curiobase_subject_tag_group)
        group ? group.tags.pluck(:name).to_set : Set.new
      end
    end

    def self.reset_cache!
      Discourse.cache.delete(CACHE_KEY)
    end
  end
end
