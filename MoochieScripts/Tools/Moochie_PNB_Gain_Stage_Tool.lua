-- @description Perfectly Normal Beast Gain Stage Tool
-- @author Moochie
-- @version 1.0
-- @provides [main] .
-- @about -- A tool to normalise tracks / items for input into analog emulation plugins
-- License = GPL v3
--
-- If you want to treat me nice:
-- https://buymeacoffee.com/moochie

local ctx = reaper.ImGui_CreateContext("Gain Stage Tool")

--------------------------------
-- PARAMETERS
--------------------------------

local peak_ceiling = -6
local rms_ceiling = -18
local loud_percent = 40

local analyzed = false
local applied = false

local items = {}
local items_data = {}
local tracks = {}
local track_list = {}
local selected_track = nil

local analyzing = false
local progress = 0
local analyze_index = 1
local analysis_dirty = false
local changes_waiting = false

local last_time = 0
local frame_interval = 1 / 60 --fps

local tooltips = true
local page = 1
local last_page = 1

--------------------------------
-- UTILITIES
--------------------------------

function db(v)
    if v <= 0 then
        return -150
    end
    return 20 * math.log(v, 10)
end

function lin(v)
    return 10 ^ (v / 20)
end

function format_time(seconds)
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    local s = math.floor(seconds % 60)
    local ms = math.floor((seconds % 1) * 1000)

    if h > 0 then
        return string.format("%02d:%02d:%02d:%2d", h, m, s, ms)
    else
        return string.format("%02d:%02d:%2d", m, s, ms)
    end
end

function cleanup_deleted_objects()
    local changed = false

    for i = #items_data, 1, -1 do
        local d = items_data[i]
        if not reaper.ValidatePtr2(0, d.item, "MediaItem*") then
            table.remove(items_data, i)
            changed = true
        end
    end

    for name, data in pairs(tracks) do
        if not reaper.ValidatePtr2(0, data.track, "MediaTrack*") then
            tracks[name] = nil
            changed = true
        end
    end

    return changed
end

function jump_to_item(item)
    if not reaper.ValidatePtr2(0, item, "MediaItem*") then
        return
    end

    local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local tr = reaper.GetMediaItem_Track(item)

    reaper.SetEditCurPos(pos, true, true)

    reaper.Main_OnCommand(40289, 0) -- unselect all items
    reaper.SetMediaItemSelected(item, true)

    reaper.SetCursorContext(1, nil)

    if reaper.ValidatePtr2(0, tr, "MediaTrack*") then
        reaper.SetOnlyTrackSelected(tr)
        reaper.Main_OnCommand(40913, 0) -- vertical scroll selected track into view
    end

    reaper.Main_OnCommand(40914, 0) -- horizontal scroll cursor into view
    reaper.UpdateArrange()
end

function truncate_text(ctx, text, max_width)
    if reaper.ImGui_CalcTextSize(ctx, text) <= max_width then
        return text
    end

    local ellipsis = " (...)"
    local lo = 1
    local hi = #text
    local best = ellipsis

    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        local candidate = text:sub(1, mid) .. ellipsis

        if reaper.ImGui_CalcTextSize(ctx, candidate) <= max_width then
            best = candidate
            lo = mid + 1
        else
            hi = mid - 1
        end
    end

    return best
end

function update_track_cache(track_key)
    local rms_max, peak_max, count = -150, -150, 0

    local data = tracks[track_key]

    if not data or not reaper.ValidatePtr2(0, data.track, "MediaTrack*") then
        return
    end

    local offset = data.offset or 0

    data.warning = false

    for _, d in ipairs(items_data) do
        if d.track == track_key then
            if d.skip then
                data.warning = true
            else
                local predicted_rms = d.rms + d.gain + offset
                local predicted_peak = d.peak + d.gain + offset

                if predicted_rms > rms_max then rms_max = predicted_rms end
                if predicted_peak > peak_max then peak_max = predicted_peak end
                count = count + 1
            end
        end
    end

    -- Store the results in the table instead of just returning them
    data.cached_rms = rms_max
    data.cached_peak = peak_max
    data.cached_count = count
end

function rebuild_all_tracks_cache()
    for _, track_key in ipairs(track_list) do
        update_track_cache(track_key)
    end
end

--------------------------------
-- SCOPE COLLECTION
--------------------------------

