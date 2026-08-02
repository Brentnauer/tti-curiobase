# frozen_string_literal: true

require "net/http"
require "json"

module Curiobase
  # Whether a book has an embeddable Google Books preview.
  #
  # ══════════════════════════════════════════════════════════════════════════
  # KNOW BEFORE YOU IFRAME. Most ISBNs have no preview; a blank reader is noise.
  # ══════════════════════════════════════════════════════════════════════════
  #
  # Resolution order:
  #   1. Explicit `google_books:` volume id on the record (author asserts it)
  #   2. Topic cache from a prior probe (`curiobase_gbooks`)
  #   3. Google Books API lookup by ISBN → cache volume id or "none"
  module GoogleBooks
    FIELD = "curiobase_gbooks"
    NONE = "none"
    API = "https://www.googleapis.com/books/v1/volumes"
    CACHE_TTL = 7.days

    def self.register!
      ::Topic.register_custom_field_type(FIELD, :string)
    end

    # Volume id suitable for an embed, or nil when there is no preview.
    def self.volume_id_for(work, topic = nil)
      ext = work.is_a?(Hash) ? (work["external"] || {}) : {}
      explicit = ext["google_books"].to_s.strip
      return explicit if explicit.present? && explicit.match?(Embeds::GBOOKS_ID)

      isbn = ext["isbn"].to_s.gsub(/[^0-9Xx]/, "")
      return nil if isbn.blank?

      cached = read_cache(topic, isbn)
      return nil if cached == NONE
      return cached if cached.present?

      probed = safe_probe_isbn(isbn)
      # nil = transient failure (timeout, 429, WebMock). Do NOT cache as none.
      return nil if probed.nil?

      write_cache(topic, isbn, probed)
      probed == NONE ? nil : probed
    end

    # Probe never raises — a failed/blocked HTTP call must not abort post cook.
    # Returns volume id, NONE (definitively not embeddable), or nil (try again later).
    def self.safe_probe_isbn(isbn)
      probe_isbn(isbn)
    rescue StandardError => e
      Rails.logger.warn("[curiobase] google books lookup failed: #{e.class}: #{e.message}")
      nil
    end

    def self.probe_isbn(isbn)
      uri = URI(API)
      uri.query = URI.encode_www_form(q: "isbn:#{isbn}", maxResults: 1)
      body = http_get(uri)
      return nil if body.blank?

      data = JSON.parse(body)
      item = Array(data["items"]).first
      return NONE unless item

      info = item["accessInfo"] || {}
      return NONE unless info["embeddable"]

      id = item["id"].to_s
      id.match?(Embeds::GBOOKS_ID) ? id : NONE
    end

    def self.http_get(uri)
      key = "curiobase:gbooks:http:#{uri.query}"
      cached = Discourse.cache.read(key)
      return cached if cached.present?

      body =
        Net::HTTP.start(
          uri.host,
          uri.port,
          use_ssl: uri.scheme == "https",
          open_timeout: 3,
          read_timeout: 5,
        ) do |http|
          req = Net::HTTP::Get.new(uri)
          req["User-Agent"] = "tti-curiobase"
          req["Accept"] = "application/json"
          res = http.request(req)
          res.is_a?(Net::HTTPSuccess) ? res.body.to_s : nil
        end

      # Only cache successes — a 429 must not freeze "no body" for a week.
      Discourse.cache.write(key, body, expires_in: CACHE_TTL) if body.present?
      body
    rescue StandardError => e
      # WebMock in specs, timeouts in prod — never let a Books probe abort a bake.
      Rails.logger.warn("[curiobase] google books http failed: #{e.class}: #{e.message}")
      nil
    end

    def self.read_cache(topic, isbn)
      # ISBN-keyed cache is authoritative — the topic field is only a hint and
      # used to poison pairings when an earlier ISBN got 429 → "none".
      cached = Discourse.cache.read(cache_key(isbn))
      return cached if cached.present?

      return nil unless topic

      stored = topic.custom_fields[FIELD].to_s
      return nil if stored.blank? || stored == NONE
      # Topic field is a bare volume id from a prior successful resolve for this
      # topic. Trust it only when it looks like one — never "none".
      stored.match?(Embeds::GBOOKS_ID) ? stored : nil
    end

    def self.write_cache(topic, isbn, value)
      value = value.presence || NONE
      Discourse.cache.write(cache_key(isbn), value, expires_in: CACHE_TTL)
      return unless topic
      # Never persist NONE on the topic — a quota blip would hide previews for a week.
      return if value == NONE

      return if topic.custom_fields[FIELD] == value
      topic.custom_fields[FIELD] = value
      topic.save_custom_fields
    end

    def self.cache_key(isbn) = "curiobase:gbooks:isbn:#{isbn}"

    # Ops / recovery: drop a bad "none" so the next bake can probe again.
    def self.clear_cache!(topic: nil, isbn: nil)
      Discourse.cache.delete(cache_key(isbn)) if isbn.present?
      return unless topic

      return if topic.custom_fields[FIELD].blank?
      topic.custom_fields.delete(FIELD)
      topic.save_custom_fields
    end
  end
end
