# frozen_string_literal: true

module Curiobase
  # Where a record's external identifiers point.
  #
  # ══════════════════════════════════════════════════════════════════════════
  # ONE REGISTRY. THE CARD READS IT FOR LINKS, THE JSON-LD FOR `sameAs`.
  # ══════════════════════════════════════════════════════════════════════════
  #
  # ⚠ IT LIVED IN `CardRenderer` AND WAS ABOUT TO BE COPIED. Two lists of
  #   "identifier → URL" is the shape that has cost this codebase more than any
  #   other single thing: the copy drifts, and the drift is invisible because
  #   both halves keep rendering something.
  #
  # ⚠ REGISTRY, NOT A HARDCODED PAIR — the reason it exists at all. Only `imdb`
  #   and `tmdb` used to be handled, so every book, game, video and report
  #   rendered NO external links, silently, because a missing key looks exactly
  #   like a record that has none. Four of the six media were affected and two
  #   fixtures never showed it.
  #
  # ⚠ `asin` IS DELIBERATELY ABSENT, and this is the one entry whose absence is
  #   a decision rather than an omission. An Amazon product URL is a commercial
  #   listing, not an identity for the work — and on this site it carries an
  #   affiliate tag. Putting it in `sameAs` would tell Google that a shop page
  #   IS the film. It belongs in the Find-a-copy line and nowhere else.
  module Identifiers
    REGISTRY = {
      "imdb" => ["IMDb", "https://www.imdb.com/title/%s/"],
      "tmdb" => ["TMDB", "https://www.themoviedb.org/movie/%s"],
      "isbn" => ["ISBN", "https://openlibrary.org/isbn/%s"],
      "igdb" => ["IGDB", "https://www.igdb.com/games/%s"],
      "youtube" => ["YouTube", "https://www.youtube.com/watch?v=%s"],
      "archive_org" => ["Internet Archive", "https://archive.org/details/%s"],
      "wikipedia" => ["Wikipedia", "https://en.wikipedia.org/wiki/%s"],
      "google_books" => ["Google Books", "https://books.google.com/books?id=%s"],
    }.freeze

    # { "IMDb" => "https://…", … } — what the card renders as reference links.
    def self.links(external)
      each(external).to_h { |_key, label, url| [label, url] }
    end

    # ["https://…", …] — what `sameAs` carries.
    #
    # ⚠ `sameAs` is the property Google uses to reconcile an entity with one it
    #   already knows, and **Wikipedia is the strongest signal in the list.**
    #   The builder used to emit IMDb alone, so a book with an ISBN, a game with
    #   an IGDB id and a recovered broadcast on archive.org all told Google
    #   nothing about what they were.
    def self.urls(external)
      each(external).map { |_key, _label, url| url }
    end

    def self.url_for(external, key)
      id = external.is_a?(Hash) ? external[key.to_s].presence : nil
      entry = REGISTRY[key.to_s]
      id && entry && format(entry[1], id)
    end

    # [key, label, url] for every identifier present and known.
    def self.each(external)
      return [] unless external.is_a?(Hash)

      external.filter_map do |key, id|
        entry = REGISTRY[key.to_s]
        next unless entry && id.present?
        [key.to_s, entry[0], format(entry[1], id)]
      end
    end
  end
end
