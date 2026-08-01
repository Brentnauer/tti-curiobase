# frozen_string_literal: true

module Curiobase
  # Where record data comes from.
  #
  # ══════════════════════════════════════════════════════════════════════════
  # ONE DOOR. Everything that wants a record comes through here.
  # ══════════════════════════════════════════════════════════════════════════
  #
  # Two ways a record can exist, in preference order:
  #
  #   1. THE POST ITSELF — a fenced ```curiobase block. Production authoring.
  #   2. `fixtures/` — JSON on disk, for a topic still carrying a legacy
  #      `[wrap=…]` marker that has not been converted yet.
  #
  # ⚠ Do not add a third source. Dual paths for one fact is how tag pages and
  #   topic pages drifted apart.
  module Source
    # ⚠ TYPE-SCOPED, because Works and Subjects share one slug namespace. Asking
    #   for the Subject `majestic-12` must never resolve a Work that claims the
    #   same string.
    def self.work(id) = from_post(id, type: :work) || fixture.work(id)
    def self.subject(slug) = from_post(slug, type: :subject) || fixture.subject(slug)

    def self.fixture = @fixture ||= Fixture.new

    # ══════════════════════════════════════════════════════════════════════════
    # EVERY RECORD IN A LIST, IN ONE QUERY.
    # ══════════════════════════════════════════════════════════════════════════
    #
    # `{ topic_id => record }` for the topics given. Anything not post-authored
    # is simply absent — the caller falls back to `work`/`subject` for those.
    #
    # ⚠ THIS IS THE TAG PAGE'S HOT PATH. `curiobase_scores` runs on EVERY tag
    #   page request and called `Source.work` once per row: a RecordTopic lookup
    #   plus a post fetch plus a parse, times twenty-five. Measured at 45
    #   queries for seven rows, extrapolating to ~200 for a subject at the cap.
    #
    #   The card on a record's own topic is baked into `posts.cooked`, so that
    #   cost is paid once per rebake and never on a read. The tag page is not
    #   baked, which is what makes this the one place row count turns into
    #   request cost.
    def self.for_topics(topics)
      list = Array(topics).compact
      return {} if list.empty?

      Post
        .where(topic_id: list.map(&:id), post_number: 1)
        .includes(:topic)
        .each_with_object({}) do |post, out|
          next unless PostKind.present?(post.raw)
          record = PostRecord.to_record(PostRecord.parse(post.raw), topic: post.topic)
          out[post.topic_id] = record if record
        end
    rescue StandardError => e
      # One malformed record must not empty the whole list — the caller falls
      # back to resolving each on its own.
      Rails.logger.warn("[curiobase] batch resolve failed: #{e.class}: #{e.message}")
      {}
    end

    # The record as authored in its own first post, or nil.
    #
    # ⚠ Cheap on a miss, which is what matters: RecordTopic.find is a cached
    #   custom-field lookup that returns nil for anything not yet converted.
    def self.from_post(slug, type: :subject)
      return nil if slug.blank?

      topic_id = RecordTopic.find(slug, type: type)
      return nil unless topic_id

      # `includes(:topic)` because the title below needs it — a Subject card with
      # six association rows is otherwise six extra queries inside a render.
      post = Post.includes(:topic).find_by(topic_id: topic_id, post_number: 1)
      return nil unless post && PostKind.present?(post.raw)

      # ══════════════════════════════════════════════════════════════════════
      # THE TOPIC TITLE IS THE RECORD'S TITLE.
      # ══════════════════════════════════════════════════════════════════════
      #
      # ⚠ Not a fallback — the source. The topic title is already the <h1>,
      #   already what search results show, and already what a member renames
      #   when the record is wrong. Authoring it again in the block gives one
      #   fact two homes that can disagree.
      #
      # ⚠ APPLIED INSIDE `to_record`, NOT HERE. It used to be applied here, on
      #   the way out of Source — which meant a record built any OTHER way had
      #   no title. `CardRenderer` builds one directly from the parsed block, so
      #   on a record's own topic page the title was still nil and a link read
      #   "Read more about" with nothing after it. Two paths, one of them fixed:
      #   the same shape of bug, for the seventh time.
      #
      #   Now the title is applied where the record is MADE, so there is no
      #   version of a record that lacks one.
      PostRecord.to_record(PostRecord.parse(post.raw), topic: post.topic)
    rescue StandardError => e
      # A malformed record must not take down a page that could still render —
      # but it must be findable. Specs assert this line exists.
      Rails.logger.warn("[curiobase] post-authored record #{slug} unreadable: #{e.class}: #{e.message}")
      nil
    end

    # ── fixtures ────────────────────────────────────────────────────────────
    #
    # ⚠ THE LEGACY PATH, not the primary one. A record that still carries a
    #   `[wrap=…]` marker resolves here. Convert it with
    #   `bin/rake curiobase:convert[<slug>]` and this stops being consulted for
    #   it — `curiobase:doctor` lists anything still on a wrap.
    #
    # ⚠ These files are also what the spec suite asserts against, so the shape
    #   they return IS the record shape. Nothing downstream may be able to tell
    #   where a record came from.
    class Fixture
      ROOT = File.expand_path("../../fixtures", __dir__)

      # Filenames are ids, but a wrap may name a slug. Both have to resolve or a
      # spec would pass against a reference production cannot follow.
      def work(id)
        load_json("works/#{id}.json") || by_slug(id)
      end

      def subject(slug)
        load_json("subjects/#{slug}.json")
      end

      private

      def by_slug(slug)
        key = slug.to_s
        return nil if key.blank? || key.match?(/\A\d+\z/)
        Dir[File.join(ROOT, "works", "*.json")]
          .lazy
          .map { |f| JSON.parse(File.read(f)) rescue nil }
          .find { |w| w && w["slug"].to_s == key }
      end

      def load_json(rel)
        path = File.join(ROOT, rel)
        return nil unless File.exist?(path)
        JSON.parse(File.read(path))
      rescue JSON::ParserError => e
        Rails.logger.warn("[curiobase] bad fixture #{rel}: #{e.message}")
        nil
      end
    end
  end
end
