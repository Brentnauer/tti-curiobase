# frozen_string_literal: true

module CuriobaseSpec
  # Pairing vocabulary is Subject *files*, not a tag group. Specs that need a
  # slug to create gravity rows must claim a live Subject file for it.
  def claim_subject_file!(slug, topic: nil)
    topic ||= Fabricate(:topic, title: "Subject file for #{slug}", tags: [Tag.find_or_create_by!(name: slug)])
    topic.custom_fields[Curiobase::TopicKind::FIELD] = "subject"
    topic.custom_fields[Curiobase::RecordTopic::FIELD] = slug.to_s
    topic.save_custom_fields
    Curiobase::Subjects.reset_cache!
    topic
  end
end

RSpec.configure { |config| config.include CuriobaseSpec }
