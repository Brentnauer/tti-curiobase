# frozen_string_literal: true

module Curiobase
  # The second axis: is this worth your time?
  #
  # ══════════════════════════════════════════════════════════════════════════
  # LIKES ON THE RECORD'S FIRST POST. THAT IS THE WHOLE MECHANISM.
  # ══════════════════════════════════════════════════════════════════════════
  #
  # Gravity says how central a subject is to a work. It cannot say whether the
  # work is any good, and the two come apart constantly — Hangar 10 is a 5 on
  # Rendlesham and holds 14% on Rotten Tomatoes.
  #
  # `posts.like_count` is an indexed integer column that already exists, the
  # heart already means "this is good" to every member, and `max_likes_per_day`
  # is 50 — so there is no budget worth worrying about. No plugin, no endpoint,
  # no schema, and no moderation surface that is ours to run.
  #
  # ⚠ RECOMMEND-ONLY, AND THE ABSENCE OF A DOWNVOTE IS THE DESIGN.
  #
  #   On a catalogue of unresolved questions a downvote measures the audience
  #   rather than the work. A book arguing Rendlesham was a lighthouse collects
  #   downvotes from believers and upvotes from sceptics, and the number that
  #   falls out describes who happened to be reading it.
  #
  #   Discourse's own reactions plugin reaches the same conclusion: the default
  #   `discourse_reactions_excluded_from_like` list is `-1`, `poop`, `angry`,
  #   `roll_eyes` and two dozen more. Negative reactions ship *available* and
  #   *excluded from the score*. Disapproval can be expressed; it never
  #   aggregates into a ranking.
  #
  # ⚠ ZERO RENDERS AS NOTHING, not as "0 recommend". Most works will sit at
  #   nothing for a long time, and a zero printed beside a 5 reads as a verdict
  #   when it is silence. Same rule as the distribution bar.
  module Recommendations
    def self.for_topic(topic)
      return 0 if topic.blank?
      Post.where(topic_id: topic.id, post_number: 1).pick(:like_count).to_i
    end

    # { topic_id => count } for a set of topics, in one query.
    #
    # ⚠ Batched because an association list is up to 25 rows and this would
    #   otherwise be 25 round trips on a page crawlers hit constantly.
    def self.for_topics(topic_ids)
      ids = Array(topic_ids).compact
      return {} if ids.empty?
      Post
        .where(topic_id: ids, post_number: 1)
        .pluck(:topic_id, :like_count)
        .to_h { |tid, n| [tid, n.to_i] }
    end
  end
end