function collect_items()
    items = {}

    local track_count = reaper.CountSelectedTracks(0)

    if track_count > 0 then
        for t = 0, track_count - 1 do
            local tr = reaper.GetSelectedTrack(0, t)
            local icount = reaper.CountTrackMediaItems(tr)

            for i = 0, icount - 1 do
                table.insert(items, reaper.GetTrackMediaItem(tr, i))
            end
        end
    else
        local item_count = reaper.CountSelectedMediaItems(0)

        for i = 0, item_count - 1 do
            table.insert(items, reaper.GetSelectedMediaItem(0, i))
        end
    end
end

--------------------------------
-- ITEM ANALYSIS
--------------------------------

function analyze_item(item)
    local take = reaper.GetActiveTake(item)
    if not take then return nil end

    local accessor = reaper.CreateTakeAudioAccessor(take)
    local starttime = reaper.GetAudioAccessorStartTime(accessor)
    local endtime = reaper.GetAudioAccessorEndTime(accessor)

    local samplerate = reaper.GetSetProjectInfo(0, "PROJECT_SRATE", 0, false)
    if samplerate == 0 then samplerate = 44100 end

    local source = reaper.GetMediaItemTake_Source(take)
    local numch = reaper.GetMediaSourceNumChannels(source)
    if numch <= 0 then
        reaper.DestroyAudioAccessor(accessor)
        return nil
    end

    local block = 4096
    local buf = reaper.new_array(block * numch)

    local peak = 0

    -- Top RMS buffer
    local top = {}
    local t = starttime

    while t < endtime do
        reaper.GetAudioAccessorSamples(accessor, samplerate, numch, t, block, buf)
        local sum = 0

        for i = 1, block * numch do
            local s = math.abs(buf[i])
            if s > peak then peak = s end
            sum = sum + s * s
        end

        local rms = math.sqrt(sum / (block * numch))
        if rms > 1e-6 then
            table.insert(top, rms)
        end
        t = t + block / samplerate
    end

    reaper.DestroyAudioAccessor(accessor)

    if #top == 0 then return db(peak), -150 end

    table.sort(top, function(a, b) return a > b end)

    local keep = math.max(1, math.floor(#top * (loud_percent / 100)))
    local total = 0
    for i = 1, keep do
        total = total + top[i]
    end

    return db(peak), db(total / keep)
end

function analyze()
    page = 1

    items = {}
    items_data = {}
    tracks = {}
    track_list = {}

    collect_items()

    analyzing = true
    analyzed = false
    applied = false
    analysis_dirty = false
    analyze_index = 1
    progress = 0
    changes_waiting = false
end

function analyze_step()
    if analyze_index > #items then
        analyzing = false
        analyzed = true
        progress = 1

        rebuild_all_tracks_cache()
        return
    end

    local item = items[analyze_index]

    if not reaper.ValidatePtr2(0, item, "MediaItem*") then
        analyze_index = analyze_index + 1
        return
    end

    local peak, rms = analyze_item(item)

    if peak then
        local gain = math.min(peak_ceiling - peak, rms_ceiling - rms)

        gain = math.max(-24, math.min(24, gain))

        local skip = false
        if peak < -50 or rms < -60 then
            skip = true
            gain = 0
        end

        local tr = reaper.GetMediaItem_Track(item)
        local _, track_name = reaper.GetTrackName(tr)

        local key = tostring(tr)

        if not tracks[key] then
            tracks[key] = {
                offset = 0,
                track = tr,
                name = track_name,
                cached_rms = -150,
                cached_peak = -150,
                cached_count = 0,
                warning = false
            }
            table.insert(track_list, key)
        end

        table.insert(items_data, {
            item = item,
            track = key,
            peak = peak,
            rms = rms,
            gain = gain,
            skip = skip
        })

        if skip and tracks[key] then tracks[key].warning = true end
    end

    analyze_index = analyze_index + 1
    progress = (analyze_index - 1) / #items
end

--------------------------------
-- GUI
--------------------------------

function draw_heat(rms, peak)
    local drive = rms - rms_ceiling

    if peak > 0 then
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFF3333FF)
        reaper.ImGui_Text(ctx, "!!! CLIPPING !!!")
    elseif drive > 4 then
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFF3333FF)
        reaper.ImGui_Text(ctx, "SAT")
    elseif drive > 2 then
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFF7733FF)
        reaper.ImGui_Text(ctx, "HOT")
    elseif drive > 0 then
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFFBB44FF)
        reaper.ImGui_Text(ctx, "WARM")
    elseif drive > -2 then
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x44FF44FF)
        reaper.ImGui_Text(ctx, "CLEAN")
    else
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xAAAAAAFF)
        reaper.ImGui_Text(ctx, "LOW")
    end

    reaper.ImGui_PopStyleColor(ctx)

    return drive
