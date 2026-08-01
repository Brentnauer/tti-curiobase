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
      else
        base["@type"] = KIND[record["kind"]] || "CreativeWork"
        subject_facts(base, record)
      end

      base
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
    # ⚠ MEMBER VOTES ONLY. THE INSTITUTE'S ASSESSMENT IS DELIBERATELY NOT HERE.
    # ══════════════════════════════════════════════════════════════════════════
    #
    # Two separate reasons, and both have to hold for a line of markup to be
    # worth emitting.
    #
    # 1. AggregateRating REQUIRES a ratingCount, and ratingCount means people.
    #    With voting off, every pairing has an assessment and zero voters. The
    #    only ways to emit markup anyway are to publish ratingCount 0 (invalid)
    #    or to count the institute as a voter (false). Both are the kind of thing
    #    that earns a structured-data manual action, and the recovery from one is
    #    measured in months.
    #
    # 2. More fundamentally, GRAVITY IS NOT A QUALITY RATING. It measures how
    #    central a Subject is to a Work. *Primer* scoring 5 on causal-loop says
    #    the film is built on the idea, not that it is a good film — a 1 is not a
    #    pan. schema.org's rating vocabulary means "how good", and Google renders
    #    it as stars beside the result. Stars that a reader will read as a review
    #    score, attached to a number that is not one, is a lie told to everyone
    #    who sees the search listing.
    #
    # So: no votes, no markup. That costs a rich result the site was never
    # entitled to. Everything else in this document — the type, the year, the
    # creator, sameAs — is true and stays.
    #
    # ⚠ DO NOT "FIX" THIS by feeding the blended display value in here. That is
    #   the same lie with an extra step, and the blend includes the institute.
    # ⚠ NO RESOLUTION LOGIC HERE — and for a while there was some anyway.
    #
    #   The comment above this method said exactly that while thirteen lines of
    #   its own parse-the-post-then-fall-back-to-a-wrap sequence sat underneath
    #   it. That is how the tag page and the topic page ended up rendering
    #   different records: two answers to "what record is this", diverging in
    #   silence.
    #
    #   TopicRecord knows both authoring formats and Source is the one door.
    #   Between them there is nothing left for this method to decide.
    def self.resolve(topic)
      ref = Curiobase::TopicRecord.for(topic)
      return [nil, nil] unless ref

      record = ref[:kind] == "work" ? Source.work(ref[:id]) : Source.subject(ref[:id])
      [record, ref[:kind]]
    end

    def self.aggregate(topic, record)
      return nil unless SiteSetting.curiobase_member_voting_enabled

      readings =
        Gravity.for_subjects(record, Subjects.for_topic(topic)).values.compact.select(&:voters?)
      return nil if readings.empty?

      total = readings.sum(&:voter_count)
      return nil if total.zero?

      # Unweighted member mean, reconstructed from the distributions. Not the
      # display value: this figure has to be exactly what ratingCount describes.
      sum =
        readings.sum do |r|
          Array(r.distribution).each_with_index.sum { |count, i| count * (i + 1) }
        end

      {
        "@type" => "AggregateRating",
        "ratingValue" => (sum / total.to_f).round(2),
        "bestRating" => 5,
        "worstRating" => 1,
        "ratingCount" => total,
      }
    end
  end
end
