local M = {}
function M.setup(opts)
  require("delta.config").setup(opts)
  require("delta.decorations").highlights()
  require("delta.commands").register()
end
function M.start(base)
  require("delta.session").start(base)
end
function M.close()
  require("delta.session").close()
end
function M.refresh()
  require("delta.session").refresh()
end
function M.toggle_reviewed()
  require("delta.session").reviewed()
end
function M.mark_reviewed()
  require("delta.session").reviewed(true)
end
function M.mark_unreviewed()
  require("delta.session").reviewed(false)
end
function M.next_file()
  require("delta.session").move_file(1)
end
function M.prev_file()
  require("delta.session").move_file(-1)
end
function M.next_hunk()
  require("delta.session").move_hunk(1)
end
function M.prev_hunk()
  require("delta.session").move_hunk(-1)
end
function M.stage_hunk()
  require("delta.operations").run("stage_hunk")
end
function M.unstage_hunk()
  require("delta.operations").run("unstage_hunk")
end
function M.discard_hunk()
  require("delta.operations").run("discard_hunk")
end
function M.restore_base_hunk()
  require("delta.operations").run("restore_base_hunk")
end
function M.progress()
  return require("delta.session").progress()
end
function M.get_session()
  return require("delta.session").active
end
return M