end

function draw_headers()
    reaper.ImGui_Text(ctx, "Peak Ceiling")
    reaper.ImGui_SameLine(ctx, 150)
    reaper.ImGui_SetNextItemWidth(ctx, 80)
    retval, peak_ceiling = reaper.ImGui_InputDouble(ctx, "##peak", peak_ceiling)
    if retval then
        analysis_dirty = true
    end
    if peak_ceiling > 0 then peak_ceiling = 0 end

    if tooltips and reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx,
            "Default = -6")
    end

    reaper.ImGui_SameLine(ctx, 300)
    reaper.ImGui_Text(ctx, "RMS Ceiling")
    reaper.ImGui_SameLine(ctx, 430)
    reaper.ImGui_SetNextItemWidth(ctx, 80)
    retval, rms_ceiling = reaper.ImGui_InputDouble(ctx, "##rms", rms_ceiling)
    if retval then
        analysis_dirty = true
    end
    if rms_ceiling > 0 then rms_ceiling = 0 end

    if tooltips and reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx,
            "Default = -18")
    end

    reaper.ImGui_SameLine(ctx, 640)
    if reaper.ImGui_Checkbox(ctx, 'Tooltips', tooltips) then
        tooltips = not tooltips
    end

    -- Row 2
    reaper.ImGui_Text(ctx, "RMS %")
    reaper.ImGui_SameLine(ctx, 150)
    reaper.ImGui_SetNextItemWidth(ctx, 80)
    retval, loud_percent = reaper.ImGui_InputInt(ctx, "##loud", loud_percent)
    if retval then
        analysis_dirty = true
    end
    if loud_percent > 100 then loud_percent = 100 end
    if loud_percent < 1 then loud_percent = 1 end

    if tooltips and reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx,
            "Percentage of loudest analysis blocks used\nwhen calculating RMS.\n\nLower settings ignore quieter sections\nDefault = 40%")
    end

    reaper.ImGui_Dummy(ctx, 0, 4)

    if reaper.ImGui_Button(ctx, "Analyze") then
        analyze()
    end

    if analyzing then
        reaper.ImGui_SameLine(ctx)
        reaper.ImGui_ProgressBar(ctx, progress, 200, 20)
    end

    reaper.ImGui_SameLine(ctx)

    if analysis_dirty and analyzed then
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0xCCCC33FF)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0xDDDD44FF)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), 0xBBBB22FF)

        if reaper.ImGui_Button(ctx, "Re-Analyze") then
            analyze()
        end

        reaper.ImGui_PopStyleColor(ctx, 3)
    elseif applied then
        if not changes_waiting then
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x44AA44FF)
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x55BB55FF)
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), 0x339933FF)

            reaper.ImGui_Button(ctx, "Applied")

            reaper.ImGui_PopStyleColor(ctx, 3)
        else
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0xCCCC33FF)
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0xDDDD44FF)
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), 0xBBBB22FF)

            if reaper.ImGui_Button(ctx, "Update") then
                apply_gain()
            end

            reaper.ImGui_PopStyleColor(ctx, 3)
        end
    else
        if not analyzing and reaper.ImGui_Button(ctx, "Apply Gain") then
            if not analyzed then
                analyze()
            end
            apply_gain()
        end
    end

    reaper.ImGui_SameLine(ctx, 670)

    if reaper.ImGui_Button(ctx, "Info ⓘ") then
        if page ~= 3 then
            last_page = page
            page = 3
        else
            page = last_page
        end
    end

    reaper.ImGui_Separator(ctx)

    reaper.ImGui_Separator(ctx)
end

