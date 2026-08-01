# frozen_string_literal: true

module Curiobase
  # Everything that engages a Subject.
  #
  # ⚠ THE DISCUSSIONS HALF IS FREE.
  #
  #   Discourse already knows every topic carrying a tag, going back 28 years.
  #   A Subject's association list is therefore mostly real data that costs one
  #   query and needs nothing from WordPress — and on an old forum it is usually
  #   the largest and oldest part of the list.
  #
  #   Works come from Source (WordPress, or fixtures until it exists).
  #   Discussions come from Discourse. Nothing is duplicated between them.
  class Associations
    # ══════════════════════════════════════════════════════════════════════════
    # TOP N PER BUCKET, AND THE BUCKETS ARE RANKED SEPARATELY.
    # ══════════════════════════════════════════════════════════════════════════
    #
    # ⚠ THE OLD SHAPE RANKED A RECENCY WINDOW, WHICH IS NOT A RANKING.
    #
    #   `all_topics` was `ORDER BY bumped_at DESC LIMIT 75` and the gravity sort
    #   ran in Ruby afterwards, so the window decided what was eligible and the
    #   ranking only sorted the survivors. Measured on a synthetic subject with
    #   100 works and 60 recently-bumped threads: **15 works survived, 2–3 per
    #   medium.** Filtering to books gave three rows out of seventeen. A
    #   five-star film nobody had replied to since 2019 was not ranked low — it
    #   never entered the list.
    #
    #   Discussions and Works need opposite treatment and that is the whole fix:
    #
    #     Discussions rank by `bumped_at`, which IS an indexed SQL sort. So they
    #     are ordered and limited in SQL and cost O(PER_BUCKET) at any scale.
    #
    #     Works rank by gravity, which lives in PluginStore and cannot be sorted
    #     in SQL at all. So every Work for the subject is loaded and ranked in
    #     Ruby — bounded by works-per-subject, a number the operator controls,
    #     rather than by tagged topics, which the archive controls.
    PER_BUCKET = 10

    # ⚠ How many Works may be loaded to rank them. Not a display cap — a refusal
    #   to melt on a pathological subject. Above this the list is still correct
    #   for the newest N and `truncated?` still tells the reader there is more;
    #   the "view all" exit is the honest answer at that size. If a real subject
    #   ever passes this, the fix is caching the display value on the topic so
    #   the ranking becomes an indexed SQL sort — not raising this number.
    MAX_RANKED_WORKS = 300

    Row =
      Struct.new(
        :kind,
        :title,
        :url,
        :medium,
        :mode,
        :poster, # cached URL, or nil — a thumbnail on the row, never fetched

        :gravity, # Curiobase::Gravity::Reading, or nil
        :recommendations, # likes on the record's first post
        :posts_count,
        :replies,
        :buckets, # which filter chips this row is a top-N member of
        keyword_init: true,
      )

    def initialize(subject_slug)
      @slug = subject_slug.to_s
    end

    # ══════════════════════════════════════════════════════════════════════════
    # THE UNION OF EVERY BUCKET'S TOP TEN, EACH ROW LABELLED WITH ITS BUCKETS.
    # ══════════════════════════════════════════════════════════════════════════
    #
    # The card is BAKED, so every filter state has to already be in the HTML —
    # there is no request to make when a chip is clicked. So this renders the
    # top ten for `all` plus the top ten for each medium present, deduped, and
    # `Row#buckets` says which chips each row belongs to.
    #
    # ⚠ A row can be #14 overall and #3 among books. Filtering on `data-kind`
    #   alone — matching a row's medium — would show it under "Book" but a row
    #   that is #11 among books would show too, because medium is not rank.
    #   Membership is the fact; the medium is not.
    #
    # ⚠ Unassessed Works sort LAST, not at zero and not at 3.0. `rank_key` sends
    #   a nil display to -0.0, which puts them below every assessed row but above
    #   nothing — they are still in the list, still clickable, still findable.
    #   Dropping them would hide the catalogue's own gaps from the only person
    #   who can fill them.
    def rows
      @rows ||= begin
        ranked = work_rows.sort_by { |r| Scores.rank_key(r.gravity&.display, r.recommendations, r.posts_count) }

        keep = {} # Row => Set of bucket names, insertion-ordered
        ranked.first(PER_BUCKET).each { |r| (keep[r] ||= []) << "all" }
        ranked.group_by { |r| r.medium.to_s }.each do |medium, group|
          next if medium.blank?
          group.first(PER_BUCKET).each { |r| (keep[r] ||= []) << medium }
        end

        # ⚠ Re-sorted, because the union was built bucket by bucket and a row
        #   that only made it in via "book" would otherwise appear above better
        #   ones. The displayed order is always the overall ranking; the buckets
        #   only decide membership.
        works =
          keep
            .keys
            .sort_by { |r| Scores.rank_key(r.gravity&.display, r.recommendations, r.posts_count) }
            .map { |r| r.tap { r.buckets = keep[r] } }

        works + discussion_rows
      end
    end

    # How many rows each chip will actually reveal. The chip prints the true
    # total from SQL; this is what clicking it shows, and the two differing is
    # exactly what the "view all" exit exists for.
    def shown_counts
      @shown_counts ||=
        rows.each_with_object(Hash.new(0)) do |row, out|
          Array(row.buckets).each { |b| out[b] += 1 }
        end
    end

    # The modes present among assessed Works, for choosing the anchors line.
    def modes
      @modes ||= work_rows.map(&:mode).compact_blank.uniq
    end

    # { "all" => 84, "film" => 12, "discussion" => 58, ... } for the filter chips.
    #
    # ⚠ COUNTED IN SQL, NOT FROM `rows`.
    #
    #   These used to be tallied from the rendered rows, which are capped at
    #   MAX_PER_TYPE — and `all_topics` caps at MAX_PER_TYPE * 3 before that. So
    #   a Subject with 84 tagged topics rendered a chip reading "Discussions 25".
    #
    #   A chip exists to communicate scale. One that silently saturates at the
    #   page size is worse than no chip: it does not merely omit the archive, it
    #   states a wrong number about it, and on this forum the archive is the
    #   largest and oldest part of every list.
    def counts
      @counts ||= begin
        c = Hash.new(0)
        return c unless tag

        # curiobase_kind is written at bake time and holds the medium for a
        # Work, "subject" for a Subject's own file, and nothing for an ordinary
        # thread. Matching `rows`: Subjects are counted in neither list — a
        # Subject file is not a treatment of itself.
        Topic
          .joins(:topic_tags)
          .joins(
            "LEFT JOIN topic_custom_fields tcf
               ON tcf.topic_id = topics.id AND tcf.name = #{ActiveRecord::Base.connection.quote(TopicKind::FIELD)}",
          )
          .where(topic_tags: { tag_id: tag.id })
          .where(deleted_at: nil, visible: true, archetype: Archetype.default)
          .group(Arel.sql("tcf.value"))
          .count
          .each do |kind, n|
            next if kind == "subject"
            c[kind.presence || "discussion"] += n
            c["all"] += n
          end

        c
      end
    end

    # More tagged topics than the list shows. Drives the "see everything" exit —
    # without it a reader has no way to know 59 more exist.
    def truncated?
      counts["all"].to_i > rows.size
    end

    private

    # Topics carrying this Subject's tag that are themselves Curiobase records.
    # Their medium and gravity come from the record payload.
    def work_rows
      @work_rows ||=
        begin
          # One query for the whole list rather than one per row.
          likes = Recommendations.for_topics(record_topics.map(&:id))

          # ⚠ ONE QUERY FOR EVERY POSTER, not one per row. The URL is cached on
          #   the topic at bake time by CardRenderer, so a list of 25 Works
          #   costs one custom-field lookup rather than 25 opened posts.
          posters = poster_urls(record_topics.map(&:id))

          # ⚠ ONE QUERY FOR EVERY RECORD, not one per row — this list is built
          #   on EVERY tag page request by the `curiobase_scores` serializer,
          #   and `Source.work` per row was a lookup plus a post fetch plus a
          #   parse, times the row count. Measured at 45 queries for seven rows.
          #
          #   The fallback stays for anything still on a legacy wrap, which the
          #   batch cannot see because it has no fenced block.
          batch = Source.for_topics(record_topics)

          candidates =
            record_topics.filter_map do |topic|
              ref = TopicRecord.for(topic)
              next unless ref && ref[:kind] == "work"
              w = batch[topic.id] || Source.work(ref[:id])
              next unless w
              [topic, w]
            end

          # ⚠ ONE QUERY FOR EVERY PAIRING'S VOTES, not one per row. This was the
          #   last per-row query in the render — profiled at forty works,
          #   `plugin_store_rows` was 40 of the list's 48 queries. It did not
          #   show at seven rows, which is why it survived D-045.
          readings = Gravity.for_works(candidates.map { |_, w| Gravity.work_id(w) }, @slug)

          candidates.map do |topic, w|
            Row.new(
              kind: "work",
              title: topic.title,
              url: topic.relative_url,
              medium: w["medium"],
              mode: w["mode"],
              poster: posters[topic.id],
              gravity: readings[Gravity.work_id(w).to_s],
              recommendations: likes[topic.id].to_i,
              posts_count: topic.posts_count.to_i,
            )
          end
        end
    end

    # Everything else tagged with this Subject — ordinary discussion.
    #
    # ⚠ A thread is a conversation ABOUT an idea, not a treatment OF one, so it
    #   carries no gravity score. Mixing them would make the mean meaningless.
    #
    # ⚠ ORDERED AND LIMITED IN SQL. Recency is `bumped_at`, which is indexed, so
    #   the ten newest threads cost a LIMIT rather than loading a window and
    #   slicing it in Ruby. This is why splitting the query was the fix and not
    #   just widening it: works cannot be ranked in SQL and discussions can, so
    #   forcing both through one query made each one wrong in the other's way.
    def discussion_rows
      @discussion_rows ||=
        begin
          return [] unless tag
          # ⚠ NOT `where.not(id: record_topic_ids)`. That subtracts the Works
          #   this list happens to have loaded and leaves every OTHER record —
          #   including the Subject's own file, which is tagged with its own
          #   slug. A record does not engage itself.
          TopicKind
            .discussions(tagged)
            .order(bumped_at: :desc)
            .limit(PER_BUCKET)
            .map do |topic|
              Row.new(
                kind: "discussion",
                title: topic.title,
                url: topic.relative_url,
                posts_count: topic.posts_count.to_i,
                replies: [topic.posts_count.to_i - 1, 0].max,
                buckets: ["all", "discussion"],
              )
            end
        end
    end

    def poster_urls(topic_ids)
      return {} if topic_ids.empty?
      TopicCustomField
        .where(topic_id: topic_ids, name: CardRenderer::POSTER_FIELD)
        .pluck(:topic_id, :value)
        .to_h
    end

    def tag
      return @tag if defined?(@tag)
      @tag = Tag.find_by(name: @slug)
    end

    # Every live, visible topic carrying this Subject's tag. Not materialised —
    # the two callers scope it differently and each has its own limit.
    def tagged
      Topic
        .joins(:topic_tags)
        .where(topic_tags: { tag_id: tag.id })
        .where(deleted_at: nil, visible: true, archetype: Archetype.default)
    end

    # ══════════════════════════════════════════════════════════════════════════
    # WORKS ARE SELECTED BY BEING RECORDS, NOT BY BEING RECENT.
    # ══════════════════════════════════════════════════════════════════════════
    #
    # ⚠ `curiobase_kind` is written at bake time and holds the medium for a Work,
    #   so "which of these topics are Works" is answerable in SQL. That is what
    #   makes loading them ALL affordable, and it is why `curiobase:doctor` now
    #   refuses to be quiet about a Work missing it: a Work with no
    #   `curiobase_kind` is invisible to this query and therefore absent from
    #   every chip, silently.
    #
    # ⚠ The Subject's own file is excluded HERE by kind, because it carries
    #   `curiobase_kind = "subject"`. `work_rows` still checks `ref[:kind]`
    #   afterwards, since a legacy wrap has no custom field to filter on.
    #
    # ⚠ `includes(:first_post)`: `TopicRecord.for(topic)` reads the record out of
    #   the first post and is called for every topic here. Unpreloaded that is a
    #   query per topic on a route served live on every request.
    #
    # ⚠ Ordered by `bumped_at` only so that MAX_RANKED_WORKS, if it ever bites,
    #   keeps the newest rather than an arbitrary set. Below that limit the
    #   order here is irrelevant — `rows` re-sorts by gravity.
    def record_topics
      @record_topics ||= begin
        return [] unless tag
        tagged
          .includes(:first_post)
          .joins(
            "JOIN topic_custom_fields cbk
               ON cbk.topic_id = topics.id
              AND cbk.name = #{ActiveRecord::Base.connection.quote(TopicKind::FIELD)}",
          )
          .where.not("cbk.value" => "subject")
          .where.not("cbk.value" => nil)
          .order(bumped_at: :desc)
          .limit(MAX_RANKED_WORKS)
          .to_a
      end
    end

  end
end
