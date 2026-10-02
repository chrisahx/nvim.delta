if vim.g.loaded_delta then
  return
end
vim.g.loaded_delta = true
if vim.fn.has("nvim-0.10") == 0 then
  vim.notify("delta requires Neovim >= 0.10", vim.log.levels.ERROR)
  return
end
require("delta.decorations").highlights()
require("delta.commands").register()
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("DeltaHighlights", { clear = true }),
  callback = function()
    require("delta.decorations").highlights()
  end,
})
