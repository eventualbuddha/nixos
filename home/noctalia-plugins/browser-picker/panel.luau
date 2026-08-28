-- Browser profile picker: opened via `noctalia msg panel-open browser-picker
-- <url>` (or panel-toggle with no url). Shows which site is about to open and
-- two buttons -- one per Helium profile -- each launching
-- `helium --profile-directory=<id> <url>` and closing the panel. Pressing "1"
-- or "2" does the same instantly, via the manifest's capture_keys.

-- Colors: "Default" is a neutral gray; "VotingWorks" is voting.works' own
-- brand purple (--primary in their site CSS, confirmed 2026-08-28).
local PROFILES = {
  { id = "Default", label = "Default", key = "1", color = "#6C757D" },
  { id = "VotingWorks", label = "VotingWorks", key = "2", color = "#6F42C1" },
}

local currentUrl = ""
local currentDomain = ""
local iconPath = nil
-- True when iconPath is a dark-on-transparent icon (favicon.ico, or a site's
-- normal <link rel=icon>) that needs a light backdrop to read on this dark
-- panel; false when it's a purpose-fetched dark-theme variant (already
-- light-colored, so a white backdrop would just hide it again).
local iconNeedsBackdrop = false

-- domain|dark / domain|light -> resolved local file path. In-memory only
-- (cleared on a noctalia restart), but that's fine: panel opens are
-- infrequent enough that a session-lifetime cache is plenty.
local iconCache = {}

local function domainFromUrl(url)
  if url == "" then
    return ""
  end
  local domain = url:match("^%a[%w+.-]*://([^/]+)")
  if domain == nil then
    return url
  end
  return (domain:gsub(":%d+$", ""))
end

local function extensionFromUrl(url)
  local path = url:match("^[^?]*") or url
  local ext = path:match("%.([%a0-9]+)$")
  return ext and ext:lower() or "img"
end

-- "https://x.com/a/favicon.svg?v=2" -> "https://x.com/a/favicon-dark.svg?v=2".
-- No convention guarantees this file exists (GitHub is confirmed to serve
-- exactly this pattern, verified 2026-08-28); callers must fall back on 404.
local function withDarkSuffix(url)
  local base, query = url:match("^([^?]*)(.*)$")
  local prefix, ext = base:match("^(.*)%.([%a0-9]+)$")
  if prefix == nil then
    return nil
  end
  return prefix .. "-dark." .. ext .. query
end

-- Resolves a relative href against scheme+domain the same way a browser
-- would for "//host/x", "/x", and bare "x" forms.
local function resolveHref(href, scheme, domain)
  if href:sub(1, 2) == "//" then
    return scheme .. ":" .. href
  elseif href:match("^https?://") then
    return href
  elseif href:sub(1, 1) == "/" then
    return scheme .. "://" .. domain .. href
  end
  return scheme .. "://" .. domain .. "/" .. href
end

-- First declared non-touch icon link in the page's <head>, e.g.
-- <link rel="icon" href="/favicon.svg">. Lua patterns can't express
-- attribute-order independence or alternation, so this scans each <link ...>
-- tag's rel/href attributes individually rather than matching the tag whole.
--
-- Scoped to a leading slice of the body, not the whole page: plugin script
-- callbacks get a 25ms CPU budget, and a real homepage can be tens to
-- hundreds of KB (google.com is ~85KB) -- scanning all of it blew that
-- budget and silently dropped the callback. Favicon links are always near
-- the top of <head>, well within this slice, on every site tested.
local kHeadScanBytes = 16384

local function findIconHref(html, scheme, domain)
  local head = html:sub(1, kHeadScanBytes)
  for tag in head:gmatch("<link[^>]*>") do
    local rel = tag:match('rel%s*=%s*"([^"]+)"') or tag:match("rel%s*=%s*'([^']+)'")
    if rel then
      local relLower = rel:lower()
      if relLower == "icon" or relLower == "shortcut icon" or relLower == "alternate icon" then
        local href = tag:match('href%s*=%s*"([^"]+)"') or tag:match("href%s*=%s*'([^']+)'")
        if href and href ~= "" then
          return resolveHref(href, scheme, domain)
        end
      end
    end
  end
  return nil
end

local function openProfile(profileId)
  local args = { "helium", "--profile-directory=" .. profileId }
  if currentUrl ~= "" then
    table.insert(args, currentUrl)
  end
  noctalia.runAsync(args)
  panel.close()
end

