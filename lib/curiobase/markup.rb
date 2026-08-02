# frozen_string_literal: true

module Curiobase
  # Building Nokogiri nodes against the document being cooked.
  #
  # ⚠ ONE COPY. `CardRenderer` and `SubjectCard` each carried a byte-identical
  #   private `node` and `para`, plus their own `Tag.find_by(name:)` memo. Three
  #   small duplications, and this codebase's entire failure history is one fact
  #   living in two places until the copies disagree.
  #
  # ⚠ Every node must be created against `@doc.document`, not with a bare
  #   `Nokogiri::XML::Node.new`. A node built against a different document
  #   cannot be adopted into this one, and the symptom is a silently missing
  #   element rather than an exception.
  module Markup
    def node(name, attrs = {})
      n = Nokogiri::XML::Node.new(name, @doc.document)
      attrs.each { |k, v| n[k.to_s] = v.to_s }
      n
    end

    def para(klass, text)
      p = node("p", class: klass)
      p.content = text.to_s
      p
    end

    # ⚠ Discourse's ExcerptParser treats `div.excerpt` / `span.excerpt` as the
    #   ONLY text that becomes `topics.excerpt` / the crawler meta description.
    #   Without this, a short dek is followed by badge mush (`ideatimeopen`) and
    #   fact labels (`Related…`) inside the ~155-character window Google shows.
    #
    #   The dek stays first in the card DOM; this wrapper just stops the excerpt
    #   at the sentence. Badges still lead visually via CSS `order: -1`.
    def dek_block(text)
      return nil if text.blank?
      wrap = node("div", class: "excerpt")
      wrap.add_child(para("cb-dek", text))
      wrap
    end

    def text(str) = Nokogiri::XML::Text.new(str.to_s, @doc.document)

    # ⚠ `p.cb-badges`, first span primary and the rest muted. Both renderers
    #   built this independently and had already drifted in whitespace.
    #
    # ⚠ Badges lead VISUALLY via `order: -1` in CSS, never in document order.
    #   Discourse builds the meta description from the start of the post and
    #   badge text loses its spaces when tags are stripped, so leading with them
    #   produced `documenthidden historydebunked …` as a live search snippet.
    #   That has regressed three times. The dek goes first in the DOM.
    def badges(*parts)
      p = node("p", class: "cb-badges")
      parts.flatten.compact_blank.each_with_index do |t, i|
        span = node("span", class: "cb-badge cb-badge--#{i.zero? ? "primary" : "muted"}")
        span.content = t.to_s.tr("-", " ")
        p.add_child(span)
      end
      p
    end

    # Memoised per render: a Work tagged with six subjects would otherwise ask
    # for the same tags twice each.
    def tag_for(slug)
      @curiobase_tags ||= {}
      @curiobase_tags.fetch(slug) { @curiobase_tags[slug] = Tag.find_by(name: slug) }
    end
  end
end