function show_items_page(track)
    draw_track_headers()
    local data = draw_track(track)

    if reaper.ImGui_Button(ctx, "Return") then
        page = 1
    end

    draw_item_headers()

    local selected_item = reaper.GetSelectedMediaItem(0, 0)

    reaper.ImGui_BeginChild(ctx, "ITEMA", 0, 0)

    for _, d in ipairs(items_data) do
        local tr = reaper.GetMediaItem_Track(d.item)
        if not reaper.ValidatePtr2(0, tr, "MediaTrack*") then
            goto continue
        end

        if reaper.ValidatePtr2(0, d.item, "MediaItem*") and d.track == track then
            local is_selected = (selected_item == d.item)

            local colour = nil

            if d.skip then
                colour = 0xFF3333FF
            elseif is_selected then
                colour = 0xFFFF88FF
            end

            if colour then
                reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), colour)
            end

            local pos = reaper.GetMediaItemInfo_Value(d.item, "D_POSITION")
            local time = format_time(pos)

            if d.skip then
                local label = time .. "##" .. tostring(d.item)

                if reaper.ImGui_Selectable(ctx, label, false) then
                    jump_to_item(d.item)
                end

                if tooltips and reaper.ImGui_IsItemHovered(ctx) then
                    reaper.ImGui_SetTooltip(ctx, "Jump to item in timeline")
                end

                -- Peak
                reaper.ImGui_SameLine(ctx, 120)
                reaper.ImGui_Text(ctx, string.format("%.1f", d.peak))

                -- RMS
                reaper.ImGui_SameLine(ctx, 190)
                reaper.ImGui_Text(ctx, string.format("%.1f", d.rms))

                -- Gain column
                reaper.ImGui_SameLine(ctx, 260)
                reaper.ImGui_Text(ctx, "--")

                -- Drive column
                reaper.ImGui_SameLine(ctx, 340)
                reaper.ImGui_Text(ctx, "TOO QUIET")
            else
                -- Time
                local label = time .. "##" .. tostring(d.item)

                if reaper.ImGui_Selectable(ctx, label, false) then
                    jump_to_item(d.item)
                end

                if tooltips and reaper.ImGui_IsItemHovered(ctx) then
                    reaper.ImGui_SetTooltip(ctx, "Jump to item in timeline")
                end

                -- Peak
                reaper.ImGui_SameLine(ctx, 120)
                reaper.ImGui_Text(ctx, string.format("%.1f", d.peak))

                -- RMS
                reaper.ImGui_SameLine(ctx, 190)
                reaper.ImGui_Text(ctx, string.format("%.1f", d.rms))

                -- Gain
                reaper.ImGui_SameLine(ctx, 260)
                reaper.ImGui_Text(ctx, string.format("%.1f", d.gain))

                -- Drive
                reaper.ImGui_SameLine(ctx, 340)

                -- current heat
                draw_heat(d.rms, d.peak)

                reaper.ImGui_SameLine(ctx)
                reaper.ImGui_Text(ctx, "→")

                reaper.ImGui_SameLine(ctx)

                -- predicted heat after gain staging
                local predicted_rms = d.rms + d.gain + data.offset
                local predicted_peak = d.peak + d.gain + data.offset
                draw_heat(predicted_rms, predicted_peak)
            end

            if colour then
                reaper.ImGui_PopStyleColor(ctx)
            end
        end

        ::continue::
    end

    reaper.ImGui_EndChild(ctx)
end

