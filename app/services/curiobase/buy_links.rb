# frozen_string_literal: true

module Curiobase
  # Where a reader can get hold of a Work.
  #
  # ══════════════════════════════════════════════════════════════════════════
  # "FIND A COPY", NOT "BUY". FREE SOURCES COME FIRST.
  # ══════════════════════════════════════════════════════════════════════════
  #
  # This catalogue is mostly out-of-print paperbacks, public-domain documents
  # and recovered broadcasts. For a great deal of it the honest answer to *where
  # do I get this* is **the Internet Archive, for nothing** — and a card that
  # sends a reader to Amazon for a book that is free on archive.org has sold
  # them something worse than what it had.
  #
  # So free sources are listed first, and they are not marked `sponsored`
  # because they are not paid. The shops follow.
  #
  # ⚠ A vendor with no configured id renders nothing. The reader never sees a
  #   naked affiliate link and the site never carries a button earning nothing.
  #
  # ⚠ 01-BRIEF puts affiliate feeds out of scope below several hundred records.
  #   Added on the operator's call; at 34 records this earns roughly nothing and
  #   is carried because nothing here needs curating.
  module BuyLinks
    # ⚠ SCOPED BY MEDIUM. AbeBooks for a video game and Amazon for a
    #   public-domain PDF are both noise, and noise on a card that is asking to
    #   be trusted costs more than the click is worth.
    # ⚠ `document` is a Chronovisor recovery — a primary source, usually public
    #   domain. It is never for sale, and an Amazon search for one returns junk.
    #   It appears in the free lists and in none of the shops.
    BOOKS = %w[book].freeze
    GAMES = %w[game].freeze
    WATCH = %w[film series video].freeze
    LIBRARY = %w[book document].freeze
    SHOPS = %w[film series book game video].freeze
    ALL = %w[film series book game video document].freeze

    # ── free, and better for the reader ──────────────────────────────────────
    #
    # No setting to configure, no commission, no `sponsored`. Rendered only when
    # the record actually names the thing — an archive.org link is only offered
    # when the record carries an `archive_org` identifier, never as a search.
    #
    # ⚠ `holds: true` means **this link IS the work**, not a place to look it
    #   up. One of those on a card suppresses every shop below it: a reader who
    #   can watch the thing right now for nothing should not be sold a disc.
    FREE = {
      "archive" => {
        label: "Internet Archive",
        media: ALL,
        holds: true,
        url: ->(w) do
          id = w.dig("external", "archive_org").presence
          id && "https://archive.org/details/#{CGI.escape(id)}"
        end,
      },
      # ⚠ ONLY for `medium: video`, where the YouTube upload *is* the work — a
      #   Why Files episode, a recovered broadcast. A `film` carrying a youtube
      #   id most likely carries a trailer, and suppressing commerce over a
      #   two-minute trailer would be the wrong call in the other direction.
      "youtube" => {
        label: "Watch on YouTube",
        media: %w[video].freeze,
        holds: true,
        url: ->(w) do
          id = w.dig("external", "youtube").presence
          id && "https://www.youtube.com/watch?v=#{CGI.escape(id)}"
        end,
      },
      # ⚠ The most institute-shaped link on the card: it sends a reader to a
      #   library rather than a shop, and it costs nothing to offer.
      "worldcat" => {
        label: "Find in a library",
        media: LIBRARY,
        url: ->(w) do
          isbn = w.dig("external", "isbn").presence
          if isbn
            "https://search.worldcat.org/isbn/#{CGI.escape(isbn)}"
          else
            "https://search.worldcat.org/search?q=#{CGI.escape(BuyLinks.search_term(w))}"
          end
        end,
      },
      # The moving-image equivalent of WorldCat. Nobody buying Primer on DVD in
      # 2026 wants the DVD; they want to know which service has it tonight, and
      # that answer changes monthly, so it has to be a lookup rather than a
      # stored field.
      "justwatch" => {
        label: "Where to stream",
        media: WATCH,
        url: ->(w) do
          "https://www.justwatch.com/us/search?q=#{CGI.escape(BuyLinks.title_term(w))}"
        end,
      },
      # ⚠ FREE BECAUSE THERE IS NOTHING TO EARN. Steam has no public affiliate
      #   programme — verified July 2026, and long-standing. That makes it the
      #   JustWatch of games rather than a shop: for anything still commercially
      #   sold it is the canonical answer, and it answers *definitively* for
      #   older titles too, since "not on Steam" is itself the information.
      #   Amazon and eBay stay below it for physical console copies.
      "steam" => {
        label: "On Steam",
        media: GAMES,
        url: ->(w) do
          "https://store.steampowered.com/search/?term=#{CGI.escape(BuyLinks.title_term(w))}"
        end,
      },
    }.freeze

    # ── paid ─────────────────────────────────────────────────────────────────
    #
    # ⚠ SEARCH URLS, NOT LISTING IDS, AND THAT IS THE WHOLE DESIGN.
    #
    #   The operator's constraint: *"I am okay curating Amazon items myself but
    #   ebay ones expire and I dont want to spend time keeping track of that."*
    #   A listing id is a dead link in six weeks and a chore forever; a search
    #   for the title never expires.
    #
    #   So Amazon takes an optional `asin` when somebody has found one and falls
    #   back to a title search when nobody has. eBay is search only — there is
    #   no field for an eBay item and there should not be.
    VENDORS = {
      "amazon" => {
        label: "Amazon",
        media: SHOPS,
        setting: :curiobase_amazon_tag,
        url: ->(w, tag) do
          asin = w.dig("external", "asin").presence
          if asin
            "https://www.amazon.com/dp/#{CGI.escape(asin)}?tag=#{CGI.escape(tag)}"
          else
            "https://www.amazon.com/s?k=#{CGI.escape(BuyLinks.search_term(w))}&tag=#{CGI.escape(tag)}"
          end
        end,
      },
      # ⚠ Out of print is the NORMAL state of this catalogue — 1970s paperbacks,
      #   self-published claim literature, long-dead imprints. AbeBooks is where
      #   those actually are, and it runs on the same Amazon Associates tag, so
      #   it costs nothing extra to offer.
      "abebooks" => {
        label: "AbeBooks",
        media: BOOKS,
        setting: :curiobase_amazon_tag,
        url: ->(w, tag) do
          isbn = w.dig("external", "isbn").presence
          base =
            if isbn
              "https://www.abebooks.com/servlet/SearchResults?isbn=#{CGI.escape(isbn)}"
            else
              "https://www.abebooks.com/servlet/SearchResults?kn=#{CGI.escape(BuyLinks.search_term(w))}"
            end
          "#{base}&tag=#{CGI.escape(tag)}"
        end,
      },
      # ══════════════════════════════════════════════════════════════════════
      # GOG IS THE ABEBOOKS OF GAMES.
      # ══════════════════════════════════════════════════════════════════════
      #
      # Out of print is the normal state of this catalogue in every medium, and
      # for pre-2000 PC games GOG is frequently the **only** place the thing
      # legally exists at all — Steam does not carry it, the publisher is gone,
      # and the alternative is an abandonware site. That is worth a slot in a
      # way a generic key reseller is not.
      #
      # ⚠ THE SETTING HOLDS A WHOLE TRACKING PREFIX, NOT AN ID, AND THAT IS
      #   DELIBERATE. GOG runs affiliates through Adtraction, whose links wrap
      #   the destination in a redirect carrying both a programme id and an
      #   affiliate id. I cannot verify the exact parameter names or GOG's
      #   programme id from here, and a guessed tracking URL is the worst
      #   possible failure: it looks like it works and credits nobody. So the
      #   operator pastes the prefix their own dashboard gives them and the
      #   destination is appended, URL-encoded. It also survives GOG changing
      #   networks without a code change.
      "gog" => {
        label: "GOG",
        media: GAMES,
        setting: :curiobase_gog_tracking_prefix,
        url: ->(w, prefix) do
          dest = "https://www.gog.com/en/games?query=#{CGI.escape(BuyLinks.title_term(w))}"
          "#{prefix}#{CGI.escape(dest)}"
        end,
      },
      "ebay" => {
        label: "eBay",
        media: SHOPS,
        setting: :curiobase_ebay_campaign,
        url: ->(w, campaign) do
          "https://www.ebay.com/sch/i.html?_nkw=#{CGI.escape(BuyLinks.search_term(w))}" \
            "&mkcid=1&campid=#{CGI.escape(campaign)}"
        end,
      },
    }.freeze

    # ══════════════════════════════════════════════════════════════════════════
    # TWO KINDS OF SEARCH, AND THE DIFFERENCE IS THE SIZE OF THE HAYSTACK.
    # ══════════════════════════════════════════════════════════════════════════
    #
    # A **marketplace** — Amazon, eBay, AbeBooks, WorldCat — is searching tens of
    # millions of listings, so extra words narrow it usefully. "Primer" is a
    # paint product; "Primer Shane Carruth" is the film.
    #
    # A **catalogue** — Steam, JustWatch — holds tens of thousands of entries and
    # matches close to literally. `Steins;Gate (2009) 5pb. and Nitroplus` returns
    # **nothing** on Steam, where `Steins;Gate` returns the game. On a catalogue,
    # every extra word is a way to find zero results.

    # ⚠ Titles here carry a disambiguating year — `Primer (2004)`, `Dark
    #   (2017–2020)` — because the topic title is the record title (D-032) and a
    #   forum needs it. No search engine wants it, and `year` is its own field.
    def self.bare_title(w)
      w["title"].to_s.sub(/\s*\([^()]*\)\s*\z/, "").strip
    end

    def self.search_term(w)
      [bare_title(w), w["creator"]].compact_blank.join(" ")
    end

    def self.title_term(w) = bare_title(w)

    # [[label, url, paid?], …]. Free sources first, then the shops.
    def self.for(work)
      return [] if work.blank?
      return [] unless SiteSetting.curiobase_buy_links_enabled

      medium = work["medium"].to_s
      free = FREE.filter_map do |_n, v|
        next unless v[:media].include?(medium)
        url = v[:url].call(work)
        [v[:label], url, false, v[:holds]] if url.present?
      end

      # ══════════════════════════════════════════════════════════════════════
      # A FREE COPY OF THE WORK ITSELF ENDS THE LINE. ALL OF IT.
      # ══════════════════════════════════════════════════════════════════════
      #
      # A Why Files episode is on YouTube for nothing and a recovered briefing
      # document is public domain. Everything else on the line is *where might
      # this be* — a shop, a streaming service the reader may not subscribe to,
      # a library 200 miles away — and every one of those is noise next to
      # **here it is, free, now**. Printing them anyway says the card would
      # rather earn than answer.
      held = free.select { |_l, _u, _p, holds| holds }
      return held.map { |l, u, p, _h| [l, u, p] } if held.any?

      free = free.map { |l, u, p, _h| [l, u, p] }

      paid = VENDORS.filter_map do |_n, v|
        next unless v[:media].include?(medium)
        id = SiteSetting.public_send(v[:setting]).to_s
        next if id.blank?
        [v[:label], v[:url].call(work, id), true]
      end

      free + paid
    end
  end
end
