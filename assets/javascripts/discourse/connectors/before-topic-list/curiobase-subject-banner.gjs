import Component from "@glimmer/component";
import { service } from "@ember/service";
import { htmlSafe } from "@ember/template";

// The Subject banner on a tag page, for the Ember app.
//
// ⚠ NO FETCH. The markup arrives on the topic list payload
//   (add_to_serializer(:topic_list, :curiobase_banner) in plugin.rb), so it is
//   present at first render — on a cold load it comes out of PreloadStore, and
//   on a client-side navigation it is already in the list response.
//
//   The previous version fetched it in onPageChange, which produced a visible
//   flash: the server renders the banner into preload-content, Ember replaces
//   #main-outlet and discards it, then the fetch put it back. It looked like a
//   slow load and was actually a round trip re-fetching something the page had
//   already been given.
//
// ⚠ The `before-topic-list` outlet only receives `category` and `tag`, so the
//   list is read off the resolved route model instead. That is also why this is
//   a component and not an api-initializer.
//
// htmlSafe is safe here: SubjectCard builds through Nokogiri, so every value is
// escaped as a text node or an attribute. Nothing interpolates record data into
// a markup string.
export default class CuriobaseSubjectBanner extends Component {
  @service router;

  get banner() {
    const list = this.router.currentRoute?.attributes?.list;
    if (!list) {
      return null;
    }

    // ⚠ A plugin attribute does NOT land on the TopicList model.
    //
    //   TopicList promotes only a known set of keys onto itself — can_create_topic,
    //   per_page, more_topics_url and friends — and keeps the untouched server
    //   payload on `.topic_list`. So `list.curiobase_banner` is undefined even
    //   though the attribute is unmistakably in the JSON, and `.get()` returns
    //   undefined too. Measured in a running app, after an hour of the serializer
    //   looking broken when it was working perfectly.
    //
    //   The `?? list.curiobase_banner` is the belt to that braces: if a future
    //   Discourse does promote unknown keys, this keeps working.
    const b = list.topic_list?.curiobase_banner ?? list.curiobase_banner;
    return b?.html ? b : null;
  }

  <template>
    {{#if this.banner}}
      <div class="curiobase-tag-banner" data-slug={{this.banner.slug}}>
        {{htmlSafe this.banner.html}}
      </div>
    {{/if}}
  </template>
}