function draw_track(track)
    local data = tracks[track]
    if not data then
        return -1
    end

    local track_name = data.name

    reaper.ImGui_Dummy(ctx, 0, 6)

    local tr = data.track

    if not reaper.ValidatePtr2(0, tr, "MediaTrack*") then
        tracks[track] = nil
        return
    end

    local avg_rms = data.cached_rms
    local peak_max = data.cached_peak
    local count = data.cached_count

    -- Track name and colour

    local color = reaper.GetTrackColor(tr)

    if color ~= 0 then
        local r = (color & 0xFF) / 255
        local g = ((color >> 8) & 0xFF) / 255
        local b = ((color >> 16) & 0xFF) / 255

        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),
            reaper.ImGui_ColorConvertDouble4ToU32(r, g, b, 1))

        local display_name = truncate_text(ctx, track_name, 200)
        reaper.ImGui_Text(ctx, display_name)
        if reaper.ImGui_IsItemHovered(ctx) then
            reaper.ImGui_SetTooltip(ctx, track_name)
        end

        reaper.ImGui_PopStyleColor(ctx)
    else
        local display_name = truncate_text(ctx, track_name, 200)
        reaper.ImGui_Text(ctx, display_name)
        if reaper.ImGui_IsItemHovered(ctx) then
            reaper.ImGui_SetTooltip(ctx, track_name)
        end
    end

    -- Item count column
    reaper.ImGui_SameLine(ctx, 220)

    if reaper.ImGui_Button(ctx, count .. " items##" .. track) then
        selected_track = track
        if page == 2 then
            page = 1
        else
            page = 2
        end
    end

    -- too quiet warning
    local warn = data.warning
    if warn then
        reaper.ImGui_SameLine(ctx)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFF3333FF)
        reaper.ImGui_Text(ctx, "!")
        reaper.ImGui_PopStyleColor(ctx)
    end

    -- Offset slider column
    reaper.ImGui_SameLine(ctx, 320)
    reaper.ImGui_SetNextItemWidth(ctx, 120)
    if data.offset > 6 then data.offset = 6 end
    if data.offset < -6 then data.offset = -6 end
    retval, data.offset = reaper.ImGui_SliderDouble(ctx, "##Offset" .. track, data.offset, -6, 6)

    if retval then
        changes_waiting = true
        update_track_cache(track)
    end

    -- Avg RMS
    reaper.ImGui_SameLine(ctx, 460)
    reaper.ImGui_Text(ctx, string.format("%.1f", avg_rms))

    -- Peak
    reaper.ImGui_SameLine(ctx, 540)
    reaper.ImGui_Text(ctx, string.format("%.1f", peak_max))

    -- Drive
    reaper.ImGui_SameLine(ctx, 610)
    draw_heat(avg_rms, peak_max)
    if tooltips and reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx, "Plugin drive estimate based on RMS and peak level.")
    end

    return data
end

function show_info_page()
    reaper.ImGui_TextColored(ctx, 0xFFFF00FF,
        "                                                                              Perfectly Normal Beast Gain Stage Tool")
    reaper.ImGui_Separator(ctx)

    reaper.ImGui_BeginChild(ctx, "Inform", 0, 0)
    reaper.ImGui_TextColored(ctx, 0xFFFF00FF, [[
    Purpose:]])



    reaper.ImGui_Text(ctx, [[
        Create consistent input levels for analog-style plugins and establish a solid gain structure to start mixing.

]])
    reaper.ImGui_Separator(ctx)


    reaper.ImGui_TextColored(ctx, 0xFFFF00FF, [[
    Controls and Notes:]])

    reaper.ImGui_Text(ctx, [[
        Hover controls for tooltips.

        Ctrl (Cmd on Mac) click sliders to input values directly.

        The tool works non-destrucively based on original source levels,
            ignoring faders / automation and envelopes.

        Gain changes are written to Item Properties and are NOT cumulative
            - pressing Apply twice will produce identical results.

        Click on an analyzed item to jump to it in the timeline.

        Works on Tracks or Items, If both are selected prioritises Tracks.

        Spilt items by section, phrase, or even note if you want a more granular normalisation.
      ]])

    reaper.ImGui_Separator(ctx)

    reaper.ImGui_TextColored(ctx, 0xFFFF00FF, [[
    Suggested Workflow:]])

    reaper.ImGui_Text(ctx, [[
        1. Import tracks into your mix template / session.

           At the default Peak and RMS settings, Track faders should
           be set to -10 dB, which will leave around -6 to -10 dB
           of mixbus headroom on a full production post gain adjsutment.

        2. Clean up audio (Optional, but recommended):

          • remove silence
          • split or consolidate tracks if needed
          • fix obvious gain spikes or noise

        3. Select tracks or items and press ANALYZE.

        4. Review predicted levels and Drive classification.

        5. Adjust track Offset sliders if needed.

        6. Press APPLY GAIN to write gain changes to item takes.
      ]])



    if reaper.ImGui_Button(ctx, "Return") then
        page = last_page
    end

    reaper.ImGui_EndChild(ctx)
end

