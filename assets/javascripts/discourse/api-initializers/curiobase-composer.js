import { apiInitializer } from "discourse/lib/api";
import {
  replaceOrInsertFence,
  subjectStub,
  workStub,
} from "../lib/curiobase-fence";

function canBuildRecord(composer, api) {
  const siteSettings = api.container.lookup("service:site-settings");
  const currentUser = api.getCurrentUser();
  if (!siteSettings?.curiobase_enabled || !currentUser?.staff) {
    return false;
  }

  const model = composer?.model;
  if (!model) {
    return false;
  }

  // Prefer Discourse's first-post helpers; fall back to action checks in case
  // a computed is not yet live when the + menu builds.
  if (model.topicFirstPost || model.creatingTopic || model.editingFirstPost) {
    return true;
  }

  return model.action === "createTopic" || model.action === "edit";
}

async function openBuilder(api, composer, toolbarEvent) {
  const modal = api.container.lookup("service:modal");
  // Lazy-load so a modal compile error cannot wipe the + menu entries.
  const { default: CuriobaseRecordBuilder } = await import(
    "../components/modal/curiobase-record-builder"
  );
  modal.show(CuriobaseRecordBuilder, {
    model: {
      toolbarEvent,
      composer,
      topicId: composer.model?.topic?.id,
    },
  });
}

export default apiInitializer("1.0", (api) => {
  const composer = api.container.lookup("service:composer");

  api.addComposerToolbarPopupMenuOption({
    name: "curiobase-build",
    action: (toolbarEvent) => openBuilder(api, composer, toolbarEvent),
    icon: "book",
    label: "curiobase.composer.build",
    condition: (composerService) => canBuildRecord(composerService, api),
  });

  api.addComposerToolbarPopupMenuOption({
    name: "curiobase-stub-subject",
    action: (toolbarEvent) => {
      replaceOrInsertFence(
        toolbarEvent,
        composer.model?.reply,
        subjectStub()
      );
    },
    icon: "file",
    label: "curiobase.composer.stub_subject",
    condition: (composerService) => canBuildRecord(composerService, api),
  });

  api.addComposerToolbarPopupMenuOption({
    name: "curiobase-stub-work",
    action: (toolbarEvent) => {
      replaceOrInsertFence(toolbarEvent, composer.model?.reply, workStub());
    },
    icon: "film",
    label: "curiobase.composer.stub_work",
    condition: (composerService) => canBuildRecord(composerService, api),
  });
});
