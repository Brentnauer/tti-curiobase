# frozen_string_literal: true

module Curiobase
  # Outbound Subject→Subject edges, indexed as topic custom-field rows.
  #
  # ══════════════════════════════════════════════════════════════════════════
  # ONE ROW PER EDGE ON THE SOURCE TOPIC. NOT A FAN-IN PluginStore INDEX.
  # ══════════════════════════════════════════════════════════════════════════
  #
  #   topic_id = A, name = curiobase_edge, value = "explains:rendlesham-forest"
  #   topic_id = A, name = curiobase_edge, value = "precedes:john-titor"
  #
  # Inbound for B is `WHERE name = ? AND value IN (explains:B, contradicts:B, …)`.
  # Outbound for A is `WHERE topic_id = A AND name = ?`.
  #
  # ⚠ NO PluginStore FAN-IN MAP. That would be read-modify-write under a mutex
  #   on every edge change, and — like votes — "NO FOREIGN KEY, so removal is a
  #   sweep." Delete topic A and every target's inbound list would keep a ghost
  #   forever. Custom fields die with the topic; every other bake cache here
  #   (`curiobase_kind`, `curiobase_slug`, `curiobase_poster`) already works
  #   that way.
  #
  # ⚠ Multi-row, same name. The hash-style `topic.custom_fields[name] =` API
  #   collapses to one value. Writes go through TopicCustomField directly.
  module SubjectEdges
    FIELD = "curiobase_edge"

    # Verbs that surface as inbound attribution on the target's full card (v1).
    # Authorship stays one-way; the card names the source and the verb.
    INBOUND_VERBS = %w[explains contradicts].freeze

    Row =
      Struct.new(:from_slug, :from_title, :from_topic_id, :verb, keyword_init: true)

    def self.register!
      ::Topic.register_custom_field_type(FIELD, :string)
    end

    def self.encode(verb, slug) = "#{verb}:#{slug}"

    def self.decode(value)
      verb, sep, slug = value.to_s.partition(":")
      return nil if sep.blank? || verb.blank? || slug.blank?
      [verb, slug]
    end

    # Replace all outbound edge rows on the source topic.
    #
    # Returns target slugs that need a rebake (union of previous and new) when
    # the set changed; empty when nothing changed — so a hub rebake does not
    # stampede its neighbours.
    def self.replace!(topic, refs)
      return [] unless topic

      previous = TopicCustomField.where(topic_id: topic.id, name: FIELD).pluck(:value)
      new_values = encode_refs(refs)

      if previous.sort == new_values.sort
        return []
      end

      TopicCustomField.where(topic_id: topic.id, name: FIELD).delete_all
      new_values.each do |value|
        TopicCustomField.create!(topic_id: topic.id, name: FIELD, value: value)
      end

      fan_out_slugs(previous + new_values)
    end

    # Drop every edge row (Work conversion, or a Subject with no refs left).
    def self.clear!(topic)
      return [] unless topic

      previous = TopicCustomField.where(topic_id: topic.id, name: FIELD).pluck(:value)
      return [] if previous.empty?

      TopicCustomField.where(topic_id: topic.id, name: FIELD).delete_all
      fan_out_slugs(previous)
    end

    # Who points at this subject, for the verbs the card cares about.
    #
    # ⚠ BATCHED. One CF scan, one Topic load, one first-post pluck — not
    #   TopicRecord.for per source (that would N+1 on first_post).
    def self.inbound(slug, verbs: INBOUND_VERBS)
      slug = slug.to_s
      return [] if slug.blank?

      values = Array(verbs).map { |verb| encode(verb, slug) }
      cfs = TopicCustomField.where(name: FIELD, value: values).to_a
      return [] if cfs.empty?

      topic_ids = cfs.map(&:topic_id).uniq
      topics = Topic.where(id: topic_ids, deleted_at: nil).index_by(&:id)
      raws =
        Post
          .where(topic_id: topic_ids, post_number: 1)
          .pluck(:topic_id, :raw)
          .to_h

      cfs.filter_map do |cf|
        topic = topics[cf.topic_id]
        next unless topic

        verb, = decode(cf.value)
        next if verb.blank?

        ref = TopicRecord.from_raw(raws[cf.topic_id])
        next unless ref && ref[:kind].to_s == "subject"

        Row.new(
          from_slug: ref[:id].to_s,
          from_title: topic.title.to_s,
          from_topic_id: topic.id,
          verb: verb,
        )
      end
    rescue StandardError => e
      Rails.logger.warn("[curiobase] inbound edges for #{slug} failed: #{e.class}: #{e.message}")
      []
    end

    # Source topic is gone or back — targets must rebake so inbound cooked
    # drops (or restores) the attribution. Debounced per target.
    def self.schedule_fan_out!(topic)
      return unless topic

      previous = TopicCustomField.where(topic_id: topic.id, name: FIELD).pluck(:value)
      return if previous.empty?

      fan_out_slugs(previous).each do |slug|
        next if slug.blank?
        Curiobase.schedule_subject_file_rebake!(slug)
      end
    end

    def self.encode_refs(refs)
      Array(refs)
        .select { |e| e.is_a?(Hash) && e["slug"].present? }
        .filter_map do |e|
          verb = e["verb"].presence || PostRecord::RELATED
          # same_as is refused at validate / doctor — never index it.
          next if verb == "same_as"
          encode(verb, e["slug"].to_s)
        end
        .uniq
    end

    def self.fan_out_slugs(values)
      values.filter_map { |v| decode(v)&.last }.uniq
    end
    private_class_method :fan_out_slugs
  end
end
