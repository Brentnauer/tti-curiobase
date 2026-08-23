/**
 * Client helpers for the Curiobase composer builder.
 * Fence *formatting* stays on the server (RecordWriter); this only parses
 * an existing block for edit-prefill and swaps it in the composer.
 */

export const FENCE_RE = /```curiobase\n[\s\S]*?```/;

const LIST_KEYS = new Set(["period", "evidence", "refs"]);
const EDGE_KEYS = new Set([
  "explains",
  "contradicts",
  "precedes",
  "part_of",
  "involves",
  "same_as",
  "refs",
]);

export function subjectStub() {
  return [
    "```curiobase",
    "type: subject",
    "slug: ",
    "kind: ",
    "domain: ",
    "dek: ",
    "```",
  ].join("\n");
}

export function workStub() {
  return [
    "```curiobase",
    "type: work",
    "slug: ",
    "medium: ",
    "mode: ",
    "dek: ",
    "```",
  ].join("\n");
}

/** Parse the first ```curiobase fence in composer raw into a fields object. */
export function parseFence(raw) {
  if (!raw) {
    return null;
  }
  const match = raw.match(/```curiobase\n([\s\S]*?)```/);
  if (!match) {
    return null;
  }

  const fields = { refs: [] };
  for (const line of match[1].split("\n")) {
    const idx = line.indexOf(":");
    if (idx < 0) {
      continue;
    }
    const key = line.slice(0, idx).trim();
    const value = line.slice(idx + 1).trim();
    if (!key) {
      continue;
    }

    if (EDGE_KEYS.has(key)) {
      const verb = key === "refs" ? "related" : key;
      value
        .split(",")
        .map((s) => s.trim())
        .filter(Boolean)
        .forEach((slug) => fields.refs.push({ verb, slug }));
      continue;
    }

    if (LIST_KEYS.has(key)) {
      fields[key] = value
        .split(",")
        .map((s) => s.trim())
        .filter(Boolean);
      continue;
    }

    fields[key] = value;
  }

  return fields;
}

export function replaceOrInsertFence(toolbarEvent, composerRaw, fence) {
  const existing = composerRaw?.match(FENCE_RE);
  if (existing && typeof toolbarEvent.replaceText === "function") {
    toolbarEvent.replaceText(existing[0], fence);
  } else {
    toolbarEvent.addText(`${fence}\n\n`);
  }
}
