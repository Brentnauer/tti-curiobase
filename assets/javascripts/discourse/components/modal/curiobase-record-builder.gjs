import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { service } from "@ember/service";
import withEventValue from "discourse/helpers/with-event-value";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import DButton from "discourse/ui-kit/d-button";
import DModal from "discourse/ui-kit/d-modal";
import { i18n } from "discourse-i18n";
import {
  parseFence,
  replaceOrInsertFence,
  subjectStub,
  workStub,
} from "../../lib/curiobase-fence";

function blankEdge() {
  return { verb: "related", slug: "" };
}

export default class CuriobaseRecordBuilder extends Component {
  @service site;

  @tracked schema = null;
  @tracked loading = true;
  @tracked saving = false;
  @tracked error = null;

  @tracked type = "subject";
  @tracked slug = "";
  @tracked kind = "";
  @tracked domain = "";
  @tracked status = "";
  @tracked medium = "";
  @tracked mode = "";
  @tracked year = "";
  @tracked creator = "";
  @tracked dek = "";
  @tracked period = "";
  @tracked evidence = "";
  @tracked edges = [blankEdge()];

  constructor() {
    super(...arguments);
    this.bootstrap();
  }

  get dekMax() {
    return this.schema?.dek_max || 200;
  }

  get dekCount() {
    return (this.dek || "").length;
  }

  get dekOver() {
    return this.dekCount > this.dekMax;
  }

  get isSubject() {
    return this.type === "subject";
  }

  get edgeCap() {
    return this.schema?.edge_cap || 12;
  }

  get edgeVerbs() {
    return (
      this.schema?.edge_verbs || [
        "explains",
        "contradicts",
        "precedes",
        "part_of",
        "involves",
        "related",
      ]
    );
  }

  get facetOptions() {
    return this.schema?.facets || {};
  }

  get subjectSlugs() {
    return this.site?.curiobase_subject_slugs || [];
  }

  get canAddEdge() {
    return this.edges.length < this.edgeCap;
  }

  get insertDisabled() {
    return this.loading || this.saving || this.dekOver;
  }

  async bootstrap() {
    this.loading = true;
    this.error = null;
    try {
      this.schema = await ajax("/curiobase/schema.json");
      this.prefillFromComposer();
    } catch (e) {
      this.error = i18n("curiobase.composer.schema_failed");
      popupAjaxError(e);
    } finally {
      this.loading = false;
    }
  }

  prefillFromComposer() {
    const raw = this.args.model?.composer?.model?.reply;
    const fields = parseFence(raw);
    if (!fields) {
      return;
    }

    this.type = fields.type === "work" ? "work" : "subject";
    this.slug = fields.slug || "";
    this.kind = fields.kind || "";
    this.domain = fields.domain || "";
    this.status = fields.status || "";
    this.medium = fields.medium || "";
    this.mode = fields.mode || "";
    this.year = fields.year ? String(fields.year) : "";
    this.creator = fields.creator || "";
    this.dek = fields.dek || "";
    this.period = Array.isArray(fields.period)
      ? fields.period.join(", ")
      : fields.period || "";
    this.evidence = Array.isArray(fields.evidence)
      ? fields.evidence.join(", ")
      : fields.evidence || "";
    this.edges =
      Array.isArray(fields.refs) && fields.refs.length
        ? fields.refs.map((r) => ({
            verb: r.verb || "related",
            slug: r.slug || "",
          }))
        : [blankEdge()];
  }

  payload() {
    const fields = {
      type: this.type,
      slug: this.slug.trim(),
      dek: this.dek.trim(),
    };

    if (this.isSubject) {
      fields.kind = this.kind;
      fields.domain = this.domain;
      if (this.status) {
        fields.status = this.status;
      }
      const period = this.splitList(this.period);
      if (period.length) {
        fields.period = period;
      }
      const evidence = this.splitList(this.evidence);
      if (evidence.length) {
        fields.evidence = evidence;
      }
      fields.refs = this.edges
        .map((e) => ({
          verb: e.verb || "related",
          slug: (e.slug || "").trim(),
        }))
        .filter((e) => e.slug);
    } else {
      fields.medium = this.medium;
      if (this.mode) {
        fields.mode = this.mode;
      }
      if (this.year) {
        fields.year = this.year.trim();
      }
      if (this.creator) {
        fields.creator = this.creator.trim();
      }
    }

    return fields;
  }

  splitList(value) {
    return (value || "")
      .split(",")
      .map((s) => s.trim())
      .filter(Boolean);
  }

  @action
  setType(value) {
    this.type = value;
  }

  @action
  setSlug(value) {
    this.slug = value;
  }

  @action
  setKind(value) {
    this.kind = value;
  }

  @action
  setDomain(value) {
    this.domain = value;
  }

