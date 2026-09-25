-- lazy.nvim reads this file as a spec scoped to this plugin, so a config with
-- no dependencies line still installs live-server.nvim. It lists only the
-- dependency. The self-named shape lazy.nvim's docs show for a plugin's
-- lazy.lua (return { "me/my-plugin", opts = {} }, doc/lazy.nvim.txt,
-- Developers) is deliberately not taken: it made lazy.nvim clone upstream
-- beside an install under any other name (a name override, a fork, a dir
-- checkout), and upstream's modules then shadowed the user's copy (measured).
return { { "selimacerbas/live-server.nvim" } }
