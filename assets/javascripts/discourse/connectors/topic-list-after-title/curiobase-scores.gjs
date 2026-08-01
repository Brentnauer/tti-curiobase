import Component from "@glimmer/component";
import { service } from "@ember/service";

// Gravity and recommendations on the tag page's topic list.
//
// ⚠ NO FETCH, same as the banner. The numbers arrive on the topic list payload
//   (add_to_serializer(:topic_list, :curiobase_scores) in plugin.rb), keyed by
//   topic id, so they are there at first render.
//
// ⚠ WHY THE LIST AND NOT THE ITEM. Gravity is a property of the PAIRING, and
//   only the list knows which subject is being viewed — `topic_list_item` has
//   no idea it is being rendered on /tag/excalibur. A per-item serializer could
//   carry the medium and the recommendation count but never the score.
//
// ⚠ Absent everywhere else. The server only computes this on Subject tag pages,
//   so on /latest, on categories and on ordinary tags this renders nothing.
export default class CuriobaseScores extends Component {
  @service router;

  get score() {
    const id = this.args.outletArgs?.topic?.id;
    if (!id) {
      return null;
    }

    const list = this.router.currentRoute?.attributes?.list;
    // TopicList promotes only a known set of keys onto itself and keeps the
    // untouched payload on `.topic_list` — see the banner connector, where
    // that cost an hour of the serializer looking broken while it worked.
    const scores = list?.topic_list?.curiobase_scores ?? list?.curiobase_scores;
    const s = scores?.[String(id)];

    // A row with neither number is an ordinary discussion thread. Render
    // nothing rather than a pair of dashes.
    if (!s || (s.gravity == null && !s.recommend)) {
      return null;
    }

    return {
      ...s,
      gravity: s.gravity == null ? null : s.gravity.toFixed(1),
      strength: s.gravity == null ? null : String(Math.min(5, Math.max(1, Math.round(s.gravity)))),
    };
  }

  <template>
    {{#if this.score}}
      <span class="cb-list-scores">
        {{#if this.score.gravity}}
          <span
            class="cb-list-score cb-list-gravity"
            data-strength={{this.score.strength}}
            title="How strongly does this pull on the idea?"
          >
            <span class="cb-glyph" aria-hidden="true">●</span>{{this.score.gravity}}
          </span>
        {{/if}}
        {{#if this.score.recommend}}
          <span class="cb-list-score cb-list-recommend" title="Members recommend this">
            <span class="cb-glyph" aria-hidden="true">♥</span>{{this.score.recommend}}
          </span>
        {{/if}}
      </span>
    {{/if}}
  </template>
}
