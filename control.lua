-----------------------------------
--  ___ _        _           _     
-- / __| |_ __ _| |_ ___ _ _(_)___ 
-- \__ \  _/ _` |  _/ _ \ '_| / _ \
-- |___/\__\__,_|\__\___/_| |_\___/
--
-- --------------------------------
-- Collect statistics from Factorio
-- game APIs and write them to disk
-- in JSON for consumption in other
-- dashboard software or something.
--
-- This is the runtime script which
-- is executed during gameplay.
-----------------------------------


-- load dependencies


-- general utility functions
require "script.utilities"

-- mod settings cache
Settings = require("script.settings")

-- initialize mod, set event handlers
-- this triggers OnNthTick() below
require "script.init"

-- console command definitions
require "script.commands"

-- used to write or broadcast metrics
Publisher = require("script.publisher")

-- keeps a list of metrics to watch, fetches
-- them when requested from the game api
Fetcher = require("script.fetcher")



-- main loop
OnNthTick = function()

  -- iterate through requested metrics
  for index, name in pairs(global.statorio.metrics) do

    -- fetch metric
    if not Fetcher.traverseApiForValues(name, function(name, val)

        -- cache value for publication
        Publisher.addMetric(name, data)
      end)
    then

      -- failed
      log("Failed to fetch metric "..name)

    end
  end

  -- publish all cached metrics
  Publisher.publish()
end