-- lazy.nvim reads this file as the plugin's own spec, so live-server.nvim is
-- installed with no dependencies line in the user's config. Measured with
-- lazy.nvim: a first install clones it in the same startup, and a user spec's
-- url (a fork) still wins over the name below.
return {
	"selimacerbas/markdown-preview.nvim",
	dependencies = { "selimacerbas/live-server.nvim" },
}
