# frozen_string_literal: true

module Curiobase
  # Kept for the namespace and for autoloading app/ — nothing else.
  #
  # ⚠ THIS ENGINE DOES NOT ROUTE. Routes are registered directly into
  #   Discourse's own route set in plugin.rb.
  #
  #   Mounting it worked — `/curiobase` appeared in the route table — but the
  #   engine's own route set came back empty, so every path under it 404'd. Two
  #   separate debugging sessions went into that, and an engine buys nothing
  #   here: there is no isolation to gain, no reusable mountable component, and
  #   one more layer whose failure mode is a silent 404.
  #
  #   Plain routes into Discourse's route set are what most plugins use and
  #   what demonstrably works.
  class Engine < ::Rails::Engine
    # Must be a valid Ruby identifier — PLUGIN_NAME is "tti-curiobase" and the
    # hyphen makes engine_name unusable.
    engine_name "curiobase"
    isolate_namespace Curiobase

    # ⚠ Give up lib/tasks, or every rake task in this plugin runs TWICE.
    #
    #   Two separate loaders find the same .rake file:
    #     · Discourse — Plugin::Instance#activate! calls
    #       Rake.add_rakelib(<plugin>/lib/tasks)          lib/plugin/instance.rb:877
    #     · Rails     — Engine#run_tasks_blocks does
    #       paths["lib/tasks"].existent.sort.each { load } railties/rails/engine.rb:687
    #
    #   Rake APPENDS to a task rather than replacing it, so the block ends up
    #   registered twice and the body executes twice. Observed: one
    #   `rake curiobase:rebake` printed "Rebaking 3 posts / Done" twice.
    #
    #   Harmless for an idempotent rebake. Not harmless for anything that
    #   counts, charges, posts, or writes to WordPress.
    paths["lib/tasks"] = []

    # ⚠ DO NOT add `config.autoload_paths << ".../app"`.
    #
    #   Rails::Engine already registers each app/* subdirectory as its own
    #   autoload root. Adding `app` itself makes Zeitwerk manage the same files
    #   under two roots and expect app/services/curiobase/card_renderer.rb to
    #   define Services::Curiobase::CardRenderer.
    #
    #   Zeitwerk then raises during boot, after_initialize aborts partway, and
    #   every symptom is silent: the plugin still lists as enabled, its site
    #   settings still exist, but no routes mount and no hooks fire. That cost
    #   an hour.
  end
end
