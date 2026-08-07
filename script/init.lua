--  ___ _        _           _     
-- / __| |_ __ _| |_ ___ _ _(_)___ 
-- \__ \  _/ _` |  _/ _ \ '_| / _ \
-- |___/\__\__,_|\__\___/_| |_\___/
--
-- Mod init routines for when first
-- loaded, upgraded, etc.

local initialize = function()
  -- when game starts, or mod added to existing save
  -- use to initialize global variables

  log("initialize()")

  -- global.statorio is persisted between sessions
  global.statorio = {}

  -- store user's metric list here for persistence
  global.statorio.metrics = {}

end

local reload = function()

  -- cache game settings
  Settings.init()

  -- prepare publisher
  Publisher.init()

end

local registerEvents = function()
  script.on_nth_tick(nil)
  script.on_nth_tick(Settings.getRuntimeGlobal("statorio-frequency"), OnNthTick)
end

-- called when a save game is loaded that previously
-- had this mod
script.on_load(function()
  reload()
  registerEvents()
end)

-- called when a new game is created with this mod
-- or when the mod is first used on an existing game
script.on_init(function()
  reload()
  initialize()
  registerEvents()

  log("Statorio initialized")
end)

-- called any time the game version changes and any
-- time mod versions change, including adding or
-- removing mod
script.on_configuration_changed(function(data)
-- TODO: upgrade path
--  reload()
--  registerEvents()
--  log("Statorio configuration updated")
end)


script.on_event(defines.events.on_runtime_mod_setting_changed, function(event)
  if not event then return end

  if not event.setting then return end

  -- settings are received from the game api, so are assumed to be valid

  if event.setting_type == "runtime-global" then
    Settings.setRuntimeGlobal(event.setting, settings.global[event.setting].value)

    -- this change needs to re-register the on_nth_tick event
    if event.setting == "statorio-frequency" then registerEvents() end

    -- this change needs to clean up the old file
    if event.setting == "statorio-filename" then Publisher.setFilename(settings.global[event.setting].value) end
  end
end)