if vim.g.loaded_review then
  return
end
vim.g.loaded_review = true
if vim.fn.has("nvim-0.10") == 0 then
  vim.notify("review requires Neovim >= 0.10", vim.log.levels.ERROR)
  return
end
require("review.decorations").highlights()
require("review.commands").register()
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("ReviewHighlights", { clear = true }),
  callback = function()
    require("review.decorations").highlights()
  end,
})
