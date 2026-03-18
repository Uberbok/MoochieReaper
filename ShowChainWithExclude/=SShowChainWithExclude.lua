function open_fx_windows_excluding()
    local num_tracks = reaper.CountSelectedTracks(0)
    
    for i = 0, num_tracks - 1 do
        local track = reaper.GetSelectedTrack(0, i)
        local num_fx = reaper.TrackFX_GetCount(track)
        
        for fx = 0, num_fx - 1 do
            local is_bypassed = reaper.TrackFX_GetEnabled(track, fx) == false
            
            if not is_bypassed then
                reaper.TrackFX_Show(track, fx, 3) -- Open FX window
            end
        end
    end
end

reaper.Undo_BeginBlock()
open_fx_windows_excluding()
reaper.Undo_EndBlock("Open FX Windows Excluding Bypassed FX", -1)
