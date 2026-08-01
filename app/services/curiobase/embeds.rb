# frozen_string_literal: true

module Curiobase
  # Which media chrome a Work card should bake.
  #
  # ══════════════════════════════════════════════════════════════════════════
  # IFRAME ONLY WHEN THE HOST ALLOWS IT. Dead boxes are worse than a link.
  # ══════════════════════════════════════════════════════════════════════════
  #
  # Measured Aug 2026:
  #   YouTube nocookie embed  → works in our theme
  #   Google Books output=embed → 404 + X-Frame-Options: SAMEORIGIN
  #   Archive.org /embed/nasa   → collection page / donation shell, blank body
  #
  # So: YouTube may iframe (video works AND film/game/series trailers). Books
  # and Archive bake as Discord-style link cards — those hosts refuse iframes.
  # Every embed lands in `.cb-stage` below the identity head, above gravity.
  #
  # ⚠ youtube-nocookie / youtube embed URLs MUST be on allowed_iframes via
  #   register_modifier in plugin.rb. Without that, PrettyText strips the
  #   player and leftover watch-links get Discourse oneboxes instead.
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
    ].freeze

    def self.for_record(record, topic = nil)
      work = record
      return nil unless work.is_a?(Hash)

      medium = work["medium"].to_s
      ext = work["external"].is_a?(Hash) ? work["external"] : {}

      case medium
      when "video"
        youtube_iframe(ext["youtube"], :hero) || archive_card(ext["archive_org"], :hero)
      when "document"
        archive_card(ext["archive_org"], :hero)
      when "book"
        books_card(work, topic) || archive_card(ext["archive_org"], :hero)
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
        # www.youtube.com/embed is on Discourse's onebox iframe allowlist;
        # nocookie is added via the pretty_text_allowed_iframes modifier.
        src: "https://www.youtube.com/embed/#{CGI.escape(id)}",
        href: "https://www.youtube.com/watch?v=#{CGI.escape(id)}",
        thumb: "https://i.ytimg.com/vi/#{CGI.escape(id)}/hqdefault.jpg",
      )
    end

    def self.archive_card(id, role)
      id = id.to_s.strip
      return nil unless id.match?(ARCHIVE_ID)

      Result.new(
        provider: "archive",
        mode: :link,
        role: role,
        label: I18n.t("curiobase.embed.archive"),
        href: "https://archive.org/details/#{CGI.escape(id)}",
        thumb: "https://archive.org/services/img/#{CGI.escape(id)}",
      )
    end

    def self.books_card(work, topic = nil)
      volume_id = GoogleBooks.volume_id_for(work, topic)
      return nil if volume_id.blank?

      Result.new(
        provider: "google_books",
        mode: :link,
        role: :hero,
        label: I18n.t("curiobase.embed.preview"),
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
