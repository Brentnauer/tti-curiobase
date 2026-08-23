# frozen_string_literal: true

module Curiobase
  # Staff composer helper: schema allowlists + RecordWriter fence output.
  #
  #   GET  /curiobase/schema  — facets / verbs / caps (one door with Ruby)
  #   POST /curiobase/fence   — { fields… } → { fence } or validation errors
  #
  # The client never formats the fence itself. That keeps RecordWriter the
  # exact inverse of PostRecord.parse.
  class FenceController < ::ApplicationController
    requires_plugin Curiobase::PLUGIN_NAME

    before_action :ensure_logged_in
    before_action :ensure_enabled
    before_action :ensure_staff

    def schema
      render json: FenceBuilder.schema
    end

    def create
      post = find_optional_post
      result = FenceBuilder.build(request_fields, post: post)

      unless result.ok?
        return render_json_error(
          result.errors.presence || [I18n.t("curiobase.errors.fence_blank")],
          status: 422,
        )
      end

      render json: { fence: result.fence }
    end

    private

    def ensure_enabled
      raise Discourse::NotFound unless SiteSetting.curiobase_enabled
    end

    def ensure_staff
      raise Discourse::InvalidAccess unless current_user.staff?
    end

    # Prefer a nested `fields` hash; fall back to top-level keys for curl/tests.
    def request_fields
      raw =
        if params[:fields].present?
          params.require(:fields)
        else
          params
        end

      raw.permit(
        :type,
        :slug,
        :kind,
        :domain,
        :status,
        :medium,
        :mode,
        :year,
        :creator,
        :runtime,
        :dek,
        :also_known_as,
        :coords,
        :landing_url,
        :image_credit,
        :series,
        :season,
        :episode,
        *PostRecord::EXTERNAL,
        *PostRecord::FACTS,
        period: [],
        evidence: [],
        explains: [],
        contradicts: [],
        precedes: [],
        part_of: [],
        involves: [],
        refs: %i[verb slug],
        external: PostRecord::EXTERNAL.map(&:to_sym),
        facts: PostRecord::FACTS.map(&:to_sym),
      )
    end

    # When editing an existing first post, slug exclusivity must ignore self.
    def find_optional_post
      topic_id = params[:topic_id].presence&.to_i
      return nil if topic_id.blank?

      topic = Topic.find_by(id: topic_id)
      return nil unless topic
      guardian.ensure_can_see!(topic)
      topic.first_post
    end
  end
end
