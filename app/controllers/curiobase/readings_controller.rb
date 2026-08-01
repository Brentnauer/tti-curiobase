# frozen_string_literal: true

module Curiobase
  # Live gravity for rows already on a Subject association list.
  #
  # Baked cards stay the crawler / no-JS source of truth. This endpoint is the
  # human path: one batched PluginStore read for the Work ids the card already
  # rendered — no Associations re-rank on every paint.
  #
  #   GET /curiobase/readings?subject=john-titor&works=primer-2004,steins-gate
  #   → { "subject": "john-titor", "readings": { "primer-2004": { "display": 3.0, "voter_count": 1 } } }
  class ReadingsController < ::ApplicationController
    requires_plugin Curiobase::PLUGIN_NAME

    # Cap matches Associations::MAX_RANKED_WORKS — a Subject card never ships more.
    MAX_WORKS = Associations::MAX_RANKED_WORKS

    skip_before_action :check_xhr, only: %i[index]

    def index
      raise Discourse::NotFound unless SiteSetting.curiobase_enabled

      subject = params[:subject].to_s
      raise Discourse::InvalidParameters.new(:subject) if subject.blank?
      raise Discourse::NotFound unless Subjects.vocabulary.include?(subject)

      work_ids = parse_work_ids.first(MAX_WORKS)

      batch =
        if work_ids.any? && SiteSetting.curiobase_member_voting_enabled
          Gravity.for_works(work_ids, subject)
        else
          {}
        end

      readings =
        work_ids.each_with_object({}) do |wid, out|
          reading = batch[wid.to_s]
          out[wid] = {
            display: reading&.display,
            voter_count: reading&.voter_count.to_i,
          }
        end

      render json: { subject: subject, readings: readings }
    end

    private

    # Comma-separated is the reliable wire format: jQuery's repeated `works=a&works=b`
    # collapses to the last value under Rack, which made live refresh look dead.
    def parse_work_ids
      raw = params[:works]
      list =
        case raw
        when Array
          raw
        when String
          raw.split(",")
        when nil
          []
        else
          Array(raw)
        end

      list.map { |w| w.to_s.strip }.reject(&:blank?).uniq
    end
  end
end
