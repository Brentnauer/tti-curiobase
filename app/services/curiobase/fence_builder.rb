# frozen_string_literal: true

module Curiobase
  # Builds a fenced ```curiobase block from structured params for the
  # composer helper. RecordWriter remains the only formatter; this only
  # normalises the browser payload into a record hash.
  module FenceBuilder
    Result = Struct.new(:fence, :errors, :record, keyword_init: true) do
      def ok? = errors.empty? && fence.present?
    end

    # Allowlists + caps the modal must not hardcode a second copy of.
    def self.schema
      {
        facets: RecordValidator::FACETS,
        list_facets: RecordValidator::LIST_FACETS,
        # same_as is refused — never offer it in the picker.
        edge_verbs: PostRecord::EDGE_VERBS - %w[same_as],
        edge_cap: PostRecord::EDGE_CAP,
        dek_max: RecordValidator::DEK_MAX,
        required: PostRecord::REQUIRED,
        facts_by_kind: PostRecord::FACTS_BY_KIND,
        external: PostRecord::EXTERNAL,
      }
    end

    def self.build(params, post: nil)
      record = normalize(params)
      lost = RecordWriter.losses(record)
      if lost.any?
        return Result.new(
          fence: nil,
          errors: [I18n.t("curiobase.errors.fence_loss", keys: lost.join(", "))],
          record: record,
        )
      end

      fence = RecordWriter.fence(record)
      if fence.blank? || fence == "```curiobase\n\n```"
        return Result.new(
          fence: nil,
          errors: [I18n.t("curiobase.errors.fence_blank")],
          record: record,
        )
      end

      errors = RecordValidator.errors_for(fence, post: post)
      Result.new(fence: errors.empty? ? fence : nil, errors: errors, record: record)
    end

    def self.normalize(params)
      raw = params.respond_to?(:to_unsafe_h) ? params.to_unsafe_h : params.to_h
      raw = raw.deep_stringify_keys

      record = {}
      %w[
        type slug kind domain status medium mode year creator runtime dek
        also_known_as coords landing_url image_credit series season episode
      ].each do |key|
        value = raw[key]
        next if value.blank?
        record[key] = value.is_a?(String) ? value.strip : value
      end

      RecordValidator::LIST_FACETS.each_key do |key|
        list = Array(raw[key]).map { |v| v.to_s.strip }.reject(&:blank?)
        record[key] = list if list.any?
      end

      external = {}
      PostRecord::EXTERNAL.each do |key|
        value = raw.dig("external", key).presence || raw[key].presence
        external[key] = value.to_s.strip if value.present?
      end
      record["external"] = external if external.any?

      facts = {}
      held = raw["facts"].is_a?(Hash) ? raw["facts"] : {}
      PostRecord::FACTS.each do |key|
        value = held[key].presence || raw[key].presence
        facts[key] = value.to_s.strip if value.present?
      end
      record["facts"] = facts if facts.any?

      refs = normalize_refs(raw)
      record["refs"] = refs if refs.any?

      record
    end
    private_class_method :normalize

    def self.normalize_refs(raw)
      out = []
      Array(raw["refs"]).each do |entry|
        next unless entry.is_a?(Hash)
        slug = entry["slug"].to_s.strip
        next if slug.blank?
        verb = entry["verb"].presence || PostRecord::RELATED
        out << { "verb" => verb.to_s, "slug" => slug }
      end

      PostRecord::EDGES.each do |verb|
        Array(raw[verb]).each do |slug|
          slug = slug.to_s.strip
          next if slug.blank?
          out << { "verb" => verb, "slug" => slug }
        end
      end

      out
    end
    private_class_method :normalize_refs
  end
end
