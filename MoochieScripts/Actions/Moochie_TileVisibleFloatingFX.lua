-- @description Tile Visible Floating FX Windows
-- @author Moochie
-- @version 1.0
-- @provides [main] .
-- @about 
--     A bindable script action to tile visible floating FX windows
--     Licencse = GPL v3

local windows = {}

------------------------------------------------
-- Collect floating FX windows
------------------------------------------------

local function CollectFX(track)

    local fxCount = reaper.TrackFX_GetCount(track)

    for fx = 0, fxCount - 1 do

        local hwnd = reaper.TrackFX_GetFloatingWindow(track, fx)

        if hwnd then
            table.insert(windows, hwnd)
        end
    end
end

-- Normal tracks
for t = 0, reaper.CountTracks(0) - 1 do
    CollectFX(reaper.GetTrack(0, t))
end

-- Master track
CollectFX(reaper.GetMasterTrack(0))

------------------------------------------------
-- Abort if none
------------------------------------------------

if #windows == 0 then
    reaper.ShowMessageBox(
        "No floating FX windows found.",
        "Arrange FX",
        0
    )
    return
end

------------------------------------------------
-- Screen area
------------------------------------------------

local left, top, right, bottom =
    reaper.JS_Window_GetViewportFromRect(
        0, 0, 0, 0, false
    )

local padding = 1

local x = left + padding
local y = top + padding

local rowHeight = 0

------------------------------------------------
-- Arrange windows
------------------------------------------------
for _, hwnd in ipairs(windows) do

    local retval, l, t, r, b =
        reaper.JS_Window_GetRect(hwnd)

    if retval then

        local w = r - l
        local h = b - t

        -- wrap to next row
        if x + w > right then

            x = left + padding
            y = y + rowHeight + padding

            rowHeight = 0
        end

        reaper.JS_Window_SetPosition(
            hwnd,
            x,
            y,
            w,
            h
        )

        x = x + w + padding

        if h > rowHeight then
            rowHeight = h
        end
    end
end

reaper.UpdateArrange()
