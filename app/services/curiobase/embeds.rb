# frozen_string_literal: true

module Curiobase
  # Which media chrome a Work card should bake.
  #
  # ══════════════════════════════════════════════════════════════════════════
  # IFRAME ONLY WHEN THE HOST ALLOWS IT. Dead boxes are worse than a link.
  # ══════════════════════════════════════════════════════════════════════════
  #
  # Measured Aug 2026:
  #   YouTube embed                    → iframe OK
  #   Google Books ?output=embed       → iframe OK for previewable volumes
  #   Archive.org /embed/IDENTIFIER    → iframe OK (official embed URL)
  #     Older note about donation shells applied to some collection pages;
  #     item embeds are the BookReader / player Archive publishes for sharing.
  #
  # Every embed lands in `.cb-stage` below the identity head, above gravity.
  #
  # ⚠ Embed URL prefixes MUST be on allowed_iframes via register_modifier in
  #   plugin.rb. Without that, PrettyText strips the player.
  module Embeds
    Result =
      Struct.new(:provider, :mode, :role, :label, :src, :href, :thumb, keyword_init: true) do
        def hero?
          role == :hero
        end

        def secondary?
          role == :secondary
        end

        def iframe?
          mode == :iframe && src.present?
        end

        def link?
          mode == :link && href.present?
        end
      end

    YOUTUBE_ID = /\A[\w-]{6,}\z/
    ARCHIVE_ID = /\A[\w.-]+\z/
    GBOOKS_ID = /\A[\w-]{8,}\z/

    # Prefixes PrettyText keeps (need ≥3 slashes — see discourse-markdown-it).
    ALLOWED_IFRAME_PREFIXES = [
      "https://www.youtube.com/embed/",
      "https://www.youtube-nocookie.com/embed/",
      "https://books.google.com/books",
      "https://www.google.com/books",
      "https://archive.org/embed/",
    ].freeze

    def self.for_record(record, topic = nil)
      work = record
      return nil unless work.is_a?(Hash)

      medium = work["medium"].to_s
      ext = work["external"].is_a?(Hash) ? work["external"] : {}

      case medium
      when "video"
        youtube_iframe(ext["youtube"], :hero) || archive_iframe(ext["archive_org"], :hero)
      when "document"
        archive_iframe(ext["archive_org"], :hero)
      when "book"
        books_iframe(work, topic) || archive_iframe(ext["archive_org"], :hero)
      when "film", "series", "game"
        # Real player in the stage — not a link chip Discourse can onebox.
        youtube_iframe(ext["youtube"], :secondary)
      end
    end

    # Playable YouTube embed. Used for video works and for trailers.
    def self.youtube_iframe(id, role)
      id = id.to_s.strip
      return nil unless id.match?(YOUTUBE_ID)

      Result.new(
        provider: "youtube",
        mode: :iframe,
        role: role,
        label:
          (
            if role == :secondary
              I18n.t("curiobase.embed.trailer")
            else
              I18n.t("curiobase.embed.watch")
            end
          ),
        src: "https://www.youtube.com/embed/#{CGI.escape(id)}",
        href: "https://www.youtube.com/watch?v=#{CGI.escape(id)}",
        thumb: "https://i.ytimg.com/vi/#{CGI.escape(id)}/hqdefault.jpg",
      )
    end

    # Official Archive share embed — same stage slot as YouTube / Books.
    # Identifier is the /details/ slug (e.g. chemotaxonomiede05hegn).
    def self.archive_iframe(id, role)
      id = id.to_s.strip
      return nil unless id.match?(ARCHIVE_ID)

      Result.new(
        provider: "archive",
        mode: :iframe,
        role: role,
        label: I18n.t("curiobase.embed.archive"),
        src: "https://archive.org/embed/#{CGI.escape(id)}",
        href: "https://archive.org/details/#{CGI.escape(id)}",
        thumb: "https://archive.org/services/img/#{CGI.escape(id)}",
      )
    end

    # Baked iframe — same stage slot as YouTube. Requires `google_books:` or an
    # embeddable ISBN resolve; authors should prefer the volume id.
    def self.books_iframe(work, topic = nil)
      volume_id = GoogleBooks.volume_id_for(work, topic)
      return nil if volume_id.blank?

      Result.new(
        provider: "google_books",
        mode: :iframe,
        role: :hero,
        label: I18n.t("curiobase.embed.preview"),
        src:
          "https://books.google.com/books?id=#{CGI.escape(volume_id)}" \
            "&pg=PR1&printsec=frontcover&output=embed",
        href: "https://books.google.com/books?id=#{CGI.escape(volume_id)}",
        thumb: books_thumb(work, volume_id),
      )
    end

    # Prefer Open Library when we have an ISBN — Google's content URL often
    # ships an "image not available" stub even for valid volume ids.
    def self.books_thumb(work, volume_id)
      ext = work.is_a?(Hash) ? (work["external"] || {}) : {}
      isbn = ext["isbn"].to_s.gsub(/[^0-9Xx]/, "")
      if isbn.match?(/\A\d{9}[\dXx]\z|\A\d{13}\z/)
        return "https://covers.openlibrary.org/b/isbn/#{CGI.escape(isbn)}-M.jpg"
      end

      "https://books.google.com/books/content?id=#{CGI.escape(volume_id)}" \
        "&printsec=frontcover&img=1&zoom=0"
    end
  end
end
