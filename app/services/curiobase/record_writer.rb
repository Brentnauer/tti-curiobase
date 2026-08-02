# frozen_string_literal: true

module Curiobase
  # Turns a record back into the block that produced it.
  #
  # ⚠ THE EXACT INVERSE OF PostRecord.parse, and it has to stay that way. If
  #   writing and reading ever disagree, converting a record silently changes
  #   it — which on a catalogue is worse than failing, because the new value
  #   looks as authoritative as the old one.
  #
  # ⚠ FIELD ORDER IS FOR A HUMAN, not for the parser. Identity first, then what
  #   the thing is, then the sentence, then the details — so that the block
  #   reads top to bottom like a form and a missing field is visible by its
  #   absence rather than by its position.
  module RecordWriter
    # ⚠ FACTS COME FROM PostRecord, NOT FROM A SECOND HAND-KEPT LIST.
    #
    #   This used to spell them out — `began ended where witnesses outcome
    #   object_kind founded claimant` — a copy of a list that was itself already
    #   incomplete. Two partial copies of one vocabulary is how John Titor's
    #   `nationality` and Majestic 12's `jurisdiction` were dropped on the floor
    #   during conversion without anything erroring.
    ORDER = [
      %w[type slug],
      %w[kind domain status medium mode],
      %w[year creator runtime],
      %w[period evidence],
      %w[also_known_as coords landing_url image_credit],
      PostRecord::FACTS,
      PostRecord::EXTERNAL,
      PostRecord::EDGES,
      %w[refs],
      %w[dek],
    ].flatten.freeze

    # ══════════════════════════════════════════════════════════════════════════
    # WHAT THE BLOCK DELIBERATELY DOES NOT CARRY.
    # ══════════════════════════════════════════════════════════════════════════
    #
    # Each of these has a better home in Discourse, so its absence from the
    # fence is correct rather than lossy. Anything NOT on this list and not in
    # ORDER is data going missing — see `losses`.
    ELSEWHERE = {
      "id" => "Discourse owns the identifier",
      "updated_at" => "Discourse owns revision times",
      "type" => "written first in the block",
      "title" => "the topic title IS the record title — Source reads it from there",
      "gravity" => "a member vote now, in PluginStore",
      "poster" => "the image dragged into the composer",
      "body" => "the post body, below the fence",
    }.freeze

    # ⚠ CONTAINERS. Expressed through their member keys, not as themselves.
    #
    #   `external` becomes `imdb:`/`isbn:` lines and `facts` becomes `founded:`
    #   /`jurisdiction:` lines, so the container key is never written and its
    #   absence from ORDER is correct. A sweep that does not know this reports
    #   both as lost on every record — which is what the first version of
    #   `losses` did, and it is the same blind spot in miniature: a check that
    #   only understands one of the two ways a field can be present.
    CONTAINERS = {
      "external" => PostRecord::EXTERNAL,
      "facts" => PostRecord::FACTS,
    }.freeze

    # ⚠ TOO LONG FOR A KEY-VALUE LINE, so they live in the post body as ordinary
    #   markdown. Not a loss and not a workaround — `prose` is an ordered
    #   argument (assertion, then support, then contradiction) and it reads far
    #   better as headed paragraphs than as a definition list, which is how it
    #   rendered before. `full_text` is a recovered document and goes last,
    #   collapsed, so it cannot push the dek out of the search snippet.
    # `links` are catalogue outbound URLs (Wikipedia, archives). Too free-form
    # for fence keys; they become a headed markdown list in the body, same as
    # prose. Fixtures still carry the array so SubjectCard can render `.cb-links`
    # on the wrap/fixture path.
    BODY = %w[prose full_text links].freeze

    # ⚠ WHAT CONVERSION WOULD THROW AWAY. Call this BEFORE writing.
    #
    #   `curiobase:convert` wrote 34 records, reported success on every one, and
    #   silently discarded a field on six of them. That is precisely the ACF
    #   failure the whole post-authoring move was meant to escape — a write that
    #   returns 200 and drops what it did not understand — reproduced in our own
    #   code inside a week.
    #
    #   A converter that cannot express a field must say so and stop. The record
    #   in the CMS is the only copy.
    def self.losses(record)
      known = ORDER + ELSEWHERE.keys + BODY + CONTAINERS.keys
      top =
        record.each_with_object([]) do |(key, value), out|
          next if known.include?(key)
          next if blank_value?(value)
          out << key
        end

      top + container_losses(record) + ref_losses(record)
    end

    # Unknown verb inside the refs array — same blind spot as container_losses.
    def self.ref_losses(record)
      Array(record["refs"]).filter_map do |entry|
        next unless entry.is_a?(Hash)

        verb = entry["verb"].presence || PostRecord::RELATED
        next if PostRecord::EDGE_VERBS.include?(verb)

        "refs.verb:#{verb}"
      end
    end

    # A container is a hash, so an unknown key INSIDE it is invisible to the
    # sweep above — the container key itself is known. Same shape of blind spot
    # as the one this whole method exists to catch, one level down.
    def self.container_losses(record)
      CONTAINERS.flat_map do |container, allowed|
        held = record[container]
        next [] unless held.is_a?(Hash)
        (held.keys - allowed).reject { |k| blank_value?(held[k]) }.map { |k| "#{container}.#{k}" }
      end
    end

    def self.blank_value?(v) = v.nil? || v == "" || v == [] || v == {}

    # ⚠ ONE IMPLEMENTATION, used by BOTH `curiobase:convert` AND
    #   `curiobase:repair`. Two copies of "where does prose go" is how the fact
    #   vocabulary ended up in two places and both of them wrong.
    #
    #   Returns the markdown sections `existing` does not already carry, so it
    #   is safe to run twice. Matched on the HEADING, never on the text —
    #   matching on the text would re-append the whole section the moment an
    #   editor changed a word of it.
    def self.body_additions(record, existing)
      out = []

      Array(record["prose"]).each do |p|
        label = p["label"].to_s
        body = p["body"].to_s.strip
        next if body.blank?
        next if existing.match?(/^\#{2,3}\s*#{Regexp.escape(label)}\s*$/i)
        out << "### #{label}\n\n#{body}"
      end

      full = record["full_text"].to_s.strip
      if full.present? && !existing.include?(full[0, 40])
        label = I18n.t("curiobase.full_text", default: "The recovered text")
        out << "[details=\"#{label}\"]\n#{full}\n[/details]"
      end

      link_rows =
        Array(record["links"]).filter_map do |l|
          next unless l.is_a?(Hash)
          url = l["url"].to_s.strip
          next if url.blank?
          label = l["label"].presence || url
          "- [#{label}](#{url})"
        end
      if link_rows.any?
        heading = I18n.t("curiobase.further_reading", default: "Further reading")
        unless existing.match?(/^\#{2,3}\s*#{Regexp.escape(heading)}\s*$/i)
          out << "### #{heading}\n\n#{link_rows.join("\n")}"
        end
      end

      out
    end

    def self.fence(record)
      lines = ORDER.filter_map { |key| line(key, value_for(record, key)) }
      "```curiobase\n#{lines.join("\n")}\n```"
    end

    def self.value_for(record, key)
      return record["type"] if key == "type"
      return record.dig("external", key) if PostRecord::EXTERNAL.include?(key)
      return record.dig("facts", key) if PostRecord::FACTS.include?(key)

      if PostRecord::EDGES.include?(key)
        return edge_slugs(record, key)
      end
      if key == "refs"
        return edge_slugs(record, PostRecord::RELATED)
      end

      record[key]
    end

    def self.edge_slugs(record, verb)
      Array(record["refs"])
        .select { |r| r.is_a?(Hash) && (r["verb"].presence || PostRecord::RELATED) == verb }
        .map { |r| r["slug"] }
        .compact
        .presence
    end

    def self.line(key, value)
      return nil if value.blank?
      value = value.join(", ") if value.is_a?(Array)
      # ⚠ A newline inside a value would end the field and turn the rest into an
      #   unknown key, which the validator would then refuse. Flatten rather
      #   than emit something that cannot be read back.
      "#{key}: #{value.to_s.gsub(/\s*\n\s*/, " ").strip}"
    end
  end
end