function draw_track_headers()
    reaper.ImGui_Text(ctx, "Track")

    reaper.ImGui_SameLine(ctx, 220)
    reaper.ImGui_Text(ctx, "Items")

    reaper.ImGui_SameLine(ctx, 320)
    reaper.ImGui_Text(ctx, "Offset")

    reaper.ImGui_SameLine(ctx, 460)
    reaper.ImGui_Text(ctx, "Avg RMS")
    if tooltips and reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx,
            "Post gain RMS prediction")
    end

    reaper.ImGui_SameLine(ctx, 540)
    reaper.ImGui_Text(ctx, "Peak")
    if tooltips and reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx,
            "Post gain Peak prediction")
    end

    reaper.ImGui_SameLine(ctx, 610)
    reaper.ImGui_Text(ctx, "Drive")

    reaper.ImGui_Separator(ctx)
end

function draw_item_headers()
    reaper.ImGui_Text(ctx, [[TimeLine
Position]])

    reaper.ImGui_SameLine(ctx, 120)
    reaper.ImGui_Text(ctx, [[Current
Peak]])

    reaper.ImGui_SameLine(ctx, 190)
    reaper.ImGui_Text(ctx, [[Current
RMS]])

    reaper.ImGui_SameLine(ctx, 260)
    reaper.ImGui_Text(ctx, [[Gain
Change]])

    reaper.ImGui_SameLine(ctx, 340)
    reaper.ImGui_Text(ctx, [[
         Drive]])

    reaper.ImGui_Separator(ctx)
end

function show_tracks_page()
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 0, 0)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), 8, 4)

    if reaper.ImGui_BeginChild(ctx, "HeaderStrip", 0, 30, reaper.ImGui_ChildFlags_None(), reaper.ImGui_WindowFlags_NoScrollbar()) then
        draw_track_headers()
        reaper.ImGui_EndChild(ctx)
    end

    if reaper.ImGui_BeginChild(ctx, "Page1 Window", 0, 0, reaper.ImGui_ChildFlags_None()) then
        for _, track in ipairs(track_list) do
            draw_track(track)
        end
        reaper.ImGui_EndChild(ctx)
    end

    reaper.ImGui_PopStyleVar(ctx, 2)
end

--------------------------------
-- APPLY GAIN
--------------------------------

function apply_gain()
    reaper.PreventUIRefresh(1)

    reaper.Undo_BeginBlock()

    for _, d in ipairs(items_data) do
        local tr = reaper.GetMediaItem_Track(d.item)
        if not reaper.ValidatePtr2(0, tr, "MediaTrack*") then
            goto continue
        end

        if reaper.ValidatePtr2(0, d.item, "MediaItem*") then
            local take = reaper.GetActiveTake(d.item)

            if take then
                local track_data = tracks[d.track]
                if not track_data then
                    goto continue
                end

                local offset = track_data.offset
                local final_gain = d.gain + offset

                reaper.SetMediaItemTakeInfo_Value(take, "D_VOL", lin(final_gain))
            end
        end
        ::continue::
    end

    reaper.Undo_EndBlock("Gain stage items", -1)
    reaper.UpdateArrange()
    reaper.PreventUIRefresh(-1)
    applied = true
    changes_waiting = false
end

--------------------------------
-- MAIN
--------------------------------

function loop()
    local now = reaper.time_precise()

    if now - last_time < frame_interval then
        reaper.defer(loop)
        return
    end

    last_time = now

    reaper.ImGui_SetNextWindowSize(ctx, 720, 520, reaper.ImGui_Cond_Appearing())

    local visible, open = reaper.ImGui_Begin(ctx, "PNB Gain Stage Tool", true, reaper.ImGui_WindowFlags_NoDocking())

    if analyzing then
        analyze_step()
    end

    local changed = cleanup_deleted_objects()
    if changed then
        rebuild_all_tracks_cache()
    end

    if visible then
        if reaper.ImGui_IsWindowFocused(ctx, reaper.ImGui_FocusedFlags_RootAndChildWindows()) then
            if not reaper.ImGui_IsAnyItemActive(ctx) then
                reaper.JS_Window_SetFocus(reaper.GetMainHwnd())
            end
        end

        draw_headers()

        if page == 1 then
            if analyzed then
                show_tracks_page()
            end
        elseif page == 2 then
            if selected_track then
                show_items_page(selected_track)
            else
                reaper.ImGui_Text(ctx, "No track selected")
                if reaper.ImGui_Button(ctx, "Return") then
                    page = 1
                end
            end
        elseif page == 3 then
            show_info_page()
        end
    end

    reaper.ImGui_End(ctx)

    if open then
        reaper.defer(loop)
    end
end

loop()
