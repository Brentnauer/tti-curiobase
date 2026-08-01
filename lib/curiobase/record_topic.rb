# frozen_string_literal: true

module Curiobase
  # Which topic IS a given record — the reverse of TopicRecord.
  #
  # TopicRecord answers "what record does this topic carry?" by reading the
  # block out of the first post. This answers the opposite, and it is needed
  # because every link to a Subject should land on the Subject's own file rather
  # than on its tag page. 02-IA already says so — *"the file is canonical, the
  # tag page is navigation"* — and the renderer was doing the reverse.
  #
  # ══════════════════════════════════════════════════════════════════════════
  # THE RECORD DESIGNATES ITSELF, AND THE CLAIM IS EXCLUSIVE.
  # ══════════════════════════════════════════════════════════════════════════
  #
  # There is no setting naming the canonical topic, no field on the tag and no
  # list to maintain. A topic becomes the file for `majestic-12` by carrying a
  # record block that says `slug: majestic-12`. That is the designation.
  #
  # ⚠ THIS IS NOT A TAG LOOKUP, and the distinction is the whole design.
  #
  #   Four topics carry the tag `majestic-12` — the file plus three Works that
  #   engage it — and that is exactly what the tag is for. But each of them
  #   claims its OWN slug: Deus Ex claims `deus-ex-2000`. Only the file claims
  #   `majestic-12`. "Which topic is the file" and "which topics are tagged"
  #   are different questions with different answers.
  #
  # ⚠ A CACHE, NOT A SOURCE OF TRUTH, AND IT IS VERIFIED BEFORE IT IS TRUSTED.
  #
  #   The truth is the block in the post. The custom field exists so the lookup
  #   is an indexed equality match instead of a LIKE scan of 125,297 rows on a
  #   route crawlers hammer — but a cache that is trusted blindly is how a stale
  #   claim wins.
  #
  #   Nothing releases the field when a topic stops being a record. Eight stale
  #   claims existed from topics deleted during a rebuild, including one on
  #   `majestic-12` from an old draft with a LOWER id than the real file. It was
  #   invisible only because deleted topics are filtered out — restore that
  #   topic and the tag page silently serves the wrong record.
  #
  #   So the winner is confirmed against its own first post before it is
  #   returned. That makes a stale claim harmless no matter how it arose, which
  #   is worth more than any number of hooks remembering to clean up.
  module RecordTopic
    FIELD = "curiobase_slug"

    def self.register!
      ::Topic.register_custom_field_type(FIELD, :string)
    end

    # ⚠ NEGATIVE ANSWERS EXPIRE FAST, POSITIVE ONES DO NOT.
    #
    #   "This subject has no file" is the answer for most of the spine and it is
    #   worth caching — otherwise every card with six subject rows runs six
    #   misses against the custom-field table on a route crawlers hammer.
    #
    #   But it is also the answer that goes stale the moment somebody writes the
    #   file, and a stale negative is invisible: the card silently keeps linking
    #   to the tag page and nothing anywhere says why. That is exactly what
    #   happened while building the demo set — three subject files were written
    #   and stayed unlinkable, and the only symptom was a URL that looked
    #   slightly wrong.
    #
    #   So: a hit is cached for ten minutes, a miss for one.
    HIT_TTL = 10.minutes
    MISS_TTL = 1.minute
    MISS = -1

    # ⚠ TYPE-SCOPED. Works and Subjects share one slug namespace, so without
    #   this a Work claiming `majestic-12` would be a candidate for the Subject
    #   file. Nothing collides today; nothing prevents it either, and the
    #   failure would be a tag page rendering a film as its own subject.
    def self.find(slug, type: :subject)
      key = slug.to_s
      return nil if key.blank?

      cache_key = "curiobase:record_topic:#{type}:#{key}"
      cached = Discourse.cache.read(cache_key)
      return cached.to_i.positive? ? cached.to_i : nil if cached

      id = lookup(key, type)
      Discourse.cache.write(cache_key, id || MISS, expires_in: id ? HIT_TTL : MISS_TTL)
      id
    end

    # Every LIVE topic whose custom field claims this slug, oldest first.
    # Usually one. More than one is an editorial problem, not a read problem —
    # `curiobase:doctor` names them and RecordValidator refuses the second.
    def self.claimants(slug)
      Topic
        .joins(:_custom_fields)
        .where(topic_custom_fields: { name: FIELD, value: slug.to_s })
        .where(deleted_at: nil, visible: true)
        .order(:id)
        .pluck(:id)
    end

    # { slug => [topic_id, ...] } for every slug more than one LIVE topic claims.
    # Doctor's collision check; not used on any render path.
    def self.claimants_by_slug
      Topic
        .joins(:_custom_fields)
        .where(topic_custom_fields: { name: FIELD })
        .where(deleted_at: nil, visible: true)
        .pluck(Arel.sql("topic_custom_fields.value"), :id)
        .group_by(&:first)
        .transform_values { |pairs| pairs.map(&:last).sort }
        .select { |_slug, ids| ids.size > 1 }
    end

    def self.lookup(key, type = :subject)
      claimants(key).find { |id| really_claims?(id, key, type) }
    end

    # ⚠ THE VERIFICATION. Ask the post, not the index.
    #
    #   `type` comes from the record itself rather than from `curiobase_kind`,
    #   because that field holds a Work's MEDIUM — "book", "game" — and reading
    #   a type out of it means encoding the mapping in a second place.
    #
    # ⚠ THROUGH TopicRecord, WHICH KNOWS BOTH AUTHORING FORMATS.
    #
    #   The first version of this called `PostRecord.parse` directly, so it
    #   understood the fenced block and not the legacy wrap — and a wrap-authored
    #   record would have quietly failed to verify, lost its claim, and dropped
    #   every link to its file back to the tag page. That is the bug that has now
    #   happened six times in this codebase, and this is the sixth: **a check
    #   that only knows one of the two ways a thing can exist.** Four specs
    #   caught it because they still author with wraps.
    #
    #   `TopicRecord.for` is the one reader that understands both. Anything
    #   asking "what record does this topic carry" goes through it.
    def self.really_claims?(topic_id, slug, type)
      topic = Topic.find_by(id: topic_id)
      ref = topic && TopicRecord.for(topic)
      return false unless ref

      ref[:id].to_s == slug.to_s && ref[:kind].to_s == type.to_s
    end

    # ⚠ INVALIDATES UNCONDITIONALLY, even when the field is unchanged.
    #
    #   An earlier version returned early if the custom field already matched,
    #   and skipped the invalidation with it. A rebake then could not clear a
    #   stale entry, which is the one thing a rebake is supposed to fix.
    def self.remember(topic, slug)
      return if topic.blank? || slug.blank?
      forget_cache(slug)
      return if topic.custom_fields[FIELD] == slug
      # The topic's previous claim is being released — clear its cache too, or a
      # renamed slug leaves the old one resolving here for ten more minutes.
      forget_cache(topic.custom_fields[FIELD])
      topic.custom_fields[FIELD] = slug
      topic.save_custom_fields
    end

    def self.forget_cache(slug)
      return if slug.blank?
      %i[subject work].each { |t| Discourse.cache.delete("curiobase:record_topic:#{t}:#{slug}") }
    end

    # Drops a claim a topic no longer backs up. Verification already makes a
    # stale field harmless at read time; this keeps the table honest so that
    # `doctor` reports real collisions rather than archaeology.
    def self.release(topic)
      return if topic.blank?
      slug = topic.custom_fields[FIELD]
      return if slug.blank?
      topic.custom_fields[FIELD] = nil
      topic.save_custom_fields
      forget_cache(slug)
    end

    # /t/<slug>/<id> when the record has a file, /tag/<slug>/<id> when it does
    # not.
    #
    # ⚠ THE FALLBACK IS THE COMMON CASE, not an edge case. The spine is 93
    #   subjects and only a handful have files. A link that 404s or dead-ends
    #   because a record has not been written yet would make the catalogue look
    #   broken during the entire period it is being built.
    #
    # ⚠ Canonical tag URL, with the id. /tag/<slug> works but 301s, and a baked
    #   link that always redirects is a hop on every crawl forever.
    def self.href(slug, tag: nil)
      # ⚠ `topic.relative_url`, not a hand-built "/t/#{slug}/#{id}". Discourse
      #   owns the shape of its own URLs; seven independent interpolations of it
      #   is seven places for one of them to drift.
      if (id = find(slug, type: :subject))
        topic = Topic.select(:id, :slug).find_by(id: id)
        return topic.relative_url if topic
      end

      tag ||= Tag.find_by(name: slug)
      tag ? "/tag/#{tag.name}/#{tag.id}" : "/tag/#{slug}"
    end
  end
end