  @action
  setStatus(value) {
    this.status = value;
  }

  @action
  setMedium(value) {
    this.medium = value;
  }

  @action
  setMode(value) {
    this.mode = value;
  }

  @action
  setYear(value) {
    this.year = value;
  }

  @action
  setCreator(value) {
    this.creator = value;
  }

  @action
  setDek(value) {
    this.dek = value;
  }

  @action
  setPeriod(value) {
    this.period = value;
  }

  @action
  setEvidence(value) {
    this.evidence = value;
  }

  @action
  setEdgeVerb(index, value) {
    const next = this.edges.slice();
    next[index] = { ...next[index], verb: value };
    this.edges = next;
  }

  @action
  setEdgeSlug(index, value) {
    const next = this.edges.slice();
    next[index] = { ...next[index], slug: value };
    this.edges = next;
  }

  @action
  addEdge() {
    if (!this.canAddEdge) {
      return;
    }
    this.edges = [...this.edges, blankEdge()];
  }

  @action
  removeEdge(index) {
    const next = this.edges.slice();
    next.splice(index, 1);
    this.edges = next.length ? next : [blankEdge()];
  }

  @action
  insertStub(kind) {
    const fence = kind === "work" ? workStub() : subjectStub();
    const toolbarEvent = this.args.model.toolbarEvent;
    const raw = this.args.model.composer?.model?.reply;
    replaceOrInsertFence(toolbarEvent, raw, fence);
    this.args.closeModal();
  }

  @action
  async insertRecord() {
    this.saving = true;
    this.error = null;
    try {
      const body = { fields: this.payload() };
      const topicId = this.args.model.topicId;
      if (topicId) {
        body.topic_id = topicId;
      }

      const result = await ajax("/curiobase/fence.json", {
        type: "POST",
        data: JSON.stringify(body),
        contentType: "application/json",
      });

      const toolbarEvent = this.args.model.toolbarEvent;
      const raw = this.args.model.composer?.model?.reply;
      replaceOrInsertFence(toolbarEvent, raw, result.fence);
      this.args.closeModal();
    } catch (e) {
      const msg =
        e?.jqXHR?.responseJSON?.errors?.join?.(" ") ||
        e?.jqXHR?.responseJSON?.error ||
        i18n("curiobase.composer.insert_failed");
      this.error = msg;
    } finally {
      this.saving = false;
    }
  }