local function render()
  local children = {}

  -- Always a fixed 28x28 slot, whether it holds the "no domain to fetch for"
  -- glyph, the loading placeholder, or the resolved icon, so the layout
  -- never jumps as state changes -- only what's drawn inside (and its
  -- backdrop) does.
  local slotContent
  local slotFill = nil
  if currentDomain == "" then
    slotContent = { type = "glyph", props = { name = "browser", size = 16, color = "on_surface_variant" } }
    slotFill = "on_surface/0.10"
  elseif iconPath ~= nil then
    slotContent = { type = "image", props = { path = iconPath, width = 18, height = 18, fit = "contain" } }
    if iconNeedsBackdrop then
      -- Favicons are usually drawn dark-on-transparent for a light page, so
      -- they vanish against this panel's dark background without a light
      -- backdrop behind them. Skipped for a purpose-fetched dark-theme
      -- icon: that one is already light-colored, and a white backdrop would
      -- just hide it again.
      slotFill = "#FFFFFF"
    end
  else
    slotContent = { type = "glyph", props = { name = "world", size = 16, color = "on_surface_variant" } }
    slotFill = "on_surface/0.10"
  end

  -- A raised "card" for the site row, echoing the button treatment below
  -- instead of floating bare text on the panel background.
  table.insert(children, {
    type = "row",
    props = {
      key = "site",
      gap = 10,
      align = "center",
      fill = "on_surface/0.06",
      border = "outline/0.5",
      borderWidth = 1,
      radius = 10,
      paddingH = 12,
      paddingV = 10,
    },
    children = {
      {
        type = "row",
        props = { width = 28, height = 28, fill = slotFill, radius = 14, justify = "center", align = "center" },
        children = { slotContent },
      },
      {
        type = "label",
        props = {
          text = currentDomain ~= "" and currentDomain or "New window",
          fontSize = 15,
          fontWeight = "medium",
        },
      },
    },
  })

  -- Pill-shaped colored buttons: the native "button" node only offers fixed
  -- style variants (no arbitrary fill color), so these are clickable "row"
  -- containers instead -- rows support fill/radius/onClick directly. Border
  -- uses the theme's own "outline" role, matching noctalia's own card/button
  -- chrome (e.g. the control-center panel) instead of an ad hoc dark edge.
  -- A small translucent chip echoes GitHub's "Submit review ^⏎" treatment
  -- to show the "1"/"2" instant-key shortcut.
  local buttonChildren = {}
  for _, profile in ipairs(PROFILES) do
    table.insert(buttonChildren, {
      type = "row",
      props = {
        key = profile.id,
        fill = profile.color,
        border = "outline",
        borderWidth = 1,
        radius = 12,
        paddingH = 14,
        paddingV = 12,
        gap = 10,
        justify = "space_between",
        align = "center",
        flexGrow = 1,
        onClick = function()
          openProfile(profile.id)
        end,
      },
      children = {
        {
          type = "label",
          props = { text = profile.label, color = "#FFFFFF", fontSize = 14, fontWeight = "bold" },
        },
        {
          type = "row",
          props = {
            fill = "#00000038",
            radius = 6,
            paddingH = 7,
            paddingV = 3,
          },
          children = {
            { type = "label", props = { text = profile.key, color = "#FFFFFFE6", fontSize = 12, fontWeight = "bold" } },
          },
        },
      },
    })
  end
  table.insert(children, {
    type = "row",
    props = { key = "buttons", gap = 12 },
    children = buttonChildren,
  })

  panel.render({
    type = "column",
    props = { gap = 14, padding = 20, align = "stretch", justify = "center" },
    children = children,
  })
end

function onOpen(context)
  currentUrl = context or ""
  currentDomain = domainFromUrl(currentUrl)
  iconPath = nil
  iconNeedsBackdrop = false
  render()

  if currentDomain == "" then
    return
  end

  local dark = noctalia.isDarkMode()
  local cacheKey = currentDomain .. (dark and "|dark" or "|light")
  local cached = iconCache[cacheKey]
  if cached ~= nil then
    iconPath = cached.path
    iconNeedsBackdrop = cached.needsBackdrop
    render()
    return
  end

  local dataDir = noctalia.pluginDataDir()
  if dataDir == nil then
    return
  end

  local scheme = "https"
  local openedDomain = currentDomain -- guards a stale async result after reopening on a different site

  local function useIcon(path, needsBackdrop)
    iconCache[cacheKey] = { path = path, needsBackdrop = needsBackdrop }
    if currentDomain == openedDomain then
      iconPath = path
      iconNeedsBackdrop = needsBackdrop
      render()
    end
  end

  -- Last resort: the well-known default location, not declared by any <link>.
  -- Always a "light" icon (dark glyph) -- sites don't theme this convention.
  local function tryFaviconIco()
    local dest = dataDir .. "/" .. currentDomain .. ".ico"
    noctalia.download(scheme .. "://" .. currentDomain .. "/favicon.ico", dest, function(ok)
      if ok then
        useIcon(dest, true)
      end
    end)
  end

  noctalia.http({ url = scheme .. "://" .. currentDomain .. "/", method = "GET", follow_redirects = true }, function(res)
    if not (res.ok and res.body ~= nil and res.body ~= "") then
      tryFaviconIco()
      return
    end

    local href = findIconHref(res.body, scheme, currentDomain)
    if href == nil then
      tryFaviconIco()
      return
    end

    local ext = extensionFromUrl(href)

    local function useLightVariant()
      local dest = dataDir .. "/" .. currentDomain .. "-light." .. ext
      noctalia.download(href, dest, function(ok)
        if ok then
          useIcon(dest, true)
        else
          tryFaviconIco()
        end
      end)
    end

    -- Only bother probing for a dark variant when the system is actually in
    -- dark mode -- otherwise the light icon is exactly what we want anyway.
    if dark then
      local darkHref = withDarkSuffix(href)
      if darkHref ~= nil then
        local dest = dataDir .. "/" .. currentDomain .. "-dark." .. ext
        noctalia.download(darkHref, dest, function(ok)
          if ok then
            useIcon(dest, false)
          else
            useLightVariant()
          end
        end)
        return
      end
    end

    useLightVariant()
  end)
end

function onKey(chord, pressed)
  if not pressed then
    return
  end
  if chord == "1" then
    openProfile(PROFILES[1].id)
  elseif chord == "2" then
    openProfile(PROFILES[2].id)
  end
end
