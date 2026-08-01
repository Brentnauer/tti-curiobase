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

      probed = probe_isbn(isbn)
      write_cache(topic, isbn, probed)
      probed == NONE ? nil : probed
    rescue StandardError => e
      Rails.logger.warn("[curiobase] google books lookup failed: #{e.class}: #{e.message}")
      nil
    end

    def self.probe_isbn(isbn)
      uri = URI(API)
      uri.query = URI.encode_www_form(q: "isbn:#{isbn}", maxResults: 1)
      body = http_get(uri)
      return NONE if body.blank?

      data = JSON.parse(body)
      item = Array(data["items"]).first
      return NONE unless item

      info = item["accessInfo"] || {}
      return NONE unless info["embeddable"]

      id = item["id"].to_s
      id.match?(Embeds::GBOOKS_ID) ? id : NONE
    end

    def self.http_get(uri)
      Discourse.cache.fetch("curiobase:gbooks:http:#{uri.query}", expires_in: CACHE_TTL) do
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
      end
    end

    def self.read_cache(topic, isbn)
      if topic
        stored = topic.custom_fields[FIELD].to_s
        return stored if stored.present?
      end
      Discourse.cache.read(cache_key(isbn))
    end

    def self.write_cache(topic, isbn, value)
      value = value.presence || NONE
      Discourse.cache.write(cache_key(isbn), value, expires_in: CACHE_TTL)
      return unless topic

      return if topic.custom_fields[FIELD] == value
      topic.custom_fields[FIELD] = value
      topic.save_custom_fields
    end

    def self.cache_key(isbn) = "curiobase:gbooks:isbn:#{isbn}"
  end
end
