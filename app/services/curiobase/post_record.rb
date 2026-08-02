# frozen_string_literal: true

module Curiobase
  # A record authored in its own first post.
  #
  # ══════════════════════════════════════════════════════════════════════════
  # THE AUTHORING FORMAT. This is how every record is written.
  # ══════════════════════════════════════════════════════════════════════════
  #
  # This began as a spike asking whether authoring a record in the composer was
  # tolerable, built to be deleted if the answer was no. The answer was yes: all
  # 34 records were converted and the WordPress read path was removed.
  #
  #     ```curiobase
  #     type: subject
  #     slug: rendlesham-forest
  #     kind: incident
  #     domain: contact
  #     status: contested
  #     period: 1980s
  #     evidence: firsthand-account, documentary-record
  #     dek: Three nights in December 1980, between two USAF bases in Suffolk.
  #     ```
  #
  # ⚠ A FENCED BLOCK, NOT BBCODE, and the reason is failure mode. If this
  #   parser never runs — plugin off, error, an old cooked blob — a fenced block
  #   renders as a visible code block. The data is still on the page and
  #   obviously data. A BBCode wrap that fails renders as nothing at all, which
  #   is how this project lost every Work card for weeks without noticing.
  #
  # ⚠ STRICT ALLOWLIST. An unknown key is an ERROR, not something to ignore.
  #   `evidence: firsthand_account` with an underscore is the exact shape of bug
  #   that has cost the most time here, and a permissive parser is what lets it
  #   through. See RecordValidator, which stops it in the composer.
  class PostRecord
    # ⚠ One definition, in PostKind. This used to be a second identical literal.
    FENCE = PostKind::FENCE

    # ⚠ `image_credit` is the plate's caption on a Subject — source, date,
    #   whose photograph it is. Optional, but on a catalogue of contested things
    #   an uncredited photograph is a weaker claim than a credited one.
    SCALARS = %w[type slug title dek kind domain status also_known_as coords landing_url
                 image_credit
                 medium mode year creator runtime
                 series season episode
                 imdb tmdb isbn igdb youtube archive_org wikipedia asin google_books].freeze
    LISTS = %w[period evidence refs].freeze

    # Subject→Subject edge verbs. One fence key per verb; `refs` stays the
    # untyped "related" escape hatch. Work→Work relations are a separate feature.
    EDGES = %w[explains contradicts precedes part_of same_as involves].freeze
    RELATED = "related"
    EDGE_CAP = 12
    EDGE_VERBS = (EDGES + [RELATED]).freeze

    # ⚠ FACTS ARE FLAT, and that is the concession the fenced block makes.
    #
    #   ACF nests these in a group and shows an `idea` a different set from a
    #   `place`. A key-value block cannot do conditional schema, so every fact
    #   is a top-level key and the author has to know which ones their kind
    #   takes. At eight subjects that is fine; at ninety-three it is a
    #   documentation problem. It is the one real thing lost by leaving the CMS.
    #
    # ⚠ WRITTEN PER KIND, FLATTENED FOR THE PARSER — and the split is the fix
    #   for a real data loss, not decoration.
    #
    #   This was a hand-maintained flat list of eight keys: began, ended, where,
    #   witnesses, outcome, object_kind, founded, claimant. That is a PARTIAL
    #   union — it happens to cover `incident` completely and every other kind
    #   only by accident. So conversion silently truncated four of eight subjects
    #   and emptied two: John Titor lost `active`, `nationality` and `known_for`;
    #   Skinwalker Ranch lost `active` and `country`; Excalibur lost `provenance`
    #   and `whereabouts`; Majestic 12 lost `dissolved`, `org_kind` and
    #   `jurisdiction`. Nothing errored. The records saved and reported success.
    #
    #   Keeping it per kind means the list can be checked against SCHEMA.md §
    #   "The eight kinds" by reading it, and a missing kind is visible as a
    #   missing row rather than as an absence nobody can see.
    FACTS_BY_KIND = {
      "idea" => [],
      "incident" => %w[began ended where witnesses outcome],
      "claim" => %w[asserted claimant],
      "person" => %w[born died active nationality known_for],
      "place" => %w[country active],
      "object" => %w[object_kind provenance whereabouts],
      "org" => %w[founded dissolved org_kind jurisdiction],
      "document" => %w[source_site section transmitted captured operator],
    }.freeze

    # ⚠ The parser accepts the UNION, not the per-kind set.
    #
    #   Rejecting `country` on a `person` would be correct and is not worth the
    #   trade yet: `active` is legitimately used by both `person` and `place`,
    #   the boundaries move as kinds are exercised, and a validator that refuses
    #   a fact an author has good reason to write teaches them to fight the tool.
    #   The union still catches typos, which is what the allowlist is for.
    #   Per-kind enforcement is the tooling answer at several hundred records.
    FACTS = FACTS_BY_KIND.values.flatten.uniq.freeze

    # ⚠ `asin` is here rather than in a separate buy-links block because it IS
    #   an external identifier — the same shape as an ISBN. It is optional: with
    #   no ASIN the Amazon link falls back to a title search, so nobody has to
    #   go and find one for 34 records before the buttons work.
    EXTERNAL = %w[imdb tmdb isbn igdb youtube archive_org wikipedia asin google_books].freeze

    KEYS = (SCALARS + LISTS + EDGES + FACTS).freeze

    REQUIRED = { "subject" => %w[slug kind domain dek], "work" => %w[slug medium dek] }.freeze

    Result = Struct.new(:fields, :unknown, :missing, keyword_init: true) do
      def valid? = unknown.empty? && missing.empty?
      def type = fields["type"]
    end

    # ⚠ There is no `PostRecord.present?`. It existed, was byte-identical to
    #   `PostKind.present?`, and had zero callers — two copies of one regex,
    #   which is how this codebase has broken six times. `PostKind` owns the
    #   question "does this post carry a record", because the Post validator in
    #   plugin.rb needs it at boot before app/ autoloading exists.

    # Returns nil when the post carries no record block at all — which is most
    # posts on the forum, so this has to be cheap and silent.
    def self.parse(raw)
      body = raw.to_s[FENCE, 1]
      return nil unless body

      fields = {}
      unknown = []

      body.each_line do |line|
        line = line.strip
        next if line.empty? || line.start_with?("#")

        key, _, value = line.partition(":")
        key = key.strip.downcase
        value = value.strip

        next unknown << key unless KEYS.include?(key)
        next if value.empty?

        fields[key] =
          if LISTS.include?(key) || EDGES.include?(key)
            value.split(",").map(&:strip).reject(&:empty?)
          else
            value
          end
      end

      fields["type"] ||= "subject"
      missing = REQUIRED.fetch(fields["type"], []).reject { |k| fields[k].present? }

      Result.new(fields: fields, unknown: unknown, missing: missing)
    end

    # The record in the shape every renderer already reads — the fixture shape.
    #
    # ⚠ Nothing downstream may be able to tell where a record came from. The
    #   card, the banner, the association list, the JSON-LD and the doctor all
    #   read this shape, and the moment a post-authored record hands back
    #   something subtly different, one of them renders differently from the
    #   others and nobody finds out for weeks.
    # ══════════════════════════════════════════════════════════════════════════
    # `topic:` IS HOW THE RECORD GETS ITS TITLE.
    # ══════════════════════════════════════════════════════════════════════════
    #
    # ⚠ THE BLANK-TITLE BUG, SEVENTH INSTANCE. `Source.from_post` applied the
    #   topic title after calling this, so records resolved through Source were
    #   fine — but `CardRenderer#render_post_authored!` builds its record here
    #   directly and never touches Source. On a record's own topic page the
    #   title was therefore still nil, and the symptom was a link reading
    #   "Read more about" with nothing after it.
    #
    #   Two paths to build a record, one of them updated. Passing the topic here
    #   means the title is applied where the record is MADE, so there is no
    #   longer a version of a record that lacks one.
    def self.to_record(result, topic: nil)
      return nil unless result&.valid?

      fields = result.fields
      out = { "type" => fields["type"], "slug" => fields["slug"] }

      (SCALARS - %w[type slug year season episode] - EXTERNAL).each { |k| out[k] = fields[k] if fields[k].present? }
      out["year"] = fields["year"].to_i if fields["year"].present?
      out["season"] = fields["season"].to_i if fields["season"].present?
      out["episode"] = fields["episode"].to_i if fields["episode"].present?
      (LISTS - %w[refs]).each { |k| out[k] = fields[k] if fields[k].present? }

      external = EXTERNAL.each_with_object({}) { |k, h| h[k] = fields[k] if fields[k].present? }
      out["external"] = external if external.any?

      facts = FACTS.each_with_object({}) { |k, h| h[k] = fields[k] if fields[k].present? }
      out["facts"] = facts if facts.any?

      # Subject→Subject edges. Typed verbs + untyped `refs` collapse into one
      # `refs` array with a `verb` key — SubjectCard / fixtures / Source already
      # read that shape. A hash with no verb (legacy fixtures) means related.
      refs = build_refs(fields)
      out["refs"] = refs if refs.any?

      # The topic title IS the record's title — see DECISIONS D-032. A `title:`
      # in the block still wins, as the escape hatch for a topic whose title
      # carries forum noise.
      out["title"] = topic.title if out["title"].blank? && topic.respond_to?(:title)

      out
    end

    # Bare slug → related. Qualified token `explains:slug` → that verb (parse-only
    # fallback inside `refs:`). Writer always expands back to verb keys.
    def self.parse_ref_token(token)
      token = token.to_s.strip
      return [RELATED, ""] if token.blank?

      if token.include?(":")
        verb, _, rest = token.partition(":")
        verb = verb.strip.downcase
        rest = rest.strip
        return [verb, rest] if EDGES.include?(verb) && rest.present?
      end

      [RELATED, token]
    end

    def self.build_refs(fields)
      out = []
      EDGES.each do |verb|
        Array(fields[verb]).each { |slug| out << edge_entry(verb, slug) }
      end
      Array(fields["refs"]).each do |token|
        verb, slug = parse_ref_token(token)
        next if slug.blank?
        out << edge_entry(verb, slug)
      end
      out
    end

    def self.edge_entry(verb, slug)
      slug = slug.to_s.strip
      {
        "verb" => verb,
        "label" => edge_label(verb),
        "slug" => slug,
        "title" => titleize(slug),
      }
    end

    def self.edge_label(verb)
      return I18n.t("curiobase.related") if verb == RELATED

      I18n.t("curiobase.edge.#{verb}", default: verb.to_s.tr("_", " ").capitalize)
    end

    # Edge display title. Never load the target through Source.subject — that
    # re-enters to_record → build_refs → titleize and loops on mutual edges
    # (rendlesham ↔ orfordness, majestic ↔ philadelphia, …).
    def self.titleize(slug)
      topic_id = RecordTopic.find(slug, type: :subject)
      if topic_id
        title = Topic.where(id: topic_id).pick(:title)
        return title if title.present?
      end

      fixture = Source.fixture.subject(slug)
      return fixture["title"] if fixture && fixture["title"].present?

      slug.to_s.tr("-", " ").split.map(&:capitalize).join(" ")
    rescue StandardError
      slug.to_s.tr("-", " ")
    end
  end
end
