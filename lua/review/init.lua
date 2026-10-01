local M = {}
function M.setup(opts)
  require("review.config").setup(opts)
  require("review.decorations").highlights()
  require("review.commands").register()
end
function M.start(base)
  require("review.session").start(base)
end
function M.close()
  require("review.session").close()
end
function M.refresh()
  require("review.session").refresh()
end
function M.toggle_reviewed()
  require("review.session").reviewed()
end
function M.mark_reviewed()
  require("review.session").reviewed(true)
end
function M.mark_unreviewed()
  require("review.session").reviewed(false)
end
function M.next_file()
  require("review.session").move_file(1)
end
function M.prev_file()
  require("review.session").move_file(-1)
end
function M.next_hunk()
  require("review.session").move_hunk(1)
end
function M.prev_hunk()
  require("review.session").move_hunk(-1)
end
function M.progress()
  return require("review.session").progress()
end
function M.get_session()
  return require("review.session").active
end
return M
