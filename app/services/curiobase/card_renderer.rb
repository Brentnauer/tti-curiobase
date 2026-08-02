# frozen_string_literal: true

module Curiobase
  # Bakes a Curiobase card into posts.cooked.
  #
  # ══════════════════════════════════════════════════════════════════════════
  # THIS IS THE WHOLE ARCHITECTURE. Everything else is plumbing around it.
  # ══════════════════════════════════════════════════════════════════════════
  #
  # CookedPostProcessor hands over the Nokogiri document after sanitisation and
  # before posts.cooked is written. Whatever we put here is:
  #
  #   * in the database
  #   * in the crawler view — the topic template emits post.cooked.html_safe
  #   * visible with JavaScript disabled
  #   * NOT re-sanitised, so microdata and <dl> pass through intact
  #
  # Idempotent by construction: CookedPostProcessor re-cooks from raw every
  # time, so injection cannot accumulate across rebakes.
  #
  # ⚠ THE ORDER RULE. Discourse builds meta description from the START of
  #   cooked. Lead with a fact table and the snippet becomes "Medium Film Year
  #   2004 Creator Shane Carruth". Lead with a recovered document and one
  #   exhibit's snippet was, verbatim, "**** * CONFIDENTIAL * ****".
  #
  #   THE DEK GOES FIRST. It is a sentence. This has regressed twice.
  class CardRenderer
    include Markup

    MARKER = "curiobase-card"
    POSTER_FIELD = "curiobase_poster"

    # [wrap=work id=123] cooks to
    #   <div class="d-wrap" data-wrap="work" data-id="123">
    # Reading the cooked element rather than the raw text means the BBCode
    # parser has already done the parsing.
    SELECTOR = '.d-wrap[data-wrap="work"], .d-wrap[data-wrap="subject"]'

    def initialize(doc, post)
      @doc = doc
      @post = post
      @topic = post&.topic
    end

    def render!
      return unless @post&.is_first_post?
      return if @doc.at_css(".#{MARKER}")

      # ⚠ A record authored in its own post takes precedence over a legacy
      #   wrap. Everything downstream of here is identical — the parser hands
      #   back the same shape the fixtures do, on purpose, so no renderer can
      #   tell where a record came from.
      return if render_post_authored!

      wrap = @doc.at_css(SELECTOR)
      return unless wrap

      kind = wrap["data-wrap"]
      id = wrap["data-id"].presence
      return unless id

      record = kind == "work" ? Source.work(id) : Source.subject(id)
      unless record
        # Source miss (bad id, or fixture not found for a legacy wrap). Leave
        # the post alone rather than replacing it with an error — a stale card
        # beats a broken page.
        Rails.logger.warn("[curiobase] no #{kind} #{id} for post #{@post.id}")
        return
      end

      remember_kind(kind, record)

      # A Subject card is built by SubjectCard, because the tag page needs the
      # same HTML and two implementations would drift. Nokogiri#replace takes a
      # string, and nothing here is re-sanitised, so the markup survives intact.
      if kind == "subject"
        card = Nokogiri::HTML5.fragment(SubjectCard.new(record).to_html)
        wrap.replace(card.to_html)
      else
        card = node("div", class: "#{MARKER} #{MARKER}--#{kind}", "data-id": id)
        build_work(card, record)
        wrap.replace(card)
      end

      # Last — after any poster/kind custom-field saves inside build_work.
      remember_edges(kind, record)
    end

    # The post IS the record. Returns true when it handled the post.
    def render_post_authored!
      block = @doc.at_css("pre code.lang-curiobase, pre code[class*='curiobase']")
      return false unless block

      result = PostRecord.parse(@post.raw)
      # ⚠ Invalid records cannot normally reach here — the validator rejects
      #   them on save. This is the path for a record that was valid when it was
      #   written and became invalid when the vocabulary changed underneath it.
      #   Leave the block visible rather than swallowing it: the author needs to
      #   see that something is wrong, and a code block is legible.
      return false unless result&.valid?

      # ⚠ `topic:` is what gives the record its title — see PostRecord.to_record.
      #   Without it every card on a record's own topic page had a blank title,
      #   and the visible symptom was a link reading "Read more about" with
      #   nothing after it.
      record = PostRecord.to_record(result, topic: @topic)
      return false if record.blank?

      kind = record["type"]
      remember_kind(kind, record)

      # The fenced block is scaffolding, not content. Take it out before the
      # card goes in, or the reader sees the source underneath the render.
      container = block.ancestors("pre").first || block

      if kind == "subject"
        # ⚠ The plate is handed to SubjectCard rather than appended afterwards.
        #   Appending put a 104px thumbnail at the BOTTOM of the card, under the
        #   association list — which is why a Subject's image never looked like
        #   it belonged to anything. SubjectCard places it after the dek, where
        #   it reads as a plate in a file.
        card = Nokogiri::HTML5.fragment(SubjectCard.new(record, plate: media(:plate)).to_html)
        container.replace(card.to_html)
      else
        @work_record = record
        card = node("div", class: "#{MARKER} #{MARKER}--work", "data-id": record["slug"])
        build_work(card, record)
        container.replace(card)
      end

      # Last — after media(:plate) / build_work may have save_custom_fields'd.
      remember_edges(kind, record)

      true
    end

    # The image the author dragged in, already processed by Discourse.
    #
    # ⚠ Memoised per variant AND take!-once. `take!` REMOVES the image from the
    #   body, so calling it twice returns nil the second time and the card
    #   silently loses its picture.
    def media(variant)
      @media ||= {}
      return @media[variant] if @media.key?(variant)

      m = PostMedia.new(@doc, @post, variant: variant)
      node = m.take!
      # Cached for BOTH kinds: a Work's poster feeds the association list, a
      # Subject's plate feeds the tag-page banner. The field means "this
      # record's image", whichever shape it is.
      remember_poster(m.src) if node
      @media[variant] = node
    end

    def hero = media(:poster)

    # Cache what this topic IS, so ?curiobase=film can filter the tag page in
    # SQL instead of asking WordPress about every topic in a list.
    #
    # Written here because this is the one place that has already resolved the
    # record. Guarded so a rebake that changes nothing writes nothing.
    def remember_kind(kind, record)
      return unless @topic

      # Which record this topic IS, so every link to a Subject can land on its
      # file instead of its tag page. See RecordTopic.
      # ⚠ BOTH KINDS, not just subjects. Source resolves a slug back to its post
      #   through this index, so a Work that is not in it is a Work that keeps
      #   being fetched from WordPress even after it has been converted.
      RecordTopic.remember(@topic, record["slug"])
      describe_tag(record) if kind == "subject"

      value = kind == "subject" ? "subject" : record["medium"].to_s
      return if value.blank?
      return if @topic.custom_fields[TopicKind::FIELD] == value
      @topic.custom_fields[TopicKind::FIELD] = value
      @topic.save_custom_fields
    end

    # Outbound edges → `curiobase_edge` rows on this topic; fan-out rebakes
    # targets so their inbound block / JSON-LD stay honest. Debounced per
    # target via schedule_subject_file_rebake! (same 60s redis gate as votes).
    #
    # ⚠ Call LAST in the render path — after every `save_custom_fields`.
    #   Discourse's hash sync deletes TopicCustomField rows that are not in
    #   `topic.custom_fields`, so multi-row `curiobase_edge` written earlier
    #   would be wiped by kind / slug / poster saves.
    def remember_edges(kind, record)
      return unless @topic

      targets =
        if kind == "subject"
          ::Curiobase::SubjectEdges.replace!(@topic, record["refs"])
        else
          ::Curiobase::SubjectEdges.clear!(@topic)
        end

      self_slug = record["slug"].to_s
      targets.each do |slug|
        next if slug.blank? || slug == self_slug
        Curiobase.schedule_subject_file_rebake!(slug)
      end
    end

    # ══════════════════════════════════════════════════════════════════════════
    # THE DEK BECOMES THE TAG'S DESCRIPTION.
    # ══════════════════════════════════════════════════════════════════════════
    #
    # Discourse renders a tag page's meta description straight from the tag row:
    #
    #   @description_meta = Tag.where(name: @tag_name).pick(:description) || @title
    #     — app/controllers/tags_controller.rb
    #
    # So /tag/majestic-12 was serving "Topics tagged majestic-12" as its search
    # snippet purely because nothing had ever filled that column in.
    #
    # ⚠ THE FIRST ATTEMPT AT THIS WAS WRONG and is worth recording. A second
    #   `<meta name="description">` was emitted from the crawler head builder.
    #   Measured: the page then had TWO, and a crawler reads the first — so the
    #   good one was the loser. Writing the value Discourse already reads is the
    #   whole fix, and it also populates the tag description in the UI.
    #
    # ⚠ Same discipline as the other caches: written here because this is the one
    #   place that has already resolved the record, and guarded so a rebake that
    #   changes nothing writes nothing. The dek is capped at 200 characters and
    #   the column takes 1000, so it always fits.
    # ══════════════════════════════════════════════════════════════════════════
    # THE POSTER URL, CACHED ON THE TOPIC.
    # ══════════════════════════════════════════════════════════════════════════
    #
    # So a Subject's association list can show a thumbnail beside each Work
    # without opening 25 posts to find 25 images. Same discipline as
    # `curiobase_kind` and `curiobase_slug`: written here, by the one piece of
    # code that has already resolved the image, and read in one batched query.
    #
    # ⚠ Without this the list would be an N+1 on a page crawlers hit constantly
    #   — the exact shape of the `ILIKE` scan that RecordTopic exists to avoid.
    def remember_poster(url)
      return if @topic.blank? || url.blank?
      return if @topic.custom_fields[POSTER_FIELD] == url

      @topic.custom_fields[POSTER_FIELD] = url
      @topic.save_custom_fields
    end

    def describe_tag(record)
      dek = record["dek"].to_s.strip
      return if dek.blank?

      tag = Tag.find_by(name: record["slug"])
      return unless tag
      return if tag.description.to_s.strip == dek

      # ⚠ `update`, NOT `update_columns`. Tag#sanitize_description runs as a
      #   before_save and this value is rendered as HTML on the tag page. Going
      #   round the callback to save a timestamp write would put unsanitised
      #   author input into a page.
      tag.update(description: dek)
    rescue StandardError => e
      # A tag description is a nicety; a record that will not bake is not.
      Rails.logger.warn("[curiobase] could not describe tag #{record["slug"]}: #{e.class}")
    end

    private

    # ── work ────────────────────────────────────────────────────────────────
    def build_work(card, w)
      # Held for the gravity block, which needs the Work's own `gravity` rows
      # and its `mode` to choose the anchor wording.
      @work_record = w

      SeriesEpisodes.remember!(@topic, w["series"])
      embed = Embeds.for_record(w, @topic)

      head = node("div", class: work_head_class(w, embed))
      attach_work_media(head, w, embed)

      body = node("div", class: "cb-body")

      # 1 · the dek. A sentence, FIRST IN THE DOM, always. See the order rule.
      #
      # ⚠ The badges used to be here and they broke the rule for a third time:
      #   every meta description started "seriesfiction …", "documenthidden
      #   historydebunked …". Badge text has no spaces between elements once
      #   tags are stripped, so it reads as one nonsense word and burns thirty
      #   characters of a snippet Google truncates at about 155.
      #
      #   They still LOOK like they come first — .cb-badges carries order: -1.
      #   Visual order is CSS's job; document order belongs to the crawler.
      body.add_child(para("cb-dek", w["dek"])) if w["dek"].present?
      body.add_child(badge(w["medium"], w["mode"]))
      body.add_child(series_line(w)) if w["series"].present?

      # 2 · facts as one inline row. Five facts do not need five lines.
      facts = [w["year"]&.to_s, w["creator"], w["runtime"]].compact_blank
      se = [season_episode_label(w)].compact_blank
      facts = se + facts if se.any?
      body.add_child(para("cb-meta", facts.join(" · "))) unless facts.empty?

      links = external_links(w["external"], omit: embed_omit_keys(embed))
      body.add_child(links) if links

      head.add_child(body)
      card.add_child(head)

      # Discord stock order: identity block, then media, then the rest.
      # Video / trailer / Books / Archive all land here — never inside .cb-head.
      card.add_child(embed_stage(embed)) if embed

      card.add_child(gravity_block(w))
      # episodes_block returns nil when the hub has no children yet — never
      # add_child(nil); Nokogiri raises and the cook rescue leaves an empty wrap.
      if (eps = episodes_block(w))
        card.add_child(eps)
      end
      buy = buy_links(w)
      card.add_child(buy) if buy
    end

    # Video is the work itself — no poster column in the head (the stage is the
    # player). Everything else keeps a poster column (attachment, authored URL,
    # or labelled empty tile).
    def work_head_class(w, _embed = nil)
      skip_poster?(w) ? "cb-head cb-head--text" : "cb-head"
    end

    def skip_poster?(w)
      %w[video].include?(w["medium"].to_s)
    end

    def attach_work_media(head, w, _embed = nil)
      if skip_poster?(w)
        # Still lift a dragged image (or cache poster.url) so it does not sit
        # under the card, and so Subject association rows can thumb it. Never
        # render it in the video head — that would compete with the stage.
        claim_list_poster!(w)
        return
      end

      attached =
        if (dragged = hero)
          head.add_child(dragged)
          true
        elsif (poster = w.dig("poster", "url")).present?
          fig = node("div", class: "cb-poster")
          img = node("img", src: poster, alt: w.dig("poster", "alt").to_s, loading: "lazy")
          fig.add_child(img)
          head.add_child(fig)
          remember_poster(poster)
          true
        else
          # Never auto-fill from Archive / Books / YouTube. Poster is an
          # author attachment (or the labelled empty tile until they add one).
          head.add_child(poster_placeholder(w))
          true
        end

      head["class"] = "cb-head cb-head--text" unless attached
    end

    # Video: take! the body image (remember_poster runs inside media()) without
    # placing a poster column. Authors download a YouTube thumbnail and drag it
    # in — we never fetch host covers. Fence has no poster key (ELSEWHERE).
    def claim_list_poster!(w)
      return if hero

      # Fixture / legacy shape only — post-authored records use the drag path.
      poster = w.dig("poster", "url")
      remember_poster(poster) if poster.present?
    end

    # Full-width media strip between the identity head and gravity.
    def embed_stage(embed)
      stage = node("div", class: "cb-stage", "data-provider": embed.provider)
      stage.add_child(embed_chrome(embed))
      stage
    end

    # YouTube / Google Books / Archive → iframe; otherwise link card.
    def embed_chrome(embed)
      return embed_iframe(embed) if embed.iframe?
      embed_link_card(embed)
    end

    def embed_omit_keys(embed)
      case embed&.provider
      when "youtube" then %w[youtube]
      when "archive" then %w[archive_org]
      when "google_books" then %w[google_books]
      else []
      end
    end

    def embed_iframe(embed)
      kind = embed.secondary? ? "trailer" : "hero"
      extra =
        case embed.provider
        when "google_books" then " cb-embed--gbooks"
        when "archive" then " cb-embed--archive"
        else ""
        end
      fig =
        node(
          "div",
          class: "cb-embed cb-embed--#{kind}#{extra}",
          "data-provider": embed.provider,
        )
      iframe =
        node(
          "iframe",
          src: embed.src,
          title: embed.label,
          loading: "lazy",
          allowfullscreen: "allowfullscreen",
          referrerpolicy: "strict-origin-when-cross-origin",
          allow:
            "accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share",
        )
      iframe["frameborder"] = "0"
      # Discourse onebox/CSS hooks key off this; keep our player unmarked.
      iframe["class"] = "cb-embed-frame"
      fig.add_child(iframe)
      fig
    end

    def embed_link_card(embed)
      a =
        node(
          "a",
          class: "cb-media-link track-link",
          href: embed.href,
          rel: "noopener",
          target: "_blank",
          "data-provider": embed.provider,
        )
      # No host thumbs here — posters are attachment-only on the card head.
      meta = node("span", class: "cb-media-link-meta")
      eye = node("span", class: "cb-media-link-label")
      eye.content = embed.label
      meta.add_child(eye)
      host = node("span", class: "cb-media-link-host")
      host.content = media_link_host(embed)
      meta.add_child(host)
      a.add_child(meta)
      a
    end

    def media_link_host(embed)
      case embed.provider
      when "youtube" then "YouTube"
      when "archive" then "archive.org"
      when "google_books" then "Google Books"
      else embed.provider.to_s
      end
    end

    # Episode → series hub. The rateable unit stays the episode; this is the
    # exit to the family without making the series absorb gravity.
    def series_line(w)
      slug = w["series"].to_s
      return nil if slug.blank?

      hub = Source.work(slug)
      title = hub&.dig("title").presence || PostRecord.titleize(slug)
      url = record_url(slug, type: :work)

      p = node("p", class: "cb-series")
      p.add_child(Nokogiri::XML::Text.new("#{I18n.t("curiobase.part_of")} ", @doc.document))
      if url
        a = node("a", class: "cb-series-link", href: url)
        a.content = title
        p.add_child(a)
      else
        p.add_child(Nokogiri::XML::Text.new(title, @doc.document))
      end
      p
    end

    def season_episode_label(w)
      s = w["season"].to_i
      e = w["episode"].to_i
      return nil if s <= 0 && e <= 0
      if s.positive? && e.positive?
        I18n.t("curiobase.season_episode", season: s, episode: e)
      elsif e.positive?
        I18n.t("curiobase.episode_only", episode: e)
      else
        I18n.t("curiobase.season_only", season: s)
      end
    end

    def episodes_block(w)
      rows = SeriesEpisodes.for(w["slug"])
      return nil if rows.empty?

      block = node("section", class: "cb-episodes", "data-hub": w["slug"].to_s, id: "cb-episodes-#{w["slug"]}")
      h = node("h2", class: "cb-episodes-head")
      h.content = I18n.t("curiobase.episodes_heading")
      block.add_child(h)
      block.add_child(episodes_tools(rows, w["slug"].to_s))

      list = node("ol", class: "cb-episodes-list")
      rows.each do |r|
        li = node("li", class: "cb-episodes-row")
        li["data-work"] = r.work_id.to_s if r.work_id.present?
        li["data-season"] = r.season.to_i.to_s
        li["data-episode"] = r.episode.to_i.to_s
        li["data-recommend"] = r.likes.to_i.to_s
        li["data-title"] = r.title.to_s.downcase

        main = node("span", class: "cb-episodes-main")
        if (label = season_episode_label("season" => r.season, "episode" => r.episode))
          eye = node("span", class: "cb-episodes-num")
          eye.content = label
          main.add_child(eye)
        end
        a = node("a", class: "cb-episodes-title", href: r.url)
        a.content = r.title
        main.add_child(a)
        li.add_child(main)

        meta = node("span", class: "cb-episodes-meta")
        n = r.likes.to_i
        if n.positive?
          rec = node("span", class: "cb-episodes-likes")
          label_txt = I18n.t("curiobase.recommend", count: n)
          rec["aria-label"] = label_txt
          rec["title"] = label_txt
          heart = node("span", class: "cb-glyph", "aria-hidden": "true")
          heart.content = "♥"
          rec.add_child(heart)
          rec.add_child(Nokogiri::XML::Text.new(n.to_s, @doc.document))
          meta.add_child(rec)
        end
        li.add_child(meta)
        list.add_child(li)
      end
      block.add_child(list)
      block
    end

    # Season chips + sort — Discourse filter-chip vocabulary, client-only.
    # Anchors (not <button>) so PrettyText keeps them in cooked HTML.
    # href targets this section so no-JS clicks stay put instead of jumping top.
    def episodes_tools(rows, hub_slug)
      tools = node("div", class: "cb-episodes-tools")
      anchor = "#cb-episodes-#{hub_slug}"

      seasons = rows.map { |r| r.season.to_i }.select(&:positive?).uniq.sort
      if seasons.length > 1
        nav =
          node(
            "nav",
            class: "cb-filters cb-episodes-seasons",
            "aria-label": I18n.t("curiobase.season_filter"),
          )
        nav.add_child(
          episode_tool_chip(I18n.t("curiobase.filter_all"), anchor, "data-season": "all", active: true),
        )
        seasons.each do |s|
          nav.add_child(
            episode_tool_chip(
              I18n.t("curiobase.season_only", season: s),
              anchor,
              "data-season": s.to_s,
            ),
          )
        end
        tools.add_child(nav)
      end

      sort =
        node(
          "div",
          class: "cb-filters cb-episodes-sort",
          role: "group",
          "aria-label": I18n.t("curiobase.episode_sort"),
        )
      sort.add_child(
        episode_tool_chip(I18n.t("curiobase.sort_air_order"), anchor, "data-sort": "air", active: true),
      )
      sort.add_child(
        episode_tool_chip(I18n.t("curiobase.sort_most_recommended"), anchor, "data-sort": "recommend"),
      )
      tools.add_child(sort)

      tools
    end

    def episode_tool_chip(label, href, active: false, **data)
      attrs = { class: "cb-filter#{' is-active' if active}", href: href, role: "button" }.merge(data)
      a = node("a", attrs)
      a.content = label
      a
    end

    def record_url(slug, type:)
      topic_id = RecordTopic.find(slug, type: type)
      return nil unless topic_id
      Topic.find_by(id: topic_id)&.relative_url
    rescue StandardError
      nil
    end

    # ══════════════════════════════════════════════════════════════════════════
    # WHERE TO BUY IT.
    # ══════════════════════════════════════════════════════════════════════════
    #
    # ⚠ `rel="nofollow sponsored"` IS NOT OPTIONAL. Google requires paid links
    #   to be marked, and an affiliate link that passes PageRank is a manual
    #   action waiting to happen — on a site whose entire strategy is organic
    #   search. `sponsored` is the specific value for paid placement.
    #
    # ⚠ The disclosure ships with the buttons, in the same block, because the
    #   FTC requires it close to the link — and because a catalogue that asks to
    #   be trusted about contested claims cannot afford an undisclosed one.
    #
    # ⚠ Renders nothing at all unless a vendor is configured. See BuyLinks.
    def buy_links(w)
      vendors = BuyLinks.for(w)
      return nil if vendors.empty?

      section = node("p", class: "cb-buy")

      label = node("span", class: "cb-buy-label")
      label.content = I18n.t("curiobase.buy_heading")
      section.add_child(label)

      paid_any = false
      vendors.each do |name, url, paid|
        paid_any ||= paid
        # ⚠ `sponsored` ONLY on the paid ones. Marking a free archive.org link
        #   as sponsored would be a false declaration to Google, and marking a
        #   paid one as ordinary is the manual action.
        rel = paid ? "nofollow sponsored noopener" : "noopener"
        a = node("a", class: "cb-buy-link#{paid ? "" : " cb-buy-link--free"}",
                      href: url, rel: rel, target: "_blank")
        a.content = name
        section.add_child(a)
      end

      # ⚠ Only when something on this line is actually paid. A card offering
      #   only the Internet Archive and a library has nothing to disclose, and
      #   claiming a commission it cannot earn is its own kind of dishonest.
      if paid_any
        note = node("span", class: "cb-buy-note")
        note.content = I18n.t("curiobase.buy_disclosure")
        section.add_child(note)
      end
      section
    end

    # Where a Work can be looked up elsewhere.
    #
    # ⚠ An external database is a destination, not a value. Never print
    #   tt0390384 at a reader — the label is the readable thing.
    #
    # ⚠ The registry moved to `Curiobase::Identifiers` when the JSON-LD needed
    #   the same list for `sameAs`. Two copies of "identifier → URL" is the shape
    #   that has cost this codebase more than any other.
    def external_links(external, omit: [])
      return nil if external.blank?
      omit = Array(omit).map(&:to_s)
      rows = Identifiers.each(external).reject { |key, _label, _url| omit.include?(key) }
      return nil if rows.empty?

      p = node("p", class: "cb-ext")
      rows.each_with_index do |(_key, label, url), i|
        p.add_child(Nokogiri::XML::Text.new(" · ", @doc.document)) if i.positive?
        a = node("a", href: url, rel: "noopener", target: "_blank")
        a.content = label
        p.add_child(a)
      end
      p
    end

    # ── gravity ─────────────────────────────────────────────────────────────
    #
    # Subjects come from Discourse TAGS, not from WordPress. Tagging a topic is
    # what creates the pairing — there is nothing else to author.
    #
    # ⚠ Only tags in the synced vocabulary count. Adding `funny` to a topic must
    #   not produce a rating row.
    def gravity_block(work)
      slugs = Curiobase::Subjects.for_topic(@topic)
      return empty_gravity if slugs.empty?

      # data-mode is read by the rating control to label its buttons with the
      # right anchor set. Baked here so the client never has to guess.
      block = node("section", class: "cb-gravity", "data-mode": work["mode"].to_s)
      h = node("h2", class: "cb-gravity-head")
      h.content = I18n.t("curiobase.gravity_heading")
      block.add_child(h)

      # ⚠ One read for every row on this card, not one per row.
      readings = Gravity.for_subjects(work, slugs)

      slugs.each do |slug|
        subject = Source.subject(slug)
        next unless subject
        # ⚠ Gravity.work_id, not work["id"]. A post-authored record has no id,
        #   so this baked data-work="" and the vote button posted nothing while
        #   the score above it rendered correctly from the slug.
        block.add_child(gravity_row(Gravity.work_id(work), subject, readings[slug.to_s]))
      end

      block.add_child(Anchors.para_node(@doc.document, Anchors.key_for_mode(work["mode"])))
      block.add_child(recommend_line) if recommend_line
      block
    end

    # No Subject tags yet — invitation, not a blank hole in the card.
    def empty_gravity
      block = node("section", class: "cb-gravity cb-gravity--empty")
      h = node("h2", class: "cb-gravity-head")
      h.content = I18n.t("curiobase.gravity_heading")
      block.add_child(h)
      block.add_child(para("cb-gravity-invite", I18n.t("curiobase.gravity_empty")))
      block
    end

    # ⚠ ONCE PER WORK, NOT ONCE PER SUBJECT ROW.
    #
    #   Gravity is a property of the PAIRING — Primer is a 5 on causal-loop and
    #   would be something else on temporal-perception. Whether the film is worth
    #   two hours is a property of the FILM, and does not change per subject.
    #   Repeating it on every row would imply it did.
    def recommend_line
      return @recommend_line if defined?(@recommend_line)

      n = Recommendations.for_topic(@topic)
      @recommend_line =
        if n.positive?
          para("cb-recommend", I18n.t("curiobase.recommend", count: n))
        end
    end

    def gravity_row(work_id, subject, reading)
      # ⚠ data-work and data-subject are what the client island rates against.
      #
      #   Nothing user-specific may be baked here. `cooked` is ONE shared blob
      #   served to everybody — a logged-out crawler, an admin, and the person
      #   who rated this yesterday all get the same bytes. Bake "your rating: 4"
      #   and it is wrong for every reader but one, and cached that way.
      #
      #   The aggregate is public and belongs in the HTML. The personal half is
      #   fetched after load. That split is not an optimisation, it is the only
      #   correct answer.
      row = node("div", class: "cb-row", "data-work": work_id.to_s, "data-subject": subject["slug"])

      name = node("div", class: "cb-row-name")
      # ⚠ THE FILE, NOT THE TAG PAGE.
      #
      #   This linked to /tag/<slug>, which contradicted 02-IA's own rule — "the
      #   file is canonical, the tag page is navigation" — in the most expensive
      #   possible way: every Work card funnelled internal links into tag pages
      #   while the files, which are the product, received none.
      #
      #   It was also worse to read. A tag page orders by bumped_at, so clicking
      #   a subject landed you on whatever got a drive-by reply most recently.
      #   The file's association list is ordered by judgement.
      #
      #   Falls back to the tag page when the Subject has no file yet.
      a = node("a", href: RecordTopic.href(subject["slug"], tag: tag_for(subject["slug"])))
      a.content = subject["title"]
      name.add_child(a)
      name.add_child(para("cb-row-dek", subject["dek"])) if subject["dek"].present?
      row.add_child(name)

      row.add_child(score(reading))
      row.add_child(vote_mount) if SiteSetting.curiobase_member_voting_enabled
      row
    end

    # Takes a Curiobase::Gravity::Reading, or nil.
    #
    # ⚠ TWO RULES, both learned the hard way.
    #
    #   1. NO BAR BELOW TWO VOTERS. One vote drawn as five segments looks like
    #      consensus. The number alone is the honest presentation until there is
    #      something to disagree about.
    #
    #   2. THE COUNT SITS AGAINST THE BAR, NOT THE NUMBER. The bar is a
    #      headcount; the number is the mean of the same eligible votes.
    def score(reading)
      wrap = node("div", class: "cb-score")

      # Tagged but nobody has voted. Not a zero — a vacancy. A 0.0 reads as a
      # verdict, and it would drag every average a reader eyeballs across a page.
      if reading.nil? || !reading.rated?
        # Em dash in the score column — the long invitation lives on the vote
        # control, not as a wrapping sentence beside the marks.
        em = node("span", class: "cb-unrated")
        em.content = "—"
        em["title"] = I18n.t("curiobase.unrated")
        em["aria-label"] = I18n.t("curiobase.unrated")
        wrap.add_child(em)
        return wrap
      end

      mean = node("span", class: "cb-mean")
      mean.content = format("%.1f", reading.display.to_f)
      wrap.add_child(mean)

      return wrap unless reading.distributed?

      # The distribution matters more than the mean. A 3.1 where everyone said 3
      # and a 3.1 where half said 1 and half said 5 are different facts, and on
      # a site about contested subjects the split is the more honest number.
      #
      # Unweighted on purpose — see Gravity. Weighting this would hide exactly
      # the disagreement it exists to show.
      dist = reading.distribution
      if dist.is_a?(Array) && dist.sum.positive?
        total = dist.sum.to_f
        bar = node("span", class: "cb-dist", "aria-hidden": "true")
        dist.each_with_index do |c, i|
          seg = node("span", class: "cb-dist-seg cb-dist-#{i + 1}")
          seg["style"] = "flex-grow:#{(c / total * 100).round(2)}"
          bar.add_child(seg)
        end
        wrap.add_child(bar)

        # The bar is aria-hidden because it duplicates nothing a screen reader
        # can use, so the member count belongs here — attached to the BAR, which
        # is genuinely n members, and not to the number, which is not.
        n = node("span", class: "cb-dist-note")
        n.content = distribution_note_text(dist, reading.voter_count)
        title = distribution_breakdown(dist)
        n["title"] = title if title.present?
        wrap.add_child(n)
      end

      wrap
    end

      # Headcount on the bar. When low and high anchors both have real weight,
      # name the disagreement — that is the contested-archive signal.
    def distribution_note_text(dist, voter_count)
      base = I18n.t("curiobase.members_rated", count: voter_count)
      return base unless Gravity.disagree?(dist)

      "#{base} · #{I18n.t("curiobase.members_disagree")}"
    end

    def distribution_breakdown(dist)
      return "" unless dist.is_a?(Array)

      dist
        .each_with_index
        .filter_map { |c, i| "#{c} at #{i + 1}" if c.to_i.positive? }
        .join(" · ")
    end

    # The mount point for the rating control.
    #
    # Empty on purpose. The control is behaviour, not content: it needs the
    # current user, a CSRF token and a live endpoint, none of which can be baked
    # into a blob that is shared by every reader and cached for months.
    #
    # No JavaScript therefore means no control — and every number still present.
    # That is the right way round. A crawler needs the score, not the widget.
    def vote_mount
      node("div", class: "cb-vote", "data-mount": "gravity")
    end

    # Same footprint as a real poster, so the grid never moves.
    def poster_placeholder(w)
      fig = node("div", class: "cb-poster cb-poster--empty")
      label = node("span", class: "cb-poster-label")
      label.content = [w["medium"], w["year"]].compact_blank.join(" · ")
      fig.add_child(label)
      fig
    end

    # ── helpers ─────────────────────────────────────────────────────────────
    # `badge` is Markup#badges. Kept as an alias because "the badge line" is
    # what the rest of this class calls it.
    def badge(*parts) = badges(*parts)

  end
end
