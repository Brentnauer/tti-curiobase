# frozen_string_literal: true

%w[embeds card_renderer google_books post_record].each do |f|
  load "/src/plugins/tti-curiobase/app/services/curiobase/#{f}.rb"
end

[66, 68, 69, 70, 71].each do |id|
  t = Topic.find(id)
  p = t.first_post
  r = Curiobase::PostRecord.parse(p.raw)
  emb = r&.valid? ? Curiobase::Embeds.for_record(r.to_h, t) : nil
  Curiobase.rebake_now!(p)
  c = p.reload.cooked
  puts "=== #{id} #{t.slug} ==="
  puts "valid=#{r&.valid?} medium=#{r&.to_h&.dig('medium')} ext=#{r&.to_h&.dig('external').inspect}"
  puts "embed=#{emb&.provider}/#{emb&.mode} thumb=#{emb&.thumb.to_s[0, 60]}"
  puts "stage=#{c.include?('cb-stage')} media=#{c.include?('cb-media-link')} poster-link=#{c.include?('cb-poster--link')} empty=#{c.include?('cb-poster--empty')} ytimg=#{c.include?('ytimg')}"
  frag = Nokogiri::HTML.fragment(c)
  stage = frag.at_css(".cb-stage")
  puts "stage_html=#{stage&.to_html.to_s[0, 220]}"
  poster = frag.at_css(".cb-poster, .cb-poster--empty, a.cb-poster")
  puts "poster=#{poster && poster['class']}"
end
