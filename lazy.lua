-- lazy.nvim reads this file as a spec scoped to this plugin, so a config with
-- no dependencies line still installs live-server.nvim. It lists only the
-- dependency: the common form that also names the plugin itself made
-- lazy.nvim clone upstream beside an install under any other name (a name
-- override, a fork, a dir checkout), and upstream's modules then shadowed the
-- user's copy (measured).
return { { "selimacerbas/live-server.nvim" } }
