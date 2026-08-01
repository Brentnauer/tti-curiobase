# frozen_string_literal: true

# Force-reload plugin services (dev without restart).
%w[
  embeds
  google_books
  series_episodes
  card_renderer
].each do |name|
  path = "/src/plugins/tti-curiobase/app/services/curiobase/#{name}.rb"
  load path
end

t = Topic.find(71)
rec = Curiobase::PostRecord.to_record(Curiobase::PostRecord.parse(t.first_post.raw), topic: t)
emb = Curiobase::Embeds.for_record(rec, t)
puts "deus_ex embed=#{emb.inspect}"

Discourse.redis.del("curiobase:rebake:#{t.id}")
Curiobase.rebake_now!(t.first_post)
cooked = t.first_post.reload.cooked
puts "has_media_link=#{cooked.include?("cb-media-link")}"
puts "has_trailer_iframe=#{cooked.include?("cb-embed--trailer")}"
puts "snippet=" + Nokogiri::HTML.fragment(cooked).at_css(".curiobase-card")&.to_html.to_s[0, 800]