  <template>
    <DModal
      @title={{i18n "curiobase.composer.title"}}
      @closeModal={{@closeModal}}
      class="curiobase-record-builder"
    >
      <:body>
        {{#if this.loading}}
          <p>{{i18n "curiobase.composer.loading"}}</p>
        {{else}}
          {{#if this.error}}
            <div class="alert alert-error">{{this.error}}</div>
          {{/if}}

          <div class="curiobase-builder__row">
            <label>
              {{i18n "curiobase.composer.type"}}
              <select
                value={{this.type}}
                {{on "change" (withEventValue this.setType)}}
              >
                <option value="subject">Subject</option>
                <option value="work">Work</option>
              </select>
            </label>
          </div>

          <div class="curiobase-builder__row">
            <label>
              {{i18n "curiobase.composer.slug"}}
              <input
                type="text"
                value={{this.slug}}
                {{on "input" (withEventValue this.setSlug)}}
                autocomplete="off"
              />
            </label>
          </div>

          {{#if this.isSubject}}
            <div class="curiobase-builder__row curiobase-builder__row--split">
              <label>
                {{i18n "curiobase.composer.kind"}}
                <select
                  value={{this.kind}}
                  {{on "change" (withEventValue this.setKind)}}
                >
                  <option value=""></option>
                  {{#each this.facetOptions.kind as |opt|}}
                    <option value={{opt}}>{{opt}}</option>
                  {{/each}}
                </select>
              </label>
              <label>
                {{i18n "curiobase.composer.domain"}}
                <select
                  value={{this.domain}}
                  {{on "change" (withEventValue this.setDomain)}}
                >
                  <option value=""></option>
                  {{#each this.facetOptions.domain as |opt|}}
                    <option value={{opt}}>{{opt}}</option>
                  {{/each}}
                </select>
              </label>
              <label>
                {{i18n "curiobase.composer.status"}}
                <select
                  value={{this.status}}
                  {{on "change" (withEventValue this.setStatus)}}
                >
                  <option value=""></option>
                  {{#each this.facetOptions.status as |opt|}}
                    <option value={{opt}}>{{opt}}</option>
                  {{/each}}
                </select>
              </label>
            </div>

            <div class="curiobase-builder__row">
              <label>
                {{i18n "curiobase.composer.period"}}
                <input
                  type="text"
                  value={{this.period}}
                  placeholder={{i18n "curiobase.composer.list_hint"}}
                  {{on "input" (withEventValue this.setPeriod)}}
                />
              </label>
            </div>
            <div class="curiobase-builder__row">
              <label>
                {{i18n "curiobase.composer.evidence"}}
                <input
                  type="text"
                  value={{this.evidence}}
                  placeholder={{i18n "curiobase.composer.list_hint"}}
                  {{on "input" (withEventValue this.setEvidence)}}
                />
              </label>
            </div>

            <div class="curiobase-builder__edges">
              <p class="curiobase-builder__eyebrow">
                {{i18n "curiobase.composer.edges"}}
                <span>({{this.edges.length}}/{{this.edgeCap}})</span>
              </p>
              <p class="curiobase-builder__hint">
                {{i18n "curiobase.composer.edges_hint"}}
              </p>

              {{#each this.edges as |edge index|}}
                <div class="curiobase-builder__edge">
                  <select
                    value={{edge.verb}}
                    {{on "change" (withEventValue (fn this.setEdgeVerb index))}}
                  >
                    {{#each this.edgeVerbs as |verb|}}
                      <option value={{verb}}>{{verb}}</option>
                    {{/each}}
                  </select>
                  <input
                    type="text"
                    value={{edge.slug}}
                    placeholder={{i18n "curiobase.composer.edge_slug"}}
                    list="curiobase-subject-slugs"
                    autocomplete="off"
                    {{on "input" (withEventValue (fn this.setEdgeSlug index))}}
                  />
                  <DButton
                    @icon="trash-can"
                    @action={{fn this.removeEdge index}}
                    @title={{i18n "curiobase.composer.remove_edge"}}
                    class="btn-flat"
                  />
                </div>
              {{/each}}

              <datalist id="curiobase-subject-slugs">
                {{#each this.subjectSlugs as |slug|}}
                  <option value={{slug}}></option>
                {{/each}}
              </datalist>

              {{#if this.canAddEdge}}
                <DButton
                  @label="curiobase.composer.add_edge"
                  @action={{this.addEdge}}
                  class="btn-default"
                />
              {{/if}}
            </div>
          {{else}}
            <div class="curiobase-builder__row curiobase-builder__row--split">
              <label>
                {{i18n "curiobase.composer.medium"}}
                <select
                  value={{this.medium}}
                  {{on "change" (withEventValue this.setMedium)}}
                >
                  <option value=""></option>
                  {{#each this.facetOptions.medium as |opt|}}
                    <option value={{opt}}>{{opt}}</option>
                  {{/each}}
                </select>
              </label>
              <label>
                {{i18n "curiobase.composer.mode"}}
                <select
                  value={{this.mode}}
                  {{on "change" (withEventValue this.setMode)}}
                >
                  <option value=""></option>
                  {{#each this.facetOptions.mode as |opt|}}
                    <option value={{opt}}>{{opt}}</option>
                  {{/each}}
                </select>
              </label>
            </div>
            <div class="curiobase-builder__row curiobase-builder__row--split">
              <label>
                {{i18n "curiobase.composer.year"}}
                <input
                  type="text"
                  value={{this.year}}
                  {{on "input" (withEventValue this.setYear)}}
                />
              </label>
              <label>
                {{i18n "curiobase.composer.creator"}}
                <input
                  type="text"
                  value={{this.creator}}
                  {{on "input" (withEventValue this.setCreator)}}
                />
              </label>
            </div>
          {{/if}}

          <div class="curiobase-builder__row">
            <label>
              {{i18n "curiobase.composer.dek"}}
              <textarea
                rows="3"
                value={{this.dek}}
                {{on "input" (withEventValue this.setDek)}}
              ></textarea>
              <span class="curiobase-builder__dek-count">
                {{this.dekCount}}/{{this.dekMax}}
                {{#if this.dekOver}}
                  —
                  {{i18n "curiobase.composer.dek_over"}}
                {{/if}}
              </span>
            </label>
          </div>

          <p class="curiobase-builder__hint">
            {{i18n "curiobase.composer.body_hint"}}
          </p>
        {{/if}}
      </:body>

      <:footer>
        <DButton
          @label="curiobase.composer.stub_subject"
          @action={{fn this.insertStub "subject"}}
          class="btn-flat"
          @disabled={{this.loading}}
        />
        <DButton
          @label="curiobase.composer.stub_work"
          @action={{fn this.insertStub "work"}}
          class="btn-flat"
          @disabled={{this.loading}}
        />
        <DButton @label="cancel" @action={{@closeModal}} class="btn-flat" />
        <DButton
          @label="curiobase.composer.insert"
          @action={{this.insertRecord}}
          @disabled={{this.insertDisabled}}
          class="btn-primary"
        />
      </:footer>
    </DModal>
  </template>
}
