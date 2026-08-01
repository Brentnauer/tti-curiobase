# frozen_string_literal: true

module Curiobase
  # Stops a broken record in the composer.
  #
  # ══════════════════════════════════════════════════════════════════════════
  # THIS IS THE PRICE OF AUTHORING IN A POST, AND IT IS NOT OPTIONAL.
  # ══════════════════════════════════════════════════════════════════════════
  #
  # ACF gives you a dropdown; you cannot type `firsthand_account` with an
  # underscore into a select. A textarea will take anything, and this project's
  # signature failure is the silent one: a record that saves, returns success,
  # and renders nothing while looking finished.
  #
  # So the trade for losing the CMS form is that the validation has to move to
  # the moment of authoring. Not a rake task somebody remembers to run — the
  # composer, refusing to save, saying which line is wrong.
  #
  # ⚠ Everything here fails LOUD and EARLY. If a check can only be done at read
  #   time it does not belong in this file; it belongs in curiobase:doctor.
  class RecordValidator
    FACETS = {
      "kind" => %w[idea incident claim person place object org document],
      "domain" => %w[time reality consciousness contact phenomena hidden-history
                     esoterica science control futures],
      "status" => %w[open contested explained debunked hoax-admitted unfalsifiable],
      "medium" => %w[film series book game video document],
      "mode" => %w[fiction nonfiction],
      "type" => %w[subject work],
    }.freeze

    LIST_FACETS = {
      "period" => %w[ancient pre-1950 1950s 1960s 1970s 1980s 1990s 2000s 2010s 2020s],
      "evidence" => %w[primary-source firsthand-account secondhand-account
                       physical-trace documentary-record no-evidence],
    }.freeze

    DEK_MAX = 200

    # `post` is optional so the rake tasks and specs can validate a string on
    # its own. When it is given, the slug's exclusivity is checked too — that
    # is the one rule that cannot be judged from the raw alone.
    def self.errors_for(raw, post: nil)
      result = PostRecord.parse(raw)
      return [] unless result

      errors = []
      errors.concat(claim_errors(result, post)) if post

      result.unknown.each { |k| errors << I18n.t("curiobase.invalid.unknown_key", key: k) }
      result.missing.each { |k| errors << I18n.t("curiobase.invalid.missing", key: k) }

      fields = result.fields

      FACETS.each do |key, allowed|
        value = fields[key]
        next if value.blank?
        next if allowed.include?(value)
        errors << I18n.t("curiobase.invalid.value", key: key, value: value, allowed: allowed.join(", "))
      end

      LIST_FACETS.each do |key, allowed|
        Array(fields[key]).each do |value|
          next if allowed.include?(value)
          errors << I18n.t("curiobase.invalid.value", key: key, value: value, allowed: allowed.join(", "))
        end
      end

      # ⚠ The dek IS the meta description. WordPress rejected three records on
      #   seed for this, at 204 and 206 characters, and every one of them was
      #   findable before it was sent.
      if fields["dek"].present? && fields["dek"].length > DEK_MAX
        errors << I18n.t("curiobase.invalid.dek", count: fields["dek"].length, max: DEK_MAX)
      end

      if fields["slug"].present? && !fields["slug"].match?(/\A[a-z0-9][a-z0-9-]*\z/)
        errors << I18n.t("curiobase.invalid.slug", slug: fields["slug"])
      end

      if fields["year"].present? && !fields["year"].to_s.match?(/\A\d{3,4}\z/)
        errors << I18n.t("curiobase.invalid.year", year: fields["year"])
      end

      %w[season episode].each do |key|
        next if fields[key].blank?
        next if fields[key].to_s.match?(/\A\d{1,4}\z/)
        errors << I18n.t("curiobase.invalid.number", key: key, value: fields[key])
      end

      if fields["series"].present? && !fields["series"].match?(/\A[a-z0-9][a-z0-9-]*\z/)
        errors << I18n.t("curiobase.invalid.slug", slug: fields["series"])
      end

      # ⚠ A ref pointing at a subject that does not exist renders as a link to
      #   nothing. Cheap to catch here, invisible everywhere else.
      Array(fields["refs"]).each do |slug|
        next if Curiobase::Subjects.vocabulary.include?(slug)
        errors << I18n.t("curiobase.invalid.ref", slug: slug)
      end

      errors
    end

    # ══════════════════════════════════════════════════════════════════════════
    # ONE SLUG, ONE FILE. Refused in the composer, not discovered on a tag page.
    # ══════════════════════════════════════════════════════════════════════════
    #
    # A record designates itself by claiming a slug, so two records claiming the
    # same one is genuinely ambiguous — and the reader-facing symptom is a tag
    # page that silently serves the wrong file. There is no tiebreak that is
    # right; there is only refusing the second one while somebody is still
    # looking at it.
    #
    # ⚠ Scoped by TYPE, because a Work and a Subject may not share a slug
    #   either. They live in one namespace: `Source.subject("majestic-12")` and
    #   `Source.work("majestic-12")` would otherwise be a coin toss.
    def self.claim_errors(result, post)
      slug = result.fields["slug"]
      type = result.fields["type"].presence || "subject"
      return [] if slug.blank?

      taken =
        RecordTopic
          .claimants(slug)
          .reject { |id| id == post.topic_id }
          .select { |id| RecordTopic.really_claims?(id, slug, type) }

      return [] if taken.empty?

      other = Topic.select(:id, :title, :slug).find_by(id: taken.first)
      [I18n.t(
        "curiobase.invalid.slug_taken",
        slug: slug,
        type: type,
        title: other&.title.to_s,
        url: other&.relative_url.to_s,
        default:
          "The %{type} slug '%{slug}' is already the file for “%{title}” (%{url}). " \
          "A slug names exactly one record — rename this one, or merge the two topics.",
      )]
    end
  end
end
