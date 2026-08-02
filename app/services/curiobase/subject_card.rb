# frozen_string_literal: true

module Curiobase
  # The Subject card, built once in Ruby and served to three surfaces:
  #
  #   1. the record topic          — baked into posts.cooked by CardRenderer
  #   2. the tag page, for crawlers — app/views/connectors/topic_list_header/
  #   3. the tag page, in the app   — fetched as HTML by the client island
  #
  # ⚠ ONE RENDERER. The obvious alternative is a second implementation in
  #   JavaScript for the Ember route, and that is how the two versions of a
  #   card drift apart — one gets a field, the other does not, and the one
  #   Google sees is whichever was forgotten. The client fetches this HTML
  #   rather than rebuilding it.
  #
  # Two variants:
  #
  #   :full   — everything, including the association list. The record topic.
  #   :banner — badges, dek, filter chips, and a link to the record topic.
  #
  # ⚠ The banner is deliberately SHORT.
  #
  #   The record topic is the canonical page for a Subject: it holds the
  #   JSON-LD, the replies, and whatever inbound links twenty-eight years
  #   produced. If the banner repeated the full card, the tag page would become
  #   a near-duplicate competing for the same query and the two would split
  #   their own ranking. A summary plus a link is not a compromise, it is the
  #   correct amount.
  class SubjectCard
    include Markup

    MEDIA = %w[film series book game video document].freeze
    FILTERS = (MEDIA + %w[discussion]).freeze
    # Staff statuses that claim the file is settled — membership may still split.
    SETTLED_STATUSES = %w[explained debunked hoax-admitted].freeze

    def self.for_slug(slug, variant: :full, active_filter: nil)
      record = Source.subject(slug)
      return nil unless record
      new(record, variant: variant, active_filter: active_filter)
    end

    # `plate` is the landscape image lifted out of the post by PostMedia. Only
    # the record's own topic has one — the banner and the tag-list surfaces get
    # a thumbnail from the cached URL instead.
    def initialize(record, variant: :full, active_filter: nil, plate: nil)
      @r = record
      @variant = variant
      # Resolved against association counts when filters render — Works by
      # default, Discussions when the subject has no Works yet.
      @active_filter_param = active_filter
      @active = nil
      @plate = plate
      @doc = Nokogiri::HTML5::DocumentFragment.parse("")
    end

    def to_html
      build.to_html
    end

    # The topic carrying [wrap=subject id=<slug>] — the Subject's canonical page.
    #
    # ⚠ This used to be `posts.raw ILIKE '%[wrap=subject id=<slug>]%'`, uncached,
    #   on every tag page render. That is an unindexable full scan of the posts
    #   table — 125,297 rows — on one of the routes crawlers hit hardest, and it
    #   would have gone on looking fine right up to the point it didn't.
    #
    #   RecordTopic reads a custom field written at bake time instead.
    def self.record_topic(slug)
      id = RecordTopic.find(slug)
      id && Topic.select(:id, :slug).find_by(id: id)
    end

    private

    def slug = @r["slug"]

    def build
      card = node("div", class: "curiobase-card curiobase-card--subject curiobase-card--#{@variant}",
                         "data-id": slug)

      # ⚠ THE DEK IS FIRST IN THE DOM. The badges only LOOK like they lead —
      #   .cb-badges carries order: -1. When they were first in document order
      #   every meta description began "incidentcontactcontested …", because
      #   stripping tags leaves badge words with no spaces between them.
      card.add_child(para("cb-dek", @r["dek"])) if @r["dek"].present?
      card.add_child(badge_line)
      plate_block&.then { |p| card.add_child(p) }

      @variant == :banner ? build_banner(card) : build_full(card)
      card
    end

    # ══════════════════════════════════════════════════════════════════════════
    # THE PLATE — 3:2, WITH A CAPTION. NOT A HERO.
    # ══════════════════════════════════════════════════════════════════════════
    #
    # ⚠ A Work's poster IS the artifact and needs no explanation. A Subject's
    #   image is EVIDENCE, and evidence with no provenance is the thing this
    #   catalogue exists not to be. So the caption is not decoration — it is the
    #   difference between a picture and a plate in a file, and it is why this
    #   reads as a different kind of object from a poster without needing a
    #   second layout.
    #
    # ⚠ AFTER THE DEK, always. The dek has to lead the DOM for the search
    #   snippet and that rule has already regressed three times.
    def plate_block
      return nil if @plate.nil?

      fig = node("figure", class: "cb-plate-figure")
      fig.add_child(@plate)

      if (credit = @r["image_credit"]).present?
        cap = node("figcaption", class: "cb-plate-credit")
        cap.content = credit
        fig.add_child(cap)
      end
      fig
    end

    # ── the record topic ────────────────────────────────────────────────────
    def build_full(card)
      card.add_child(facts) if facts
      card.add_child(refs) if refs
      card.add_child(inbound_refs) if inbound_refs
      card.add_child(prose) if prose
      card.add_child(links) if links
      card.add_child(facets) if facets
      card.add_child(landing_link) if @r["landing_url"].present?
      card.add_child(full_text) if @r["full_text"].present?
      card.add_child(associations)
    end

    # ── the tag page ────────────────────────────────────────────────────────
    def build_banner(card)
      assoc = Associations.new(slug)
      resolve_active!(assoc)
      card.add_child(banner_thumb)
      card.add_child(filters(assoc.counts))

      # The one link that matters here. Everything else on this page is a list.
      if (topic = self.class.record_topic(slug))
        p = node("p", class: "cb-landing")
        a = node("a", href: topic.relative_url, class: "cb-record-link")
        a.content = I18n.t("curiobase.open_record", title: @r["title"])
        p.add_child(a)
        card.add_child(p)
      elsif @r["landing_url"].present?
        card.add_child(landing_link)
      end
    end

    # ── pieces ──────────────────────────────────────────────────────────────
    def badge_line = badges(@r["kind"], @r["domain"], @r["status"])

    # ══════════════════════════════════════════════════════════════════════
    # ⚠ `facts` HOLDS SHORT SCALARS AND NOTHING ELSE.
    #
    #   This is the one schema rule the shakedown produced, and it came from
    #   rendering all eight kinds instead of the two that existed:
    #
    #     claim.supports / contradicts  — paragraphs, squeezed into a grid cell
    #     claim.claimant                — a reference, printed as "john-titor"
    #     document.full_text            — an entire recovered document, as a <dd>
    #     document.url                  — a URL, unlinked, labelled "Url"
    #     place.coords                  — the one value a reader cannot use as text
    #
    #   A two-column definition list is right for "Country: United States" and
    #   wrong for every one of those. So they leave `facts` and become typed
    #   top-level fields, each rendered by something that knows what it is.
    # ══════════════════════════════════════════════════════════════════════
    def facts
      dl = kv_list(@r["facts"], "cb-facts")
      return nil unless dl
      dl
    end

    def kv_list(hash, klass)
      return nil unless hash.is_a?(Hash) && hash.any?
      dl = node("dl", class: klass)
      hash.each do |k, v|
        next if v.blank?
        dt = node("dt"); dt.content = k.to_s.tr("_", " ").capitalize
        dd = node("dd"); dd.content = v.to_s
        dl.add_child(dt)
        dl.add_child(dd)
      end
      dl.children.any? ? dl : nil
    end

    # References to other Subjects — typed edges + related.
    # One <dt> per verb; missing verb (legacy fixtures) reads as related.
    def refs
      list = Array(@r["refs"]).select { |ref| ref.is_a?(Hash) && ref["slug"].present? }
      # same_as is refused at validate — never render if a legacy fence still has it.
      list =
        list.reject { |ref| (ref["verb"].presence || PostRecord::RELATED) == "same_as" }
      return nil if list.empty?

      grouped =
        list.group_by { |ref| (ref["verb"].presence || PostRecord::RELATED) }

      dl = node("dl", class: "cb-facts cb-refs")
      PostRecord::EDGE_VERBS.each do |verb|
        rows = grouped[verb]
        next if rows.blank?

        dt = node("dt", "data-verb": verb, class: "cb-refs-verb")
        dt.content = rows.first["label"].presence || PostRecord.edge_label(verb)
        dl.add_child(dt)

        # One <dd> per verb. Separate <dd>s auto-place into column 1 of the
        # facts grid and drop under the label — the "Related" wrap bug.
        dd = node("dd", "data-verb": verb, class: "cb-refs-targets")
        rows.each_with_index do |ref, i|
          dd.add_child(text(" · ")) if i.positive?
          a = node("a", href: ref_href(ref["slug"]))
          a.content = ref["title"].presence || ref["slug"]
          dd.add_child(a)
        end
        dl.add_child(dd)
      end
      dl.children.any? ? dl : nil
    end

    # ⚠ Through RecordTopic, so a ref lands on the referenced Subject's FILE
    #   when it has one and only falls back to its tag page when it does not —
    #   the same rule every other Subject link follows. This used to build a
    #   tag URL unconditionally, which made refs the one link type that ignored
    #   "the file is canonical, the tag page is navigation".
    def ref_href(ref_slug) = RecordTopic.href(ref_slug, tag: tag_for(ref_slug))

    # ══════════════════════════════════════════════════════════════════════════
    # INBOUND — OTHER FILES POINT HERE. NOT A MIRROR VERB.
    # ══════════════════════════════════════════════════════════════════════════
    #
    # Authorship is one-way. Rendering "Contains A" on B would make B assert
    # something it never wrote. The block names the source and attributes the
    # verb: "Orfordness Lighthouse — explains this."
    #
    # Explains and contradicts only (v1) — those are the two that carry weight
    # when a reader arrives on the claim rather than the explanation.
    def inbound_refs
      return @inbound_refs if defined?(@inbound_refs)

      rows = ::Curiobase::SubjectEdges.inbound(slug)
      if rows.empty?
        @inbound_refs = nil
        return nil
      end

      sec = node("div", class: "cb-inbound")
      head = node("p", class: "cb-inbound-head")
      head.content = I18n.t("curiobase.inbound.heading")
      sec.add_child(head)

      list = node("ul", class: "cb-inbound-list")
      rows
        .sort_by { |r| [::Curiobase::SubjectEdges::INBOUND_VERBS.index(r.verb) || 99, r.from_title.to_s] }
        .each do |row|
          li = node("li", class: "cb-inbound-row", "data-verb": row.verb)
          a = node("a", href: ref_href(row.from_slug))
          a.content = row.from_title.presence || row.from_slug
          li.add_child(a)
          li.add_child(text(" — "))
          verb = node("span", class: "cb-inbound-verb")
          verb.content = I18n.t("curiobase.inbound.#{row.verb}", default: "#{row.verb} this")
          li.add_child(verb)
          list.add_child(li)
        end
      sec.add_child(list)
      @inbound_refs = sec
    end

    # ⚠ `supports` and `contradicts` are the reason the claim kind exists. The
    #   schema makes you state BOTH so neither a drafting model nor a
    #   cataloguer having a strong day can smuggle a one-sided account past it.
    #   They are paragraphs and they get paragraph treatment.
    def prose
      list = @r["prose"]
      return nil unless list.is_a?(Array) && list.any?
      sec = node("div", class: "cb-prose")
      list.each do |p|
        next if p["body"].blank?
        h = node("h3", class: "cb-prose-label")
        h.content = p["label"].to_s
        sec.add_child(h)
        sec.add_child(para("cb-prose-body", p["body"]))
      end
      sec.children.any? ? sec : nil
    end

    def links
      list = Array(@r["links"]).select { |l| l["url"].present? }
      coords = @r["coords"]
      return nil if list.empty? && coords.blank?

      p = node("p", class: "cb-links")
      list.each_with_index do |l, i|
        p.add_child(Nokogiri::XML::Text.new(" · ", @doc.document)) if i.positive?
        a = node("a", href: l["url"], rel: "noopener")
        a.content = l["label"].presence || l["url"]
        p.add_child(a)
      end
      if coords.present?
        # The one field a reader can do nothing with as text.
        p.add_child(Nokogiri::XML::Text.new(" · ", @doc.document)) if p.children.any?
        a = node("a", href: "https://www.openstreetmap.org/?mlat=#{coords.split(",").first.to_s.strip}" \
                            "&mlon=#{coords.split(",").last.to_s.strip}#map=14/#{coords.tr(" ", "").tr(",", "/")}",
                      rel: "noopener")
        a.content = I18n.t("curiobase.on_a_map")
        p.add_child(a)
      end
      p
    end

    # Period, evidence and status are the facets the whole site navigates by,
    # and the card showed none of them until every kind was rendered at once.
    def facets
      rows = {
        I18n.t("curiobase.facets.period") => Array(@r["period"]).join(" · "),
        I18n.t("curiobase.facets.evidence") => Array(@r["evidence"]).map { |e| e.tr("-", " ") }.join(" · "),
        I18n.t("curiobase.facets.also_known_as") => @r["also_known_as"].to_s,
      }
      kv_list(rows, "cb-facts cb-facets")
    end

    # ⚠ A recovered document can be tens of thousands of words and it must never
    #   lead the card — one exhibit's meta description was, verbatim,
    #   "**** * CONFIDENTIAL * ****". Collapsed, last, and clearly quoted.
    def full_text
      d = node("details", class: "cb-fulltext")
      s = node("summary")
      s.content = I18n.t("curiobase.full_text")
      d.add_child(s)
      pre = node("pre", class: "cb-fulltext-body")
      pre.content = @r["full_text"].to_s
      d.add_child(pre)
      d
    end

    def landing_link
      p = node("p", class: "cb-landing")
      a = node("a", href: @r["landing_url"])
      a.content = I18n.t("curiobase.read_more", title: @r["title"])
      p.add_child(a)
      p
    end

    def associations
      assoc = Associations.new(slug)
      rows = assoc.rows
      return empty_associations if rows.empty?

      resolve_active!(assoc)

      # Held so `thumbs?` can ask whether ANY row in this list has a cover
      # before the first row decides whether to draw a cell.
      @assoc_rows = rows

      block = node("section", class: "cb-assoc", "data-subject": slug, "data-default": @active)
      h = node("h2", class: "cb-assoc-head")
      h.content = I18n.t("curiobase.associations_heading")
      block.add_child(h)
      if (signal = status_membership_note)
        block.add_child(signal)
      end
      block.add_child(filters(assoc.counts, assoc.shown_counts))

      list = node("ol", class: "cb-assoc-list#{thumbs? ? " cb-assoc-list--thumbs" : ""}")
      rows.each { |r| list.add_child(assoc_row(r)) }
      block.add_child(list)

      # ⚠ THE DELIBERATE "SHOW ME EVERYTHING" ACT, and it did not exist.
      #
      #   The list caps at MAX_PER_TYPE and simply stopped. A Subject with 84
      #   tagged topics rendered 25 of them and gave the reader no indication the
      #   other 59 were there — on a site whose entire pitch is a 28-year
      #   archive, and where the archive is the largest part of most lists.
      #
      #   The curated list is the institute's answer to "what should I look at".
      #   This link is the answer to "no, show me all of it", and they are
      #   different questions that deserve different surfaces. The tag page is
      #   the right destination for the second one: it is Discourse's own
      #   complete list, it paginates, and the filter chips already point there.
      block.add_child(see_everything(assoc)) if assoc.truncated?

      # The numbers in this list mean nothing without their scale. A Subject
      # page mixes films and government reports, so the wording falls back to
      # the neutral set unless every Work here shares one mode.
      #
      # ⚠ Banner variant omits it: the banner is a signpost to the file, and a
      #   scale legend on a signpost is noise.
      block.add_child(Anchors.para_node(@doc.document, Anchors.key_for_modes(assoc.modes))) if @variant == :full

      block
    end

    def resolve_active!(assoc)
      @active ||= @active_filter_param.presence || assoc.default_filter
    end
    private :resolve_active!

    # Vacancy, not silence. Teach the pairing rule where the list would be.
    def empty_associations
      block = node("section", class: "cb-assoc cb-assoc--empty")
      h = node("h2", class: "cb-assoc-head")
      h.content = I18n.t("curiobase.associations_heading")
      block.add_child(h)
      block.add_child(para("cb-assoc-invite", I18n.t("curiobase.assoc_empty")))
      block
    end

    # Staff `status:` can say the file is settled while members still split on
    # how hard Works pull on it. Surface that without replacing either signal.
    def status_membership_note
      return nil unless SETTLED_STATUSES.include?(@r["status"].to_s)
      return nil unless @assoc_rows.to_a.any? { |r| r.kind == "work" && r.gravity&.disagree? }

      para("cb-status-signal", I18n.t("curiobase.status_membership_split", status: @r["status"].to_s.tr("-", " ")))
    end

    # ⚠ Real links to the TAG PAGE, not JavaScript tabs and not the topic.
    #
    #   ?curiobase=film narrows Discourse's own topic list server-side, so a
    #   crawler follows the chip and finds a genuinely different, complete page
    #   — and a reader with no scripting gets the same thing.
    #
    #   The canonical tag URL is /tag/<slug>/<id>. Linking /tag/<slug> works but
    #   301s on every click, which is a redirect hop Google has to spend budget
    #   on for no reason.
    def filters(counts, shown = {})
      # A subject nothing engages yet renders "Works 0", which is a control that
      # does nothing next to a number that says so. Show nothing instead.
      return node("span", class: "cb-filters cb-filters--empty") if counts["all"].to_i.zero?

      nav = node("nav", class: "cb-filters")
      # Works first — catalogue ladder. Omitted when the subject only has threads.
      if counts["works"].to_i.positive?
        nav.add_child(
          chip(I18n.t("curiobase.filter_works"), counts["works"], "works", shown["works"]),
        )
      end
      FILTERS.each do |k|
        n = counts[k].to_i
        next if n.zero?
        nav.add_child(chip(I18n.t("curiobase.kinds.#{k}", default: k), n, k, shown[k]))
      end
      nav
    end

    # ⚠ A REAL LINK THAT SCRIPT INTERCEPTS — not a button, and not a link that
    #   is left to navigate.
    #
    #   Navigating is the wrong outcome on a Subject file: the association list
    #   is ordered by the institute's judgement and the tag page is ordered by
    #   `bumped_at`, so clicking "Film" on a ranked list used to drop the reader
    #   into an unranked one. Filtering in place keeps the ranking.
    #
    #   It stays an anchor with a working href because that is what a crawler
    #   follows and what a reader without scripting gets — and both of those
    #   land somewhere complete and correct. See curiobase-filters.js.
    # ⚠ `data-count` is the TRUE total from SQL; `data-shown` is how many rows
    #   this chip will actually reveal. They differ by design — the chip says
    #   "Book 17", the list holds the best 10, and the gap is precisely what the
    #   "view all" exit is for. The script needs both to decide whether to offer
    #   that exit, and it must not infer either by counting rendered rows: the
    #   list is a union, so a count of visible rows is not a count of anything.
    def chip(label, count, kind, shown = nil)
      key = kind.to_s
      a =
        node(
          "a",
          class: "cb-filter#{" is-active" if @active == key}",
          href: tag_url(key),
          "data-kind": key,
          "data-count": count.to_i.to_s,
          "data-shown": shown.to_i.to_s,
        )
      a.content = "#{label} #{count}"
      a
    end

    def tag_url(kind)
      base =
        if (t = tag_record)
          "/tag/#{t.name}/#{t.id}"
        else
          "/tag/#{slug}"
        end
      # Works = unfiltered tag page (catalogue + threads). Medium / discussion
      # chips narrow with ?curiobase=.
      return base if kind.blank? || kind == "works"
      "#{base}?curiobase=#{kind}"
    end

    def tag_record = tag_for(slug)

    # ══════════════════════════════════════════════════════════════════════════
    # A THUMBNAIL ON THE TAG PAGE, NOT THE PLATE.
    # ══════════════════════════════════════════════════════════════════════════
    #
    # ⚠ Deliberately small. The banner exists to identify the Subject and send
    #   the reader to its file; repeating the full plate here would make the tag
    #   page a near-duplicate of the record topic and the two would compete for
    #   the same query — the split-ranking problem §VI.2 of ARCHITECTURE warns
    #   about. Enough picture to recognise the thing, not enough to be the page.
    #
    # ⚠ Read from the cached URL, never lifted: there is no post to lift from on
    #   a tag page.
    def banner_thumb
      url = record_image_url
      return node("span", class: "cb-banner-thumb cb-banner-thumb--empty") if url.blank?

      fig = node("span", class: "cb-banner-thumb")
      fig.add_child(node("img", src: url, alt: "", loading: "lazy", decoding: "async"))
      fig
    end

    def record_image_url
      return @record_image_url if defined?(@record_image_url)
      id = RecordTopic.find(slug, type: :subject)
      @record_image_url =
        id && TopicCustomField.where(topic_id: id, name: CardRenderer::POSTER_FIELD).pick(:value)
    end

    # ⚠ ALL OR NOTHING PER LIST. A column of empty grey boxes beside two real
    #   covers is worse than no column: it reads as broken rather than as
    #   incomplete, and it spends width on nothing. So the thumbs appear only
    #   once at least one row in THIS list has a cover — and once they do, every
    #   row reserves the cell so the titles stay aligned.
    #
    #   Which means the list is text-only until posters exist, then becomes a
    #   picture list on its own. No setting, no decision.
    def thumbs?
      return @thumbs if defined?(@thumbs)
      @thumbs = @assoc_rows.to_a.any? { |r| r.poster.present? }
    end

    # ⚠ `loading: lazy` and `decoding: async` are not optional here. A Subject
    #   with 25 associated Works is 25 images on a page a crawler hits often;
    #   without them the list blocks render on images below the fold.
    def assoc_thumb(r)
      cell = node("span", class: "cb-assoc-thumb")
      return cell if r.poster.blank?

      img = node("img", src: r.poster, alt: "", loading: "lazy", decoding: "async")
      cell.add_child(img)
      cell
    end

    def see_everything(assoc)
      p = node("p", class: "cb-assoc-all")
      a = node("a", class: "cb-assoc-all-link", href: tag_url(nil))
      # Naming the real number is the point. "See more" tells a reader nothing;
      # "All 84 topics" tells them the archive is worth opening.
      a.content = I18n.t("curiobase.see_everything", count: assoc.counts["all"].to_i, title: @r["title"])
      p.add_child(a)
      p
    end

    # ══════════════════════════════════════════════════════════════════════════
    # AN EYEBROW OVER THE TITLE, NOT A COLUMN BESIDE IT.
    # ══════════════════════════════════════════════════════════════════════════
    #
    # ⚠ The kind used to be its own grid column, so a row read
    #   `[thumb] BOOK  The Voynich Manuscript (2016)` — three things competing
    #   across one line, and 5.5em of width spent on a word that is already
    #   implied by the cover beside it. As an eyebrow it labels the title
    #   instead of racing it, and the title gets the space back.
    #
    #   This is how Discourse itself stacks a topic: the loud thing first, the
    #   quiet metadata attached to it.
    def assoc_row(r)
      kind = r.kind == "discussion" ? "discussion" : r.medium.to_s
      # ══════════════════════════════════════════════════════════════════════
      # `data-buckets` IS MEMBERSHIP. `data-kind` IS ONLY WHAT THE THING IS.
      # ══════════════════════════════════════════════════════════════════════
      #
      # The card is baked, so every filter state is already in this HTML. A row
      # can be #14 overall and #3 among books, so it belongs under "Book" and
      # not under "Works" — and a different row can be #11 among books and belong
      # under neither. Filtering on `data-kind` would show both, because a
      # medium says what a row is and not whether it earned its place.
      li =
        node(
          "li",
          class: "cb-assoc-row",
          "data-kind": kind,
          "data-buckets": Array(r.buckets).join(" "),
        )
      if r.kind == "work" && r.work_id.present?
        li["data-work"] = r.work_id.to_s
        li["data-subject"] = slug
      end
      # Live re-sort keys for curiobase-assoc-live.js — same order as Scores.rank_key.
      if r.kind == "work" && r.gravity&.rated?
        li["data-gravity"] = format("%.2f", r.gravity.display.to_f)
      end
      li["data-recommend"] = r.recommendations.to_i.to_s
      li["data-posts"] = r.posts_count.to_i.to_s
      # Default view is Works (or Discussions when there are no Works). Hide
      # rows that are not members of the active bucket so the baked union is
      # not the initial paint for no-JS readers (JS apply() does the same).
      li["hidden"] = "hidden" unless Array(r.buckets).include?(@active)

      li.add_child(assoc_thumb(r)) if thumbs?

      main = node("span", class: "cb-assoc-main")

      eyebrow = node("span", class: "cb-assoc-kind")
      eyebrow.content = assoc_eyebrow(r)
      main.add_child(eyebrow)

      a = node("a", class: "cb-assoc-title", href: r.url)
      a.content = r.title
      main.add_child(a)
      li.add_child(main)

      # ⚠ BOTH CELLS ALWAYS, EVEN WHEN EMPTY. The row is a grid, so the columns
      #   only line up if every row emits the same cells. Rendering them
      #   conditionally let each row size its own columns and the numbers came
      #   out ragged down the list.
      li.add_child(gravity_cell(r))
      li.add_child(recommend_cell(r))
      li
    end

    def gravity_cell(r)
      cell = node("span", class: "cb-assoc-meta cb-assoc-gravity")

      if r.kind == "discussion"
        # ⚠ Discussions are not scored. A thread is a conversation about an
        #   idea, not a treatment of one.
        cell["class"] = "cb-assoc-meta cb-assoc-replies"
        cell.content = I18n.t("curiobase.replies", count: r.replies.to_i)
        return cell
      end

      # ⚠ Tagged, but nobody has voted on this pairing yet. Keep the row — it is
      #   a valid exit and an invitation — and keep the column width. The call
      #   to action lives on the card, not in a list row.
      unless r.gravity&.rated?
        cell["class"] = "cb-assoc-meta cb-unrated"
        cell["title"] = I18n.t("curiobase.unrated")
        cell.content = "—"
        return cell
      end

      value = r.gravity.display.to_f
      # data-strength drives a colour ramp in CSS. Redundant encoding — the
      # number is right there — so colour is never the only carrier of meaning.
      cell["data-strength"] = value.round.clamp(1, 5).to_s
      title = I18n.t("curiobase.gravity_heading")
      if r.gravity.disagree?
        cell["class"] = "cb-assoc-meta cb-assoc-gravity cb-assoc-gravity--split"
        cell["data-disagree"] = "1"
        title = "#{title} · #{I18n.t("curiobase.members_disagree")}"
      end
      cell["title"] = title

      dot = node("span", class: "cb-glyph", "aria-hidden": "true")
      dot.content = "●"
      cell.add_child(dot)
      cell.add_child(Nokogiri::XML::Text.new(format("%.1f", value), @doc.document))
      cell
    end

    # ⚠ A COUNT OF PEOPLE beside a number out of five — different glyph,
    #   different colour, so the two can never be misread for each other.
    #   Blank at zero: "0 recommend" reads as a verdict when it is silence.
    def recommend_cell(r)
      n = r.recommendations.to_i
      cell = node("span", class: "cb-assoc-meta cb-recommend")
      return cell unless n.positive?

      # The glyph carries nothing a screen reader can use, so it is hidden and
      # the cell is labelled with the whole sentence instead.
      label = I18n.t("curiobase.recommend", count: n)
      cell["aria-label"] = label
      cell["title"] = label

      heart = node("span", class: "cb-glyph", "aria-hidden": "true")
      heart.content = "♥"
      cell.add_child(heart)
      cell.add_child(Nokogiri::XML::Text.new(n.to_s, @doc.document))
      cell
    end

    # Episode rows lead with the series family; everything else keeps medium.
    def assoc_eyebrow(r)
      if r.series_title.present?
        bits = [r.series_title]
        if r.season.to_i.positive? && r.episode.to_i.positive?
          bits << "S#{r.season.to_i}E#{r.episode.to_i}"
        elsif r.episode.to_i.positive?
          bits << "E#{r.episode.to_i}"
        end
        return bits.join(" · ")
      end

      kind = r.kind == "discussion" ? "discussion" : r.medium.to_s
      I18n.t("curiobase.kind.#{kind}", default: kind)
    end

  end
end
