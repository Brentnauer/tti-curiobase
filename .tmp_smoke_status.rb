t = Topic.find_by_slug("primer-2004") || Topic.find_by(id: 31)
puts "topic=#{t&.id} slug=#{t&.slug} url=#{t&.relative_url}"
puts "fields=#{t&.custom_fields.inspect}" if t
puts "cooked_has_card=#{t&.first_post&.cooked&.include?('curiobase-card')}"
puts "kinds=#{TopicCustomField.where(name: 'curiobase_kind').group(:value).count.inspect}"
puts "all_cf_names=#{TopicCustomField.distinct.pluck(:name).grep(/curio/).inspect}"
Topic.where("slug LIKE ?", "%primer%").limit(5).each { |x| puts "slug=#{x.slug} id=#{x.id}" }
