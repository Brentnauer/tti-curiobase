# frozen_string_literal: true

module Curiobase
  # The published meaning of 1–5.
  #
  # Not decoration. BoardGameGeek runs the largest games database in the world
  # on a single axis and it works because every number has a stated behavioural
  # meaning. Strip the anchors and a 4 becomes "I liked it", which is a
  # different site.
  #
  # ⚠ THREE SETS, ONE SCALE. The fiction wording is incoherent applied to
  #   nonfiction — a government report does not "build on" an incident, it
  #   investigates one, and an archivist reading "4 · builds on it" beside the
  #   Halt memo would reasonably conclude the number means something it doesn't.
  #
  #   All three describe CENTRALITY, so a 5 is a 5 in any of them. Values stay
  #   comparable, mixed lists still rank correctly, and nothing stored changes.
  #   This is a labelling fix, not a scoring change.
  module Anchors
    SETS = {
      "fiction" => %w[mentions dressing serious builds essential],
      "nonfiction" => %w[mentions touches covers focuses entirely],
      "neutral" => %w[mentions passing engages central defining],
    }.freeze

    # A Work's own card: its own mode decides.
    def self.for_mode(mode)
      key = SETS.key?(mode.to_s) ? mode.to_s : "neutral"
      line(key)
    end

    # A Subject's association list: many Works, possibly many modes. If they all
    # agree, use their wording — a Subject whose associations are all films
    # should read like a film list. Otherwise fall back to neutral.
    def self.for_modes(modes)
      present = Array(modes).map(&:to_s).select { |m| SETS.key?(m) }.uniq
      present.one? ? line(present.first) : line("neutral")
    end

    def self.key_for_mode(mode)
      SETS.key?(mode.to_s) ? mode.to_s : "neutral"
    end

    def self.key_for_modes(modes)
      present = Array(modes).map(&:to_s).select { |m| SETS.key?(m) }.uniq
      present.one? ? present.first : "neutral"
    end

    # [[1, "mentions it"], ...] for baking step spans the client can highlight.
    def self.steps(key)
      k = SETS.key?(key.to_s) ? key.to_s : "neutral"
      SETS
        .fetch(k)
        .each_with_index
        .map { |token, i| [i + 1, I18n.t("curiobase.anchors.#{k}.#{token}")] }
    end

    def self.line(key)
      steps(key).map { |n, label| "#{n} #{label}" }.join(" · ")
    end

    # Baked legend with step spans so the vote control can highlight on hover.
    # Built against the caller's document so Nokogiri will adopt the nodes.
    def self.para_node(document, key)
      p = Nokogiri::XML::Node.new("p", document)
      p["class"] = "cb-anchors"
      steps(key).each_with_index do |(n, label), i|
        p.add_child(Nokogiri::XML::Text.new(" · ", document)) if i.positive?
        span = Nokogiri::XML::Node.new("span", document)
        span["class"] = "cb-anchor-step"
        span["data-step"] = n.to_s
        span.content = "#{n} #{label}"
        p.add_child(span)
      end
      p
    end
  end
end
