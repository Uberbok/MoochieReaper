-- @description Show FX windows exlcuiding Bypassed
-- @author Moochie
-- @version 1.0
-- @provides [main] .
-- @about
-- A script action to open FX windows for selected track(s), excluding bypassed FX


function open_fx_windows_excluding()
    local num_tracks = reaper.CountSelectedTracks(0)
    
    for i = 0, num_tracks - 1 do
        local track = reaper.GetSelectedTrack(0, i)
        local num_fx = reaper.TrackFX_GetCount(track)
        
        for fx = 0, num_fx - 1 do
            local is_bypassed = reaper.TrackFX_GetEnabled(track, fx) == false
            
            if not is_bypassed then
                reaper.TrackFX_Show(track, fx, 3)
            end
        end
    end
end

reaper.Undo_BeginBlock()
open_fx_windows_excluding()
reaper.Undo_EndBlock("Open FX Windows Excluding Bypassed FX", -1)
