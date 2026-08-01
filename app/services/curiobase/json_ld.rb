# frozen_string_literal: true

module Curiobase
  # schema.org for the crawler <head>.
  #
  # A reference work wants Movie / Book / VideoGame / Person, not
  # DiscussionForumPosting. This is the pattern discourse-solved ships for
  # QAPage: register_html_builder("server:before-head-close-crawler").
  #
  # The aggregateRating is the single largest SEO gain available here. Under a
  # client-side design those numbers are invisible to Google — the one output
  # the whole system exists to produce.
  module JsonLd
    MEDIUM = {
      "film" => "Movie",
      "series" => "TVSeries",
      "book" => "Book",
      "game" => "VideoGame",
      "video" => "VideoObject",
      "document" => "CreativeWork",
    }.freeze

    # ⚠ THE CREDIT PROPERTY IS PER TYPE, and `creator` is the generic fallback.
    #   Google's Movie documentation names `director`; its Book documentation
    #   names `author`. `creator` is valid schema.org on both and understood as
    #   neither, which is the difference between being parsed and being used.
    CREDIT = {
      "Movie" => "director",
      "TVSeries" => "director",
      "Book" => "author",
    }.freeze

    KIND = {
      "idea" => "DefinedTerm",
      "incident" => "Event",
      "claim" => "Claim",
      "person" => "Person",
      "place" => "Place",
      # ⚠ Not CreativeWork. Excalibur is not a creative work — it is a thing
      #   people made claims about. schema.org has no better type, and Thing is
      #   honest where CreativeWork is a category error.
      "object" => "Thing",
      "org" => "Organization",
      "document" => "CreativeWork",
    }.freeze

    def self.for_controller(controller)
      topic = controller.instance_variable_get(:@topic_view)&.topic
      return tag_head(controller) unless topic

      blob = build(topic)
      return "" if blob.blank?
      script(blob)
    rescue => e
      # ⚠ SWALLOWING THIS COST A SESSION. A rename in Gravity left `members?`
      #   dangling here, every Work silently lost its structured data, and the
      #   only trace was one warning line in a log nobody was tailing. Rescuing
      #   is still right — a broken script tag must not take the topic page down
      #   — but it has to be loud enough to find, so the class and the backtrace
      #   go in, and `verify.sh` checks the ld column on every record.
      Rails.logger.warn(
        "[curiobase] json-ld FAILED for topic #{topic&.id}: #{e.class}: #{e.message}\n" \
          "#{e.backtrace&.grep(/curiobase/)&.first(4)&.join("\n")}",
      )
      ""
    end

    def self.script(blob)
      [
        %(<script type="application/ld+json">),
        MultiJson.dump(blob).gsub("</", "<\\/").html_safe,
        "</script>",
      ].join
    end

    # ══════════════════════════════════════════════════════════════════════════
    # A SUBJECT'S TAG PAGE, FOR A CRAWLER.
    # ══════════════════════════════════════════════════════════════════════════
    #
    # Measured before this existed: /tag/majestic-12 returned no description, no
    # structured data and no card to Googlebot. The banner reaches the Ember app
    # only, so the page a reader would expect to find by searching *"films about
    # majestic 12"* was worth nothing.
    #
    # ⚠ HEAD ONLY, because that is the only hook Discourse gives a plugin on this
    #   view. `server:before-head-close-crawler` is the single outlet;
    #   `app/views/list/list.erb` has none. Overriding the view would work until
    #   the next upgrade.
    #
    # ⚠ IT DOES NOT CANONICALISE TO THE RECORD TOPIC, and that is a deliberate
    #   departure from the first sketch of this.
    #
    #   Pointing rel=canonical at /t/<slug> would tell Google the tag page is a
    #   duplicate and to drop it from the index — which is the exact opposite of
    #   making it worth something in search. Discourse already emits a
    #   self-canonical here and a second one would simply be ignored.
    #
    #   The relationship is expressed in the data instead: `about` names the
    #   Subject entity and `mainEntityOfPage` points at the file. The tag page
    #   says *"I am a list of things about X, and X lives over there."*
    #
    # ⚠ NO aggregateRating in the list, for the same reason it is absent from a
    #   Work: gravity is centrality, not quality. The ItemList carries order,
    #   which is the honest thing it has to say.
    # ⚠ THE TAG NAME IS IN A DIFFERENT PARAM ON EACH OF THREE ROUTES, and
    #   assuming otherwise made this whole method a no-op that looked shipped.
    #
    #     /tag/:tag_slug/:tag_id   canonical, and `tag_id` is the NUMERIC id
    #     /tag/:tag_id             API form, numeric
    #     /tag/:tag_name           legacy, 301s to the canonical form
    #
    #   The first version read `params[:tag_id]` and compared it to the subject
    #   vocabulary. On the canonical URL that is "13", which matches nothing, so
    #   it returned "" on every page and nothing anywhere said so.
    def self.tag_name_from(params)
      name = params[:tag_slug].presence || params[:tag_name].presence
      return name.to_s if name.present?

      id = params[:tag_id].to_s
      return "" if id.blank?
      return id unless id.match?(/\A\d+\z/)

      Tag.where(id: id).pick(:name).to_s
    end

    def self.tag_head(controller)
      slug = tag_name_from(controller.params)
      return "" if slug.blank?
      return "" unless Subjects.vocabulary.include?(slug)

      record = Source.subject(slug)
      return "" unless record

      # ⚠ NO SECOND <meta name="description">. Discourse already emits one
      #   ("Topics tagged majestic-12") and a page with two is a page where the
      #   crawler picks the first and ignores yours. Measured: adding one gave
      #   the page two description tags, of which ours was the loser.
      #
      #   Improving Discourse's own tag description means setting
      #   `@description_meta` inside TagsController before render, which no
      #   plugin hook reaches. The dek travels as the JSON-LD `description`
      #   instead — a structured signal rather than a duplicate tag. Recorded in
      #   SHIP.md as the one part of this that is not fully solved.
      rows = Associations.new(slug).rows.select { |r| r.kind == "work" }

      page = {
        "@context" => "https://schema.org",
        "@type" => "CollectionPage",
        "name" => record["title"].presence || slug.tr("-", " "),
        "url" => "#{Discourse.base_url}/tag/#{slug}",
      }
      page["description"] = record["dek"] if record["dek"].present?

      about = { "@type" => KIND[record["kind"]] || "Thing", "name" => page["name"] }
      if (file = RecordTopic.find(slug, type: :subject))
        topic = Topic.select(:id, :slug).find_by(id: file)
        about["mainEntityOfPage"] = "#{Discourse.base_url}#{topic.relative_url}" if topic
      end
      page["about"] = about

      if rows.any?
        page["mainEntity"] = {
          "@type" => "ItemList",
          "numberOfItems" => rows.size,
          "itemListOrder" => "https://schema.org/ItemListOrderDescending",
          "itemListElement" =>
            rows.each_with_index.map do |row, i|
              {
                "@type" => "ListItem",
                "position" => i + 1,
                "url" => "#{Discourse.base_url}#{row.url}",
                "name" => row.title,
              }
            end,
        }
      end

      script(page)
    end

    def self.build(topic)
      return nil unless topic

      record, kind = resolve(topic)
      return nil unless record

      ref = { kind: kind }

      base = {
        "@context" => "https://schema.org",
        "name" => topic.title,
        "url" => "#{Discourse.base_url}#{topic.relative_url}",
      }
      base["description"] = record["dek"] if record["dek"].present?

      # ⚠ REQUIRED by Google for the Book and Movie rich results, and strongly
      #   recommended everywhere else — a record without it cannot qualify at
      #   all. The URL is already cached on the topic by CardRenderer at bake
      #   time, so this costs nothing and was simply never wired up.
      if (image = image_url(topic))
        base["image"] = image
      end

      # ⚠ `sameAs` is how Google reconciles this with an entity it already
      #   knows, and it used to carry IMDb alone. Every ISBN, IGDB id, TMDB id
      #   and archive.org identifier in the catalogue was thrown away — and
      #   Wikipedia, the strongest signal of the set, with them.
      links = Identifiers.urls(record["external"])
      base["sameAs"] = links if links.any?

      if ref[:kind] == "work"
        base["@type"] = MEDIUM[record["medium"]] || "CreativeWork"
        base["datePublished"] = record["year"].to_s if record["year"]
        base["timeRequired"] = record["runtime"] if record["runtime"].present?

        if record["creator"].present?
          base[CREDIT.fetch(base["@type"], "creator")] = {
            "@type" => "Person",
            "name" => record["creator"],
          }
        end

        # The dedicated property, not just a `sameAs` link to OpenLibrary.
        if base["@type"] == "Book" && (isbn = record.dig("external", "isbn")).present?
          base["isbn"] = isbn
        end

        agg = aggregate(topic, record)
        base["aggregateRating"] = agg if agg

        # Subjects this Work engages — entities, not competing AggregateRatings.
        about = subject_about(topic)
        base["about"] = about if about.present?
      else
        base["@type"] = KIND[record["kind"]] || "CreativeWork"
        subject_facts(base, record)
      end

      base
    end

    # Subject entities linked from a Work page. No AggregateRating here — that
    # lives once on the Work, from the primary pairing.
    def self.subject_about(topic)
      Subjects.for_topic(topic).filter_map do |slug|
        subject = Source.subject(slug)
        next unless subject

        entity = {
          "@type" => KIND[subject["kind"]] || "Thing",
          "name" => subject["title"].presence || slug.tr("-", " "),
        }
        entity["description"] = subject["dek"] if subject["dek"].present?
        if (file = RecordTopic.find(slug, type: :subject))
          t = Topic.select(:id, :slug).find_by(id: file)
          entity["url"] = "#{Discourse.base_url}#{t.relative_url}" if t
        end
        entity
      end
    end

    # ⚠ ABSOLUTE, because structured data is read off-site. A relative
    #   `/uploads/…` is legal HTML and useless to a crawler resolving the image.
    def self.image_url(topic)
      url = topic.custom_fields[CardRenderer::POSTER_FIELD].presence
      return nil if url.blank?
      url.start_with?("http") ? url : "#{Discourse.base_url}#{url}"
    end

    # ══════════════════════════════════════════════════════════════════════════
    # A SUBJECT'S OWN FACTS, WHERE SCHEMA.ORG HAS A PROPERTY FOR THEM.
    # ══════════════════════════════════════════════════════════════════════════
    #
    # The schema has collected `began`, `ended`, `born`, `died`, `founded`,
    # `dissolved` and `coords` since the first version and emitted none of them.
    # An Event with no `startDate` is an Event schema.org can do nothing with.
    def self.subject_facts(base, record)
      facts = record["facts"] || {}

      case base["@type"]
      when "Event"
        base["startDate"] = iso_date(facts["began"]) if iso_date(facts["began"])
        base["endDate"] = iso_date(facts["ended"]) if iso_date(facts["ended"])
        base["location"] = { "@type" => "Place", "name" => facts["where"] } if facts["where"].present?
      when "Person"
        base["birthDate"] = iso_date(facts["born"]) if iso_date(facts["born"])
        base["deathDate"] = iso_date(facts["died"]) if iso_date(facts["died"])
        base["nationality"] = facts["nationality"] if facts["nationality"].present?
      when "Organization"
        base["foundingDate"] = iso_date(facts["founded"]) if iso_date(facts["founded"])
        base["dissolutionDate"] = iso_date(facts["dissolved"]) if iso_date(facts["dissolved"])
      end

      if (geo = geo_of(record["coords"]))
        base["geo"] = geo
      end
    end

    # ══════════════════════════════════════════════════════════════════════════
    # ONLY EMIT A DATE THAT IS GENUINELY ISO 8601.
    # ══════════════════════════════════════════════════════════════════════════
    #
    # ⚠ These fields are free text by design — `began: 27 December 1980` and
    #   `founded: allegedly 1947` are both things an author will write, and both
    #   are correct in the record. schema.org's date properties are typed, and
    #   handing Google prose where it expects a date is INVALID structured data,
    #   which is worse than omitting the property: an invalid value can
    #   disqualify the whole item, while a missing one just says less.
    #
    #   So this is deliberately strict. Year, year-month, or full date. Anything
    #   else stays in the card, where a human reads it and nothing parses it.
    def self.iso_date(value)
      s = value.to_s.strip
      s.match?(/\A\d{4}(-\d{2}(-\d{2})?)?\z/) ? s : nil
    end

    def self.geo_of(coords)
      lat, lon = coords.to_s.split(",", 2).map { |v| v.to_s.strip }
      return nil unless lat.present? && lon.present?
      return nil unless lat.match?(/\A-?\d+(\.\d+)?\z/) && lon.match?(/\A-?\d+(\.\d+)?\z/)

      { "@type" => "GeoCoordinates", "latitude" => lat.to_f, "longitude" => lon.to_f }
    end

    # ══════════════════════════════════════════════════════════════════════════
    # ⚠ MEMBER VOTES ONLY. ONE AggregateRating PER WORK URL.
    # ══════════════════════════════════════════════════════════════════════════
    #
    # Two separate reasons, and both have to hold for a line of markup to be
    # worth emitting.
    #
    # 1. AggregateRating REQUIRES a ratingCount, and ratingCount means people.
    #    With voting off, every pairing has zero voters. Publishing
    #    ratingCount 0 is invalid structured data.
    #
    # 2. Gravity is CENTRALITY, not quality — but Google still renders
    #    AggregateRating as stars. Emitting it is a deliberate discovery trade:
    #    one clear signal on the Work URL, never N competing ratings for N
    #    subjects. Subjects travel as `about` / related entities without their
    #    own AggregateRating on this page.
    #
    # So: no votes, no markup. Structured ratings off → no AggregateRating.
    # When on: primary pairing (most voters, then highest display), only if it
    # meets curiobase_structured_ratings_min_voters. ratingValue is the
    # unweighted member mean of that pairing — what ratingCount describes —
    # not the standing-weighted display used on the card.
    def self.resolve(topic)
      ref = Curiobase::TopicRecord.for(topic)
      return [nil, nil] unless ref

      record = ref[:kind] == "work" ? Source.work(ref[:id]) : Source.subject(ref[:id])
      [record, ref[:kind]]
    end

    def self.aggregate(topic, record)
      return nil unless SiteSetting.curiobase_member_voting_enabled
      return nil unless SiteSetting.curiobase_structured_ratings

      readings =
        Gravity
          .for_subjects(record, Subjects.for_topic(topic))
          .values
          .compact
          .select(&:voters?)
      return nil if readings.empty?

      # One pairing wins the page. Stacking every subject's votes into one
      # ratingCount would invent a consensus that does not exist.
      primary =
        readings.max_by { |r| [r.voter_count.to_i, r.display.to_f] }
      return nil unless primary

      min = SiteSetting.curiobase_structured_ratings_min_voters.to_i
      return nil if primary.voter_count.to_i < min

      dist = Array(primary.distribution)
      total = dist.sum
      return nil if total.zero?

      sum = dist.each_with_index.sum { |count, i| count * (i + 1) }

      {
        "@type" => "AggregateRating",
        "ratingValue" => (sum / total.to_f).round(2),
        "bestRating" => 5,
        "worstRating" => 1,
        "ratingCount" => primary.voter_count.to_i,
      }
    end
  end
end
