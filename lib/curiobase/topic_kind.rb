# frozen_string_literal: true

module Curiobase
  # What a topic IS, cached on the topic itself.
  #
  # ⚠ This is a CACHE, not a source of truth. The truth is the wrap marker in
  #   the first post, read by TopicRecord. This exists so the tag page can
  #   filter a list of topics in SQL.
  #
  #   Without it, `?curiobase=film` would mean parsing every topic's first post
  #   and asking WordPress what medium each record is — an N+1 across the page,
  #   against a remote API, on a route crawlers hit constantly. With it the
  #   filter is one join on a table Discourse already indexes.
  #
  # Written by CardRenderer at bake time, so it cannot drift from what was
  # actually rendered. A topic with no value is an ordinary discussion.
  module TopicKind
    FIELD = "curiobase_kind"

    # Media, plus "subject" for a Subject's own record topic.
    def self.register!
      ::Topic.register_custom_field_type(FIELD, :string)
    end

    # ══════════════════════════════════════════════════════════════════════════
    # ONE DEFINITION OF "A DISCUSSION". THREE PLACES NEED IT.
    # ══════════════════════════════════════════════════════════════════════════
    #
    # `?curiobase=discussion` in plugin.rb, `Associations#counts`, and
    # `Associations#discussion_rows` all have to agree on it, and they are three
    # different queries.
    #
    # ⚠ THEY DISAGREED THE MOMENT THE THIRD ONE CHANGED. `discussion_rows` used
    #   to subtract the record topics it had already loaded; when Works started
    #   being selected by `curiobase_kind`, the Subject's OWN file — which is
    #   tagged with its own slug and carries `kind = "subject"` — stopped being
    #   subtracted and appeared in its own list as a discussion. A record does
    #   not engage itself. Four specs caught it.
    #
    # A discussion is the ABSENCE of a kind, because a thread is the default
    # state of a topic. Defining it as a value would need every medium listed,
    # in three places, forever.
    def self.discussions(scope)
      scope.where(
        "topics.id NOT IN (SELECT topic_id FROM topic_custom_fields WHERE name = ?)",
        FIELD,
      )
    end

    def self.of_kind(scope, value)
      scope.where(
        "topics.id IN (SELECT topic_id FROM topic_custom_fields WHERE name = ? AND value = ?)",
        FIELD,
        value,
      )
    end
  end
end
