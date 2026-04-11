-- dayflow inbox-throw hotkey
-- Append this to ~/.hammerspoon/init.lua and reload Hammerspoon.
--
-- Default binding: Cmd + Shift + I  ("I" for Inbox).
-- Change `mods` / `key` below if it conflicts with another app.

local INB_BIN = os.getenv("HOME") .. "/dayflow/.venv/bin/inb"

local function dayflowThrow()
  local btn, text = hs.dialog.textPrompt(
    "dayflow",
    "Throw a task into the inbox:",
    "",
    "Add",
    "Cancel"
  )
  if btn ~= "Add" then return end
  text = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then return end

  local task = hs.task.new(INB_BIN, function(exitCode, stdOut, stdErr)
    if exitCode == 0 then
      hs.alert.show("✓ " .. text, 1)
    else
      hs.alert.show("✗ inb failed: " .. (stdErr or ""), 3)
    end
  end, { text })
  task:start()
end

hs.hotkey.bind({ "cmd", "shift" }, "I", dayflowThrow)
