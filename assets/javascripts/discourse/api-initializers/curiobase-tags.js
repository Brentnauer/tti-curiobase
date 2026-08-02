import { apiInitializer } from "discourse/lib/api";
import { defaultRenderTag } from "discourse/lib/render-tag";

// Subject-file tags look distinct from ordinary Discourse tags.
// Vocabulary comes from the site serializer (`curiobase_subject_slugs`),
// same Set the server uses for gravity / associations.

function subjectSlugs(api) {
  const site = api.container.lookup("service:site");
  return site?.curiobase_subject_slugs || [];
}

export default apiInitializer((api) => {
  api.replaceTagRenderer((tag, params = {}) => {
    const name = (typeof tag === "string" ? tag : tag?.name || "").toLowerCase();
    const next = { ...params };
    if (name && subjectSlugs(api).includes(name)) {
      next.extraClass = [params.extraClass, "cb-subject-tag"].filter(Boolean).join(" ");
    }
    return defaultRenderTag(tag, next);
  });
});
