--[[
  tagcal.lua  -  reusable draw_text calibration overlay for Chimera Lua.

  DROP-IN LIBRARY (callback-free). Merge into the script you want to calibrate,
  then wire it in that script:

    -- toggle from your command callback:
    if cmd:lower() == "tagcal" then cal_on = not cal_on return false end

    -- draw from your OnPreFrame OR OnPreCamera (coords are fixed, camera-free):
    if cal_on then draw_calibration() end

  Renders a ruler of left-aligned labels at known x-coords plus center/right
  alignment tests, so one screenshot reveals the draw_text coordinate space and
  alignment behaviour (see the notes below).
--]]

clua_version = 2.056

-- ============================================================
-- CALIBRATION OVERLAY (temporary diagnostic)
--
-- Toggle with console command: tagcal
-- Draws fixed strings at KNOWN coordinates, independent of camera or
-- players, so a single screenshot reveals:
--   1. The horizontal coordinate width (640 vs 853) - read where the
--      left-aligned ruler labels land relative to the viewport edges.
--   2. What "center" alignment does - test A and test B use DIFFERENT
--      boxes; if their text centers on each box, "center" is box-relative;
--      if both land at the same x, "center" is viewport-relative.
-- left-align is the trusted anchor here: the first glyph's LEFT edge sits
-- at the `left` coordinate.
-- ============================================================
cal_on = false
cal_on = false

function draw_calibration()
    -- White ruler: each label's LEFT edge marks that exact x coordinate.
    local ruler = {0, 160, 320, 426, 480, 640, 800, 853}
    for _, xv in ipairs(ruler) do
        draw_text("|" .. xv, xv, 120, xv + 70, 135, "smaller", "left", 1, 1, 1, 1)
    end

    -- Test A: box [300,400], box-center = 350. Yellow.
    draw_text("AAAA", 300, 170, 400, 185, "smaller", "center", 1, 1, 1, 0.2)
    -- Test B: box [600,700], box-center = 650. Orange.
    draw_text("BBBB", 600, 200, 700, 215, "smaller", "center", 1, 1, 0.5, 0.1)
    -- Right-align test: box [300,400], text RIGHT edge should sit at 400. Cyan.
    draw_text("RRRR", 300, 230, 400, 245, "smaller", "right", 1, 0.2, 1, 1)
    -- Left-align reference at box-A left (300) and box-B left (600). Green.
    draw_text("L", 300, 260, 360, 275, "smaller", "left", 1, 0.2, 1, 0.2)
    draw_text("L", 600, 260, 660, 275, "smaller", "left", 1, 0.2, 1, 0.2)
end
