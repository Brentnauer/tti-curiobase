# frozen_string_literal: true

module Curiobase
  # Episodes that belong to a series hub Work.
  #
  # Episodes are ordinary Works (`medium: video` typically) with `series: hub-slug`.
  # At bake time CardRenderer writes `curiobase_series` on the episode topic so
  # the hub can list children with one indexed custom-field query — not a scan
  # of every first post.
  module SeriesEpisodes
    FIELD = "curiobase_series"
    MAX = 100

    Row =
      Struct.new(
        :title,
        :url,
        :season,
        :episode,
        :work_id,
        :medium,
        :likes,
        :topic_id,
        keyword_init: true,
      )

    def self.register!
      ::Topic.register_custom_field_type(FIELD, :string)
    end

    # Remember / clear the parent series slug on an episode topic.
    def self.remember!(topic, series_slug)
      return unless topic
      value = series_slug.to_s
      if value.blank?
        return if topic.custom_fields[FIELD].blank?
        topic.custom_fields.delete(FIELD)
      else
        return if topic.custom_fields[FIELD] == value
        topic.custom_fields[FIELD] = value
      end
      topic.save_custom_fields
    end

    def self.for(series_slug)
      slug = series_slug.to_s
      return [] if slug.blank?

      topic_ids =
        TopicCustomField
          .where(name: FIELD, value: slug)
          .limit(MAX)
          .pluck(:topic_id)
      return [] if topic_ids.empty?

      topics = Topic.where(id: topic_ids)
      batch = Source.for_topics(topics)
      likes = Recommendations.for_topics(topic_ids)

      rows =
        topics.filter_map do |topic|
          ref = TopicRecord.for(topic)
          next unless ref && ref[:kind] == "work"
          w = batch[topic.id] || Source.work(ref[:id])
          next unless w
          Row.new(
            title: topic.title,
            url: topic.relative_url,
            season: w["season"],
            episode: w["episode"],
            work_id: Gravity.work_id(w),
            medium: w["medium"],
            likes: likes[topic.id].to_i,
            topic_id: topic.id,
          )
        end

      rows.sort_by { |r| [r.season.to_i, r.episode.to_i, r.title.to_s] }
    rescue StandardError => e
      Rails.logger.warn("[curiobase] series episodes failed for #{series_slug}: #{e.class}")
      []
    end
  end
end
