# frozen_string_literal: true

require "rails_helper"

RSpec.describe Curiobase::BuyLinks do
  let(:work) do
    { "type" => "work", "slug" => "primer-2004", "title" => "Primer (2004)",
      "medium" => "film", "creator" => "Shane Carruth", "dek" => "Two engineers." }
  end
  let(:book) do
    { "type" => "work", "slug" => "the-mothman-prophecies", "title" => "The Mothman Prophecies",
      "medium" => "book", "creator" => "John Keel" }
  end
  let(:game) do
    { "type" => "work", "slug" => "steins-gate", "title" => "Steins;Gate (2009)",
      "medium" => "game", "creator" => "5pb. and Nitroplus" }
  end

  # [label, url, paid?] — helpers so the tuple shape lives in one place.
  def labels(w) = described_class.for(w).map { |l, _u, _p| l }
  def url_for(w, label) = described_class.for(w).find { |l, _u, _p| l == label }&.at(1)
  def paid?(w, label) = described_class.for(w).find { |l, _u, _p| l == label }&.at(2)

  before { SiteSetting.curiobase_buy_links_enabled = true }

  # ══════════════════════════════════════════════════════════════════════════
  # THE FREE SOURCES COME FIRST, AND THEY ARE NOT SPONSORED.
  # ══════════════════════════════════════════════════════════════════════════
  #
  # This catalogue is mostly out of print. Sending a reader to Amazon for a
  # 1975 paperback that is free on archive.org sells them something worse than
  # what the card already had.
  describe "free sources" do
    it "offers the Internet Archive when the record names one" do
      w = work.merge("external" => { "archive_org" => "primer_2004" })

      expect(url_for(w, "Internet Archive")).to eq("https://archive.org/details/primer_2004")
      expect(paid?(w, "Internet Archive")).to eq(false)
    end

    it "offers YouTube when the upload IS the work" do
      w = { "title" => "The John Titor Story", "medium" => "video",
            "external" => { "youtube" => "abc123" } }

      expect(url_for(w, "Watch on YouTube")).to eq("https://www.youtube.com/watch?v=abc123")
    end

    # ⚠ A film carrying a youtube id most likely carries a TRAILER. Treating
    #   that as a free copy — and suppressing the shops over it — would be the
    #   same error in the other direction.
    it "does not treat a film's youtube id as a copy of the film" do
      expect(labels(work.merge("external" => { "youtube" => "abc123" })))
        .not_to include("Watch on YouTube")
    end

    # ⚠ NEVER A SEARCH. archive.org search results for a title are mostly
    #   unrelated scans; a link that lands on the wrong thing is worse than no
    #   link, and unlike a shop there is no id to guess at.
    it "offers nothing when the record has no archive id" do
      expect(labels(work)).not_to include("Internet Archive")
    end

    it "sends a book reader to a library" do
      expect(url_for(book, "Find in a library")).to include("search.worldcat.org/search?q=")
    end

    it "uses the ISBN for the library link when there is one" do
      w = book.merge("external" => { "isbn" => "9780765334985" })

      expect(url_for(w, "Find in a library")).to eq("https://search.worldcat.org/isbn/9780765334985")
    end

    it "sends a film reader to streaming availability" do
      expect(url_for(work, "Where to stream")).to include("justwatch.com")
    end

    # ⚠ Steam is FREE because there is nothing to earn — it has no public
    #   affiliate programme (verified July 2026). That makes it the JustWatch of
    #   games rather than a shop, and it answers definitively either way: "not
    #   on Steam" is itself the information for an older title.
    it "sends a game reader to Steam, and charges nobody for it" do
      expect(url_for(game, "On Steam")).to include("store.steampowered.com")
      expect(paid?(game, "On Steam")).to eq(false)
    end

    it "offers Steam before either shop" do
      SiteSetting.curiobase_amazon_tag = "tti-20"
      SiteSetting.curiobase_ebay_campaign = "5338888888"

      expect(labels(game).first).to eq("On Steam")
    end

    it "renders free sources even with nothing configured" do
      expect(labels(work)).to eq(["Where to stream"])
    end

    it "puts every free source before every paid one" do
      SiteSetting.curiobase_amazon_tag = "tti-20"

      paid_flags = described_class.for(book).map { |_l, _u, p| p }
      expect(paid_flags).to eq(paid_flags.sort_by { |p| p ? 1 : 0 })
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # A FREE COPY OF THE WORK ITSELF ENDS THE LINE.
  # ══════════════════════════════════════════════════════════════════════════
  #
  # A Why Files episode is on YouTube for nothing; a recovered briefing document
  # is public domain. Printing "Amazon · eBay" underneath is worse than useless
  # — it sends a reader who could be reading the thing in one click off to buy
  # something that is not it, and it says the card would rather earn than answer.
  describe "when the reader already has it" do
    before do
      SiteSetting.curiobase_amazon_tag = "tti-20"
      SiteSetting.curiobase_ebay_campaign = "5338888888"
    end

    # ⚠ The library lookup goes too. Everything else on the line answers *where
    #   might this be*, and that is noise next to *here it is, free, now*.
    it "suppresses the shops AND the lookups when the work is on the Internet Archive" do
      w = book.merge("external" => { "archive_org" => "mothman", "isbn" => "9780765334985" })

      expect(labels(w)).to eq(["Internet Archive"])
    end

    it "suppresses every shop when the work is the YouTube upload" do
      w = { "title" => "The John Titor Story", "medium" => "video",
            "external" => { "youtube" => "abc123" } }

      expect(labels(w)).to eq(["Watch on YouTube"])
    end

    # ⚠ A LOOKUP IS NOT A COPY. JustWatch tells you Primer is on a service you
    #   may not subscribe to; WorldCat tells you a library 200 miles away holds
    #   it. Neither means the reader has the thing, so neither ends the line.
    it "does not treat a streaming lookup as having it" do
      expect(labels(work)).to include("Where to stream", "Amazon", "eBay")
    end

    it "does not treat a library lookup as having it" do
      expect(labels(book)).to include("Find in a library", "Amazon")
    end

    # ⚠ The whole feature can be switched off, free links included, so a site
    #   that wants no outbound commerce at all gets exactly that.
    it "goes silent with the rest when the feature is off" do
      SiteSetting.curiobase_buy_links_enabled = false
      w = work.merge("external" => { "archive_org" => "primer_2004" })

      expect(described_class.for(w)).to be_empty
    end
  end

  # ⚠ A buy button with no affiliate id is a link that earns nothing and still
  #   spends the reader's trust. No shop renders until somebody configures it.
  describe "nothing without configuration" do
    it "renders no shops when the feature is off" do
      SiteSetting.curiobase_buy_links_enabled = false
      SiteSetting.curiobase_amazon_tag = "tti-20"

      expect(described_class.for(work)).to be_empty
    end

    it "renders no shops when no id is set" do
      expect(labels(work)).not_to include("Amazon", "eBay")
    end

    it "renders only the shops that are configured" do
      SiteSetting.curiobase_amazon_tag = "tti-20"

      expect(labels(work)).to include("Amazon")
      expect(labels(work)).not_to include("eBay")
    end

    it "renders both once both are configured" do
      SiteSetting.curiobase_amazon_tag = "tti-20"
      SiteSetting.curiobase_ebay_campaign = "5338888888"

      expect(labels(work) & %w[Amazon eBay]).to eq(%w[Amazon eBay])
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # VENDORS ARE SCOPED BY MEDIUM.
  # ══════════════════════════════════════════════════════════════════════════
  #
  # AbeBooks for a video game and a library card for a film are both noise, and
  # noise on a card that is asking to be trusted costs more than a click earns.
  describe "medium scoping" do
    before do
      SiteSetting.curiobase_amazon_tag = "tti-20"
      SiteSetting.curiobase_ebay_campaign = "5338888888"
    end

    it "offers AbeBooks and a library for a book" do
      expect(labels(book)).to include("AbeBooks", "Find in a library")
    end

    it "offers neither for a film" do
      expect(labels(work)).not_to include("AbeBooks")
      expect(labels(work)).not_to include("Find in a library")
    end

    it "offers streaming for a film and not for a book" do
      expect(labels(work)).to include("Where to stream")
      expect(labels(book)).not_to include("Where to stream")
    end

    it "offers no out-of-print bookseller for a game" do
      expect(labels(game)).not_to include("AbeBooks")
      expect(labels(game)).to include("Amazon", "eBay")
    end

    it "offers no games store for a book or a film" do
      expect(labels(book)).not_to include("On Steam", "GOG")
      expect(labels(work)).not_to include("On Steam", "GOG")
    end

    # ⚠ `medium: document` is a Chronovisor recovery — a primary source, usually
    #   public domain. It is not for sale, and an Amazon search for "Majestic 12
    #   Eisenhower Briefing Document" returns junk with the institute's tag on it.
    it "offers no shop at all for a recovered document" do
      doc = { "title" => "Eisenhower Briefing Document", "medium" => "document" }

      expect(labels(doc)).to eq(["Find in a library"])
    end

    # ⚠ A record with no medium gets the general shops and no medium-specific
    #   guesswork, rather than everything or nothing.
    it "falls back to nothing rather than everything when the medium is absent" do
      expect(labels(work.except("medium"))).to be_empty
    end
  end

  describe "Amazon" do
    before { SiteSetting.curiobase_amazon_tag = "tti-20" }

    it "links straight to the item when an ASIN is known" do
      url = url_for(work.merge("external" => { "asin" => "B000123" }), "Amazon")

      expect(url).to eq("https://www.amazon.com/dp/B000123?tag=tti-20")
    end

    # ⚠ So the buttons work on all 34 records today, without anyone first going
    #   to find an ASIN for each one.
    it "falls back to a search when no ASIN is known" do
      url = url_for(work, "Amazon")

      expect(url).to start_with("https://www.amazon.com/s?k=")
      expect(url).to include("tag=tti-20")
    end

    it "carries the affiliate tag either way" do
      with = url_for(work.merge("external" => { "asin" => "B000123" }), "Amazon")
      without = url_for(work, "Amazon")

      expect([with, without]).to all(include("tti-20"))
    end

    # ⚠ AbeBooks runs on the same Associates account, so it costs nothing extra
    #   to offer and reaches the long tail Amazon itself does not stock.
    it "shares its tag with AbeBooks rather than needing a second setting" do
      expect(url_for(book, "AbeBooks")).to include("tag=tti-20")
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # eBay IS A SEARCH, NEVER A LISTING.
  # ══════════════════════════════════════════════════════════════════════════
  #
  # The operator's constraint, in his words: *"ebay ones expire and I dont want
  # to spend time keeping track of that."* A listing id is a dead link within
  # weeks and a chore forever; a search for the title never expires.
  describe "eBay" do
    before { SiteSetting.curiobase_ebay_campaign = "5338888888" }

    it "always builds a search URL" do
      url = url_for(work, "eBay")

      expect(url).to start_with("https://www.ebay.com/sch/i.html?_nkw=")
      expect(url).to include("campid=5338888888")
    end

    it "ignores an ASIN rather than trying to resolve a listing" do
      url = url_for(work.merge("external" => { "asin" => "B000123" }), "eBay")

      expect(url).not_to include("B000123")
      expect(url).to include("/sch/")
    end

    it "has no field for an eBay item id at all" do
      expect(Curiobase::PostRecord::EXTERNAL).not_to include("ebay")
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # GOG IS THE ABEBOOKS OF GAMES.
  # ══════════════════════════════════════════════════════════════════════════
  #
  # For pre-2000 PC games GOG is frequently the only place the thing legally
  # exists — Steam does not carry it and the publisher is gone.
  describe "GOG" do
    # ⚠ A WHOLE PREFIX, NOT AN ID. GOG runs affiliates through Adtraction, whose
    #   links wrap the destination in a redirect. A guessed tracking URL is the
    #   worst failure available here: it looks like it works and credits nobody,
    #   so the operator pastes what their own dashboard gives them.
    let(:prefix) { "https://track.adtraction.com/t/t?a=123&as=456&t=2&tk=1&url=" }

    before { SiteSetting.curiobase_gog_tracking_prefix = prefix }

    it "wraps the GOG search in the operator's tracking prefix" do
      url = url_for(game, "GOG")

      expect(url).to start_with(prefix)
      expect(CGI.unescape(url.delete_prefix(prefix))).to eq("https://www.gog.com/en/games?query=Steins%3BGate")
    end

    it "stays hidden until the prefix is set" do
      SiteSetting.curiobase_gog_tracking_prefix = ""

      expect(labels(game)).not_to include("GOG")
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # A MARKETPLACE WANTS MORE WORDS. A CATALOGUE WANTS FEWER.
  # ══════════════════════════════════════════════════════════════════════════
  #
  # Amazon is searching tens of millions of listings, so the creator narrows it
  # usefully. Steam holds tens of thousands of entries and matches close to
  # literally, where every extra word is a way to find zero results.
  describe "search terms" do
    before do
      SiteSetting.curiobase_amazon_tag = "tti-20"
      SiteSetting.curiobase_ebay_campaign = "5338888888"
    end

    # ⚠ "Primer" is a paint product. "Primer Shane Carruth" is the film.
    it "narrows a marketplace search with the creator" do
      expect(CGI.unescape(url_for(work, "Amazon"))).to include("Primer Shane Carruth")
    end

    it "gives a catalogue the title alone" do
      expect(CGI.unescape(url_for(game, "On Steam"))).to end_with("term=Steins;Gate")
      expect(CGI.unescape(url_for(work, "Where to stream"))).to end_with("q=Primer")
    end

    # ⚠ The disambiguating year is in the topic title because a forum needs it
    #   (D-032) and `year` is its own field anyway. No search engine wants it.
    it "strips the disambiguating year from every search" do
      %w[Amazon eBay].each do |v|
        expect(CGI.unescape(url_for(work, v))).not_to include("(2004)")
      end
      expect(CGI.unescape(url_for(work, "Where to stream"))).not_to include("(2004)")
    end

    it "keeps a parenthesis that is part of the title" do
      w = work.merge("title" => "Dark (2017–2020)", "creator" => nil)

      expect(described_class.bare_title(w)).to eq("Dark")
      expect(described_class.bare_title("title" => "F.E.A.R.")).to eq("F.E.A.R.")
    end

    it "escapes a title that would otherwise break the URL" do
      odd = work.merge("title" => "Steins;Gate & Co #1", "creator" => nil)

      url = url_for(odd, "Amazon")
      expect(url).not_to include(";Gate & Co #1")
      expect(CGI.unescape(url)).to include("Steins;Gate & Co #1")
    end
  end

  it "is silent on a blank record rather than raising" do
    SiteSetting.curiobase_amazon_tag = "tti-20"
    expect(described_class.for(nil)).to be_empty
  end

  # ── on the card ─────────────────────────────────────────────────────────────
  describe "on a rendered Work card" do
    fab!(:admin) { Fabricate(:admin) }

    def bake!(extra = "")
      topic = Fabricate(:topic, title: "Primer (2004), the garage film", user: admin)
      post = Fabricate(:post, topic: topic, user: admin, post_number: 1, raw: <<~RAW)
        ```curiobase
        type: work
        slug: primer-2004
        medium: film
        creator: Shane Carruth
        #{extra}
        dek: Two engineers building something in a garage.
        ```
      RAW
      Curiobase.rebake_now!(post)
      post.reload
    end

    before { SiteSetting.curiobase_enabled = true }

    it "still gives a reader somewhere to go when nothing is configured" do
      # A film with no archive id still gets JustWatch — that is the point of
      # leading with the free sources.
      cooked = bake!.cooked

      expect(cooked).to include("cb-buy-link--free")
      expect(cooked).not_to include("cb-buy-note")
    end

    it "renders the buttons and the disclosure together once configured" do
      SiteSetting.curiobase_amazon_tag = "tti-20"
      cooked = bake!.cooked

      expect(cooked).to include("cb-buy-link").and include("cb-buy-note")
    end

    # ══════════════════════════════════════════════════════════════════════════
    # `sponsored` GOES ON THE PAID LINKS AND ONLY THE PAID LINKS.
    # ══════════════════════════════════════════════════════════════════════════
    #
    # Google requires paid links to be marked — an affiliate link passing
    # PageRank is a manual action waiting to happen on a site whose whole
    # strategy is organic search. But marking a free archive.org link as
    # sponsored is a false declaration in the other direction.
    it "marks every paid link nofollow AND sponsored" do
      SiteSetting.curiobase_amazon_tag = "tti-20"
      SiteSetting.curiobase_ebay_campaign = "5338888888"
      frag = Nokogiri::HTML5.fragment(bake!.cooked)

      paid = frag.css("a.cb-buy-link:not(.cb-buy-link--free)")
      expect(paid.size).to eq(2)
      paid.each { |a| expect(a["rel"]).to include("nofollow").and include("sponsored") }
    end

    it "never marks a free source sponsored" do
      SiteSetting.curiobase_amazon_tag = "tti-20"
      frag = Nokogiri::HTML5.fragment(bake!.cooked)

      free = frag.css("a.cb-buy-link--free")
      expect(free).not_to be_empty
      free.each { |a| expect(a["rel"]).not_to include("sponsored") }
    end

    # ⚠ Claiming a commission the card cannot earn is its own kind of dishonest.
    it "omits the disclosure when nothing on the line is paid" do
      frag = Nokogiri::HTML5.fragment(bake!.cooked)

      expect(frag.css("a.cb-buy-link--free")).not_to be_empty
      expect(frag.css(".cb-buy-note")).to be_empty
    end

    # ⚠ Below the gravity block. The judgement is why a reader is here; a buy
    #   button above the score makes the card a storefront with an opinion.
    it "sits after the gravity block, never above it" do
      SiteSetting.curiobase_amazon_tag = "tti-20"
      frag = Nokogiri::HTML5.fragment(bake!.cooked)
      order = frag.css(".cb-gravity, .cb-buy").map { |n| n["class"].split.first }

      expect(order).to eq(%w[cb-gravity cb-buy])
    end

    it "never appears on a Subject" do
      SiteSetting.curiobase_amazon_tag = "tti-20"
      topic = Fabricate(:topic, title: "Rendlesham Forest, three nights", user: admin)
      post = Fabricate(:post, topic: topic, user: admin, post_number: 1, raw: <<~RAW)
        ```curiobase
        type: subject
        slug: rendlesham-forest
        kind: incident
        domain: contact
        dek: Three nights in December 1980.
        ```
      RAW
      Curiobase.rebake_now!(post)

      expect(post.reload.cooked).not_to include("cb-buy")
    end
  end
end
