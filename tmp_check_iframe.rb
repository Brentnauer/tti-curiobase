# frozen_string_literal: true
c = Topic.find(71).first_post.cooked
puts c.include?("youtube.com/embed/")
puts c.include?("cb-embed--trailer")
puts c.include?("aside.onebox")
m = c.match(/src="(https:\/\/www\.youtube\.com\/embed\/[^"]+)"/)
puts m ? m[1] : "no src"
