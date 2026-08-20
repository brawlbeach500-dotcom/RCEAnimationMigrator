--!strict
-- RCE Animation Migrator
-- ------------------------------------------------------------------
-- Recursively publishes KeyframeSequences from:
--     ReplicatedFirst["Animations To Reupload"]
-- and rewires matching Animation.AnimationId values under:
--     ReplicatedStorage.RCE_Engine.Animations
--
-- Tabbed GUI (Setup / Migrate / Log), first-run onboarding wizard with a
-- live setup checker, Dark/Light/"Match Studio" theming, settings
-- persistence, a searchable & collapsible scan tree, and per-item
-- retry/error detail you can expand in the log.
--
-- Publishes with maximum parallelism, retry + backoff on failures, cancel
-- support, and a "resume unfinished" pass.
--
-- First-party dev tool: only touches instances inside YOUR OWN open place.
-- Requires the "CreateAssetAsync" Studio beta feature. See README.md.
-- ------------------------------------------------------------------

local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local AssetService = game:GetService("AssetService")

local SOURCE_PATH = { "Animations To Reupload" } -- relative to ReplicatedFirst
local DEST_PATH = { "RCE_Engine", "Animations" }  -- relative to ReplicatedStorage

local RETRY_BASE_DELAY = 1 -- seconds; exponential backoff between retries (1s, 2s, 4s, ... capped)
local RETRY_MAX_DELAY = 30 -- seconds; backoff never waits longer than this between attempts

-- No concurrency limit: every animation is published in parallel at once.
-- Uploads that fail simply retry with backoff until they succeed (see
-- publishUntilSuccess below), so there's no throughput to "tune" -- this is
-- just maximum parallelism.

----------------------------------------------------------------------
-- Game ownership
----------------------------------------------------------------------
-- If this place is owned by a Group, uploads MUST be published to that
-- Group -- publishing under your personal account is broken/rejected for
-- group-owned games. Detected once up front so the Setup tab and wizard
-- can warn about it and offer a one-click fix.

local function getGameOwnerInfo(): (string, number?)
	local ok, creatorType, creatorId = pcall(function()
		return game.CreatorType, game.CreatorId
	end)
	if not ok then
		return "Unknown", nil
	end
	if creatorType == Enum.CreatorType.Group then
		return "Group", creatorId
	end
	return "User", creatorId
end

local GAME_OWNER_TYPE, GAME_OWNER_ID = getGameOwnerInfo()

----------------------------------------------------------------------
-- Settings persistence
----------------------------------------------------------------------

local function getSetting(key: string, default: any): any
	local ok, value = pcall(function()
		return plugin:GetSetting(key)
	end)
	if ok and value ~= nil then
		return value
	end
	return default
end

local function setSetting(key: string, value: any)
	pcall(function()
		plugin:SetSetting(key, value)
	end)
end

----------------------------------------------------------------------
-- Theme system
----------------------------------------------------------------------

type Palette = { [string]: Color3 }

local THEMES: { [string]: Palette } = {
	Dark = {
		BG = Color3.fromRGB(44, 44, 44),
		PANEL = Color3.fromRGB(55, 55, 55),
		PANEL_ALT = Color3.fromRGB(50, 50, 50),
		BORDER = Color3.fromRGB(70, 70, 70),
		TEXT = Color3.fromRGB(232, 232, 232),
		SUBTEXT = Color3.fromRGB(160, 160, 160),
		ACCENT = Color3.fromRGB(0, 162, 255),
		ACCENT_DIM = Color3.fromRGB(0, 110, 175),
		SUCCESS = Color3.fromRGB(90, 200, 110),
		ERROR = Color3.fromRGB(235, 90, 90),
		ERROR_DIM = Color3.fromRGB(120, 60, 60),
		WARN = Color3.fromRGB(235, 180, 70),
		WARN_DIM = Color3.fromRGB(95, 75, 32),
		ON_ACCENT = Color3.new(1, 1, 1),
	},
	Light = {
		BG = Color3.fromRGB(244, 244, 247),
		PANEL = Color3.fromRGB(255, 255, 255),
		PANEL_ALT = Color3.fromRGB(233, 233, 237),
		BORDER = Color3.fromRGB(203, 203, 209),
		TEXT = Color3.fromRGB(26, 26, 29),
		SUBTEXT = Color3.fromRGB(97, 97, 103),
		ACCENT = Color3.fromRGB(0, 110, 200),
		ACCENT_DIM = Color3.fromRGB(70, 130, 180),
		SUCCESS = Color3.fromRGB(25, 140, 65),
		ERROR = Color3.fromRGB(195, 45, 45),
		ERROR_DIM = Color3.fromRGB(175, 90, 90),
		WARN = Color3.fromRGB(175, 115, 10),
		WARN_DIM = Color3.fromRGB(150, 115, 40),
		ON_ACCENT = Color3.new(1, 1, 1),
	},
}

local StudioSettings = settings():GetService("Studio")

local function studioColor(styleGuideColorName: string): Color3?
	local ok, col = pcall(function()
		return StudioSettings.Theme:GetColor(Enum.StudioStyleGuideColor[styleGuideColorName])
	end)
	if ok then
		return col :: Color3
	end
	return nil
end

local function buildStudioPalette(): Palette
	local bg = studioColor("MainBackground") or THEMES.Dark.BG
	local panel = studioColor("Tab") or studioColor("Titlebar") or THEMES.Dark.PANEL
	local panelAlt = studioColor("TableItem") or panel
	local border = studioColor("Border") or THEMES.Dark.BORDER
	local text = studioColor("MainText") or THEMES.Dark.TEXT
	local subtext = studioColor("SubText") or studioColor("DimmedText") or THEMES.Dark.SUBTEXT

	local brightness = bg.R * 0.299 + bg.G * 0.587 + bg.B * 0.114
	local accentSource = (brightness > 0.55) and THEMES.Light or THEMES.Dark

	return {
		BG = bg,
		PANEL = panel,
		PANEL_ALT = panelAlt,
		BORDER = border,
		TEXT = text,
		SUBTEXT = subtext,
		ACCENT = accentSource.ACCENT,
		ACCENT_DIM = accentSource.ACCENT_DIM,
		SUCCESS = accentSource.SUCCESS,
		ERROR = accentSource.ERROR,
		ERROR_DIM = accentSource.ERROR_DIM,
		WARN = accentSource.WARN,
		WARN_DIM = accentSource.WARN_DIM,
		ON_ACCENT = Color3.new(1, 1, 1),
	}
end

type ThemeEntry = { inst: Instance, prop: string, key: string }

local themedRegistry: { ThemeEntry } = {}
local themedIndex: { [Instance]: { [string]: ThemeEntry } } = {}

local themeMode: string = getSetting("RCEAnimationMigrator_ThemeMode", "Studio")
local currentPalette: Palette = if themeMode == "Light"
	then THEMES.Light
	elseif themeMode == "Studio" then buildStudioPalette()
	else THEMES.Dark

local function setThemedProp(inst: Instance, prop: string, key: string)
	local byProp = themedIndex[inst]
	if not byProp then
		byProp = {}
		themedIndex[inst] = byProp
	end
	local entry = byProp[prop]
	if entry then
		entry.key = key
	else
		entry = { inst = inst, prop = prop, key = key }
		byProp[prop] = entry
		table.insert(themedRegistry, entry)
	end
	(inst :: any)[prop] = currentPalette[key]
end

local function refreshTheme()
	for i = #themedRegistry, 1, -1 do
		local e = themedRegistry[i]
		if e.inst.Parent == nil then
			table.remove(themedRegistry, i)
			local byProp = themedIndex[e.inst]
			if byProp then
				byProp[e.prop] = nil
			end
		else
			(e.inst :: any)[e.prop] = currentPalette[e.key]
		end
	end
end

local function applyThemeMode(mode: string, persist: boolean?)
	themeMode = mode
	if mode == "Light" then
		currentPalette = THEMES.Light
	elseif mode == "Studio" then
		currentPalette = buildStudioPalette()
	else
		currentPalette = THEMES.Dark
	end
	refreshTheme()
	if persist ~= false then
		setSetting("RCEAnimationMigrator_ThemeMode", mode)
	end
end

StudioSettings.ThemeChanged:Connect(function()
	if themeMode == "Studio" then
		applyThemeMode("Studio", false)
	end
end)

----------------------------------------------------------------------
-- Toolbar / dock widget setup
----------------------------------------------------------------------

local toolbar = plugin:CreateToolbar("RCE Animation Migrator")
local toggleButton = toolbar:CreateButton(
	"Animation Migrator",
	"Open the RCE Animation Migrator panel",
	"rbxassetid://4458901886" -- placeholder icon, swap for your own asset
)
toggleButton.ClickableWhenViewportHidden = true

local widgetInfo = DockWidgetPluginGuiInfo.new(
	Enum.InitialDockState.Float,
	false,
	false,
	700, -- default width (bigger)
	860, -- default height (bigger)
	540, -- min width
	620 -- min height
)

local widget = plugin:CreateDockWidgetPluginGui("RCEAnimationMigratorWidget", widgetInfo)
widget.Title = "RCE Animation Migrator"

toggleButton.Click:Connect(function()
	widget.Enabled = not widget.Enabled
end)

widget:GetPropertyChangedSignal("Enabled"):Connect(function()
	toggleButton:SetActive(widget.Enabled)
end)

----------------------------------------------------------------------
-- UI construction helpers
----------------------------------------------------------------------

local function corner(parent: Instance, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = parent
	return c
end

local function stroke(parent: Instance, colorKey: string, thickness: number?)
	local s = Instance.new("UIStroke")
	s.Thickness = thickness or 1
	s.Parent = parent
	setThemedProp(s, "Color", colorKey)
	return s
end

local function makeLabel(parent: Instance, text: string, size: UDim2, opts: { [string]: any }?)
	opts = opts or {}
	local label = Instance.new("TextLabel")
	label.Text = text
	label.Size = size
	label.BackgroundTransparency = 1
	label.Font = (opts :: any).Bold and Enum.Font.GothamBold or Enum.Font.Gotham
	label.TextSize = (opts :: any).TextSize or 14
	label.TextXAlignment = (opts :: any).Align or Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.TextWrapped = (opts :: any).Wrapped or false
	label.Parent = parent
	setThemedProp(label, "TextColor3", (opts :: any).ColorKey or "TEXT")
	return label
end

local function makeButton(parent: Instance, text: string, size: UDim2, bgKey: string, neutralText: boolean?)
	local btn = Instance.new("TextButton")
	btn.Text = text
	btn.Size = size
	btn.Font = Enum.Font.GothamBold
	btn.TextSize = 13
	btn.AutoButtonColor = true
	btn.Parent = parent
	setThemedProp(btn, "BackgroundColor3", bgKey)
	setThemedProp(btn, "TextColor3", neutralText and "TEXT" or "ON_ACCENT")
	corner(btn, 6)
	return btn
end

local function makeTextBox(parent: Instance, placeholder: string, defaultText: string)
	local box = Instance.new("TextBox")
	box.Size = UDim2.new(1, 0, 0, 26)
	box.PlaceholderText = placeholder
	box.Text = defaultText
	box.ClearTextOnFocus = false
	box.Font = Enum.Font.Gotham
	box.TextSize = 13
	box.Parent = parent
	setThemedProp(box, "BackgroundColor3", "BG")
	setThemedProp(box, "TextColor3", "TEXT")
	setThemedProp(box, "PlaceholderColor3", "SUBTEXT")
	corner(box, 4)
	stroke(box, "BORDER")
	return box
end

-- Segmented control: a row of mutually-exclusive buttons. Used for upload
-- target, theme mode, and the log filter.
local function makeSegmented(
	parent: Instance,
	order: number,
	labelText: string,
	options: { string },
	initialIndex: number,
	onSelect: (number) -> ()
)
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, labelText ~= "" and 42 or 26)
	row.BackgroundTransparency = 1
	row.LayoutOrder = order
	row.Parent = parent

	local holderY = 0
	if labelText ~= "" then
		makeLabel(row, labelText, UDim2.new(1, 0, 0, 16), { TextSize = 12, ColorKey = "SUBTEXT" })
		holderY = 18
	end

	local holder = Instance.new("Frame")
	holder.Position = UDim2.new(0, 0, 0, holderY)
	holder.Size = UDim2.new(1, 0, 0, 26)
	holder.Parent = row
	setThemedProp(holder, "BackgroundColor3", "BG")
	corner(holder, 6)
	stroke(holder, "BORDER")

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.Parent = holder

	local buttons: { TextButton } = {}
	local selected = initialIndex

	local function refresh()
		for i, btn in ipairs(buttons) do
			if i == selected then
				setThemedProp(btn, "BackgroundColor3", "ACCENT")
				setThemedProp(btn, "TextColor3", "ON_ACCENT")
			else
				setThemedProp(btn, "BackgroundColor3", "BG")
				setThemedProp(btn, "TextColor3", "SUBTEXT")
			end
		end
	end

	for i, optText in ipairs(options) do
		local btn = makeButton(holder, optText, UDim2.new(1 / #options, 0, 1, 0), "BG", true)
		btn.AutoButtonColor = false
		btn.TextSize = 12
		btn.MouseButton1Click:Connect(function()
			selected = i
			refresh()
			onSelect(i)
		end)
		table.insert(buttons, btn)
	end
	refresh()

	return {
		row = row,
		setSelected = function(i: number)
			selected = i
			refresh()
		end,
	}
end

-- Checkbox row, used for the wizard's manual confirmation checklist.
local function makeCheckRow(parent: Instance, order: number, labelText: string, initialChecked: boolean, onToggle: (boolean) -> ())
	local row = Instance.new("TextButton")
	row.Text = ""
	row.AutoButtonColor = false
	row.Size = UDim2.new(1, 0, 0, 0)
	row.AutomaticSize = Enum.AutomaticSize.Y
	row.BackgroundTransparency = 1
	row.LayoutOrder = order
	row.Parent = parent

	local rowLayout = Instance.new("UIListLayout")
	rowLayout.FillDirection = Enum.FillDirection.Horizontal
	rowLayout.VerticalAlignment = Enum.VerticalAlignment.Top
	rowLayout.Padding = UDim.new(0, 8)
	rowLayout.Parent = row

	local box = Instance.new("Frame")
	box.Size = UDim2.new(0, 16, 0, 16)
	box.LayoutOrder = 1
	box.Parent = row
	setThemedProp(box, "BackgroundColor3", "BG")
	corner(box, 4)
	stroke(box, "BORDER")

	local check = makeLabel(box, "v", UDim2.fromScale(1, 1), {
		Bold = true,
		TextSize = 12,
		Align = Enum.TextXAlignment.Center,
		ColorKey = "ON_ACCENT",
	})
	check.Text = "\226\156\147" -- checkmark
	check.Visible = initialChecked

	local textCol = Instance.new("Frame")
	textCol.Size = UDim2.new(1, -24, 0, 0)
	textCol.AutomaticSize = Enum.AutomaticSize.Y
	textCol.BackgroundTransparency = 1
	textCol.LayoutOrder = 2
	textCol.Parent = row

	local label = makeLabel(textCol, labelText, UDim2.new(1, 0, 0, 16), { TextSize = 12, Wrapped = true })
	label.AutomaticSize = Enum.AutomaticSize.Y

	local checked = initialChecked
	local function refresh()
		setThemedProp(box, "BackgroundColor3", checked and "ACCENT" or "BG")
		check.Visible = checked
	end
	refresh()

	row.MouseButton1Click:Connect(function()
		checked = not checked
		refresh()
		onToggle(checked)
	end)

	return row
end

-- Auto-detected status row (icon + title + detail text), used both in the
-- Setup tab and the wizard's live setup check page. state is one of:
-- "ok" | "warn" | "fail" | "pending"
local function makeAutoCheckRow(parent: Instance, order: number, labelText: string)
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, 0)
	row.AutomaticSize = Enum.AutomaticSize.Y
	row.BackgroundTransparency = 1
	row.LayoutOrder = order
	row.Parent = parent

	local rowLayout = Instance.new("UIListLayout")
	rowLayout.FillDirection = Enum.FillDirection.Horizontal
	rowLayout.VerticalAlignment = Enum.VerticalAlignment.Top
	rowLayout.Padding = UDim.new(0, 8)
	rowLayout.Parent = row

	local icon = makeLabel(row, "\226\128\166", UDim2.new(0, 18, 0, 18), { Bold = true, TextSize = 14, ColorKey = "SUBTEXT" })
	icon.LayoutOrder = 1

	local textCol = Instance.new("Frame")
	textCol.Size = UDim2.new(1, -26, 0, 0)
	textCol.AutomaticSize = Enum.AutomaticSize.Y
	textCol.BackgroundTransparency = 1
	textCol.LayoutOrder = 2
	textCol.Parent = row
	local colLayout = Instance.new("UIListLayout")
	colLayout.SortOrder = Enum.SortOrder.LayoutOrder
	colLayout.Parent = textCol

	local titleLabel = makeLabel(textCol, labelText, UDim2.new(1, 0, 0, 16), { TextSize = 12, Wrapped = true })
	titleLabel.LayoutOrder = 1
	titleLabel.AutomaticSize = Enum.AutomaticSize.Y

	local detailLabel = makeLabel(textCol, "", UDim2.new(1, 0, 0, 14), { TextSize = 11, ColorKey = "SUBTEXT", Wrapped = true })
	detailLabel.LayoutOrder = 2
	detailLabel.AutomaticSize = Enum.AutomaticSize.Y

	local function setStatus(state: string, detail: string?)
		if state == "ok" then
			icon.Text = "\226\156\147"
			setThemedProp(icon, "TextColor3", "SUCCESS")
		elseif state == "warn" then
			icon.Text = "!"
			setThemedProp(icon, "TextColor3", "WARN")
		elseif state == "fail" then
			icon.Text = "\226\156\149"
			setThemedProp(icon, "TextColor3", "ERROR")
		else
			icon.Text = "\226\128\166"
			setThemedProp(icon, "TextColor3", "SUBTEXT")
		end
		detailLabel.Text = detail or ""
	end

	return { row = row, setStatus = setStatus }
end

-- Generic "make the last child in a vertical list fill remaining height"
-- helper, used for both the scan tree and the log.
local function resizeFillChild(container: GuiObject, containerLayout: UIListLayout, containerPadding: UIPadding, fillChild: GuiObject, minHeight: number)
	local total = container.AbsoluteSize.Y - containerPadding.PaddingTop.Offset - containerPadding.PaddingBottom.Offset
	local othersHeight = 0
	local visibleCount = 0
	for _, child in ipairs(container:GetChildren()) do
		if child:IsA("GuiObject") and child.Visible then
			visibleCount += 1
			if child ~= fillChild then
				othersHeight += child.AbsoluteSize.Y
			end
		end
	end
	local gaps = math.max(0, visibleCount - 1) * containerLayout.Padding.Offset
	local h = total - othersHeight - gaps
	fillChild.Size = UDim2.new(1, 0, 0, math.max(h, minHeight))
end

----------------------------------------------------------------------
-- Forward declarations (assigned later, referenced by earlier UI)
----------------------------------------------------------------------

local openWizard: () -> ()
local runSetupCheck: () -> ()
local refreshGroupOwnerBanner: () -> ()

----------------------------------------------------------------------
-- Root layout
----------------------------------------------------------------------

local root = Instance.new("Frame")
root.Size = UDim2.fromScale(1, 1)
root.BorderSizePixel = 0
root.Parent = widget
setThemedProp(root, "BackgroundColor3", "BG")

local rootPadding = Instance.new("UIPadding")
rootPadding.PaddingTop = UDim.new(0, 16)
rootPadding.PaddingBottom = UDim.new(0, 16)
rootPadding.PaddingLeft = UDim.new(0, 18)
rootPadding.PaddingRight = UDim.new(0, 18)
rootPadding.Parent = root

local rootLayout = Instance.new("UIListLayout")
rootLayout.FillDirection = Enum.FillDirection.Vertical
rootLayout.SortOrder = Enum.SortOrder.LayoutOrder
rootLayout.Padding = UDim.new(0, 10)
rootLayout.Parent = root

-- Header ----------------------------------------------------------------

local header = Instance.new("Frame")
header.Size = UDim2.new(1, 0, 0, 40)
header.BackgroundTransparency = 1
header.LayoutOrder = 1
header.Parent = root

makeLabel(header, "RCE Animation Migrator", UDim2.new(1, -70, 0, 24), { Bold = true, TextSize = 19 })
local pathsLabel = makeLabel(
	header,
	("ReplicatedFirst/%s -> ReplicatedStorage/%s"):format(table.concat(SOURCE_PATH, "/"), table.concat(DEST_PATH, "/")),
	UDim2.new(1, -70, 0, 16),
	{ TextSize = 11, ColorKey = "SUBTEXT" }
)
pathsLabel.Position = UDim2.new(0, 0, 0, 24)
pathsLabel.TextWrapped = true

local guideButton = makeButton(header, "Guide", UDim2.new(0, 64, 0, 26), "PANEL", true)
guideButton.Position = UDim2.new(1, -64, 0, 0)
guideButton.TextSize = 12
stroke(guideButton, "BORDER")

guideButton.MouseButton1Click:Connect(function()
	openWizard()
end)

-- Tab bar ----------------------------------------------------------------

local TAB_NAMES = { "Setup", "Migrate", "Log" }

local tabBar = Instance.new("Frame")
tabBar.Size = UDim2.new(1, 0, 0, 32)
tabBar.BackgroundTransparency = 1
tabBar.LayoutOrder = 2
tabBar.Parent = root

local tabBarLayout = Instance.new("UIListLayout")
tabBarLayout.FillDirection = Enum.FillDirection.Horizontal
tabBarLayout.Padding = UDim.new(0, 6)
tabBarLayout.Parent = tabBar

local tabButtons: { TextButton } = {}
local pages: { Frame } = {}

-- Content area (fills remaining vertical space; holds the 3 tab pages) ----

local contentArea = Instance.new("Frame")
contentArea.Size = UDim2.new(1, 0, 0, 200) -- resized below
contentArea.BackgroundTransparency = 1
contentArea.LayoutOrder = 3
contentArea.Parent = root

local function resizeContentArea()
	local available = root.AbsoluteSize.Y
		- rootPadding.PaddingTop.Offset
		- rootPadding.PaddingBottom.Offset
		- header.AbsoluteSize.Y
		- tabBar.AbsoluteSize.Y
		- (rootLayout.Padding.Offset * 2)
	contentArea.Size = UDim2.new(1, 0, 0, math.max(available, 200))
end

local function makePage(order: number): Frame
	local page = Instance.new("Frame")
	page.Size = UDim2.fromScale(1, 1)
	page.BackgroundTransparency = 1
	page.Visible = false
	page.Parent = contentArea
	table.insert(pages, page)
	return page
end

local setupPage = makePage(1)
local migratePage = makePage(2)
local logPage = makePage(3)

local activeTabIndex = 2

local function selectTab(index: number)
	activeTabIndex = index
	for i, pg in ipairs(pages) do
		pg.Visible = (i == index)
	end
	for i, btn in ipairs(tabButtons) do
		if i == index then
			setThemedProp(btn, "BackgroundColor3", "ACCENT")
			setThemedProp(btn, "TextColor3", "ON_ACCENT")
		else
			setThemedProp(btn, "BackgroundColor3", "PANEL")
			setThemedProp(btn, "TextColor3", "SUBTEXT")
		end
	end
	setSetting("RCEAnimationMigrator_LastTab", TAB_NAMES[index])
end

for i, name in ipairs(TAB_NAMES) do
	local btn = makeButton(tabBar, name, UDim2.new(1 / #TAB_NAMES, -4, 1, 0), "PANEL", true)
	btn.AutoButtonColor = false
	btn.MouseButton1Click:Connect(function()
		selectTab(i)
	end)
	table.insert(tabButtons, btn)
end

----------------------------------------------------------------------
-- Setup tab
----------------------------------------------------------------------

local setupPadding = Instance.new("UIPadding")
setupPadding.PaddingRight = UDim.new(0, 4)
setupPadding.Parent = setupPage

local setupScroll = Instance.new("ScrollingFrame")
setupScroll.Size = UDim2.fromScale(1, 1)
setupScroll.BackgroundTransparency = 1
setupScroll.BorderSizePixel = 0
setupScroll.ScrollBarThickness = 6
setupScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
setupScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
setupScroll.Parent = setupPage

local setupLayout = Instance.new("UIListLayout")
setupLayout.SortOrder = Enum.SortOrder.LayoutOrder
setupLayout.Padding = UDim.new(0, 12)
setupLayout.Parent = setupScroll

-- Upload target panel
local uploadPanel = Instance.new("Frame")
uploadPanel.Size = UDim2.new(1, 0, 0, 0)
uploadPanel.AutomaticSize = Enum.AutomaticSize.Y
uploadPanel.LayoutOrder = 1
uploadPanel.Parent = setupScroll
setThemedProp(uploadPanel, "BackgroundColor3", "PANEL")
corner(uploadPanel, 8)
stroke(uploadPanel, "BORDER")

local uploadPad = Instance.new("UIPadding")
uploadPad.PaddingTop = UDim.new(0, 12)
uploadPad.PaddingBottom = UDim.new(0, 12)
uploadPad.PaddingLeft = UDim.new(0, 14)
uploadPad.PaddingRight = UDim.new(0, 14)
uploadPad.Parent = uploadPanel

local uploadLayout = Instance.new("UIListLayout")
uploadLayout.SortOrder = Enum.SortOrder.LayoutOrder
uploadLayout.Padding = UDim.new(0, 10)
uploadLayout.Parent = uploadPanel

local persistedIsGroup = getSetting("RCEAnimationMigrator_UploadIsGroup", false) :: boolean
local uploadTargetIsGroup = persistedIsGroup

local groupRow = Instance.new("Frame")
groupRow.Size = UDim2.new(1, 0, 0, 42)
groupRow.BackgroundTransparency = 1
groupRow.LayoutOrder = 2
groupRow.Visible = uploadTargetIsGroup
groupRow.Parent = uploadPanel
makeLabel(groupRow, "Group ID:", UDim2.new(1, 0, 0, 16), { TextSize = 12, ColorKey = "SUBTEXT" })
local groupIdBox = makeTextBox(groupRow, "e.g. 1234567", getSetting("RCEAnimationMigrator_GroupId", "") :: string)
groupIdBox.Position = UDim2.new(0, 0, 0, 18)
groupIdBox.FocusLost:Connect(function()
	setSetting("RCEAnimationMigrator_GroupId", groupIdBox.Text)
end)

local uploadTargetSeg = makeSegmented(
	uploadPanel,
	1,
	"Upload to:",
	{ "My Account (User)", "Group" },
	uploadTargetIsGroup and 2 or 1,
	function(i)
		uploadTargetIsGroup = (i == 2)
		groupRow.Visible = uploadTargetIsGroup
		setSetting("RCEAnimationMigrator_UploadIsGroup", uploadTargetIsGroup)
		refreshGroupOwnerBanner()
		runSetupCheck()
	end
)

local function currentGroupIdNumber(): number?
	local text = groupIdBox.Text:gsub("%s+", "")
	if text == "" then
		return nil
	end
	return tonumber(text)
end

groupIdBox:GetPropertyChangedSignal("Text"):Connect(function()
	refreshGroupOwnerBanner()
	runSetupCheck()
end)

-- Group-ownership warning banner: if this place is owned by a Group, using
-- "My Account" instead of that Group is broken and every upload will fail.
local groupOwnerBanner = Instance.new("Frame")
groupOwnerBanner.Size = UDim2.new(1, 0, 0, 0)
groupOwnerBanner.AutomaticSize = Enum.AutomaticSize.Y
groupOwnerBanner.LayoutOrder = 3
groupOwnerBanner.Visible = false
groupOwnerBanner.Parent = uploadPanel
setThemedProp(groupOwnerBanner, "BackgroundColor3", "WARN_DIM")
corner(groupOwnerBanner, 6)
stroke(groupOwnerBanner, "WARN")

local groupOwnerBannerPad = Instance.new("UIPadding")
groupOwnerBannerPad.PaddingTop = UDim.new(0, 10)
groupOwnerBannerPad.PaddingBottom = UDim.new(0, 10)
groupOwnerBannerPad.PaddingLeft = UDim.new(0, 12)
groupOwnerBannerPad.PaddingRight = UDim.new(0, 12)
groupOwnerBannerPad.Parent = groupOwnerBanner

local groupOwnerBannerLayout = Instance.new("UIListLayout")
groupOwnerBannerLayout.SortOrder = Enum.SortOrder.LayoutOrder
groupOwnerBannerLayout.Padding = UDim.new(0, 8)
groupOwnerBannerLayout.Parent = groupOwnerBanner

local groupOwnerBannerText = makeLabel(groupOwnerBanner, "", UDim2.new(1, 0, 0, 0), {
	TextSize = 12,
	Wrapped = true,
})
groupOwnerBannerText.AutomaticSize = Enum.AutomaticSize.Y
groupOwnerBannerText.LayoutOrder = 1

local useGroupButton = makeButton(groupOwnerBanner, "Use this Group", UDim2.new(0, 150, 0, 26), "WARN", true)
useGroupButton.LayoutOrder = 2

refreshGroupOwnerBanner = function()
	if GAME_OWNER_TYPE == "Group" and GAME_OWNER_ID then
		local matches = uploadTargetIsGroup and currentGroupIdNumber() == GAME_OWNER_ID
		groupOwnerBanner.Visible = not matches
		groupOwnerBannerText.Text = (
			"This place is owned by Group %d. Publishing under your personal account is broken for a "
			.. "group-owned game -- you must publish to this Group instead."
		):format(GAME_OWNER_ID)
	else
		groupOwnerBanner.Visible = false
	end
end

useGroupButton.MouseButton1Click:Connect(function()
	if not GAME_OWNER_ID then
		return
	end
	uploadTargetIsGroup = true
	uploadTargetSeg.setSelected(2)
	groupRow.Visible = true
	groupIdBox.Text = tostring(GAME_OWNER_ID)
	setSetting("RCEAnimationMigrator_UploadIsGroup", true)
	setSetting("RCEAnimationMigrator_GroupId", groupIdBox.Text)
	refreshGroupOwnerBanner()
	runSetupCheck()
end)

refreshGroupOwnerBanner()

local speedInfoRow = Instance.new("Frame")
speedInfoRow.Size = UDim2.new(1, 0, 0, 16)
speedInfoRow.BackgroundTransparency = 1
speedInfoRow.LayoutOrder = 4
speedInfoRow.Parent = uploadPanel
makeLabel(
	speedInfoRow,
	"Upload speed: maximum -- every animation publishes in parallel at once.",
	UDim2.new(1, 0, 1, 0),
	{ TextSize = 12, ColorKey = "SUBTEXT" }
)

-- Appearance panel
local appearancePanel = Instance.new("Frame")
appearancePanel.Size = UDim2.new(1, 0, 0, 0)
appearancePanel.AutomaticSize = Enum.AutomaticSize.Y
appearancePanel.LayoutOrder = 2
appearancePanel.Parent = setupScroll
setThemedProp(appearancePanel, "BackgroundColor3", "PANEL")
corner(appearancePanel, 8)
stroke(appearancePanel, "BORDER")

local appearancePad = Instance.new("UIPadding")
appearancePad.PaddingTop = UDim.new(0, 12)
appearancePad.PaddingBottom = UDim.new(0, 12)
appearancePad.PaddingLeft = UDim.new(0, 14)
appearancePad.PaddingRight = UDim.new(0, 14)
appearancePad.Parent = appearancePanel

local appearanceLayout = Instance.new("UIListLayout")
appearanceLayout.SortOrder = Enum.SortOrder.LayoutOrder
appearanceLayout.Padding = UDim.new(0, 10)
appearanceLayout.Parent = appearancePanel

local THEME_OPTIONS = { "Dark", "Light", "Match Studio" }
local THEME_OPTION_MODES = { "Dark", "Light", "Studio" }
local initialThemeIndex = 3
for i, m in ipairs(THEME_OPTION_MODES) do
	if m == themeMode then
		initialThemeIndex = i
	end
end

makeSegmented(appearancePanel, 1, "Theme:", THEME_OPTIONS, initialThemeIndex, function(i)
	applyThemeMode(THEME_OPTION_MODES[i], true)
end)

-- Setup checklist panel
local checklistPanel = Instance.new("Frame")
checklistPanel.Size = UDim2.new(1, 0, 0, 0)
checklistPanel.AutomaticSize = Enum.AutomaticSize.Y
checklistPanel.LayoutOrder = 3
checklistPanel.Parent = setupScroll
setThemedProp(checklistPanel, "BackgroundColor3", "PANEL")
corner(checklistPanel, 8)
stroke(checklistPanel, "BORDER")

local checklistPad = Instance.new("UIPadding")
checklistPad.PaddingTop = UDim.new(0, 12)
checklistPad.PaddingBottom = UDim.new(0, 12)
checklistPad.PaddingLeft = UDim.new(0, 14)
checklistPad.PaddingRight = UDim.new(0, 14)
checklistPad.Parent = checklistPanel

local checklistLayout = Instance.new("UIListLayout")
checklistLayout.SortOrder = Enum.SortOrder.LayoutOrder
checklistLayout.Padding = UDim.new(0, 8)
checklistLayout.Parent = checklistPanel

local checklistHeaderRow = Instance.new("Frame")
checklistHeaderRow.Size = UDim2.new(1, 0, 0, 18)
checklistHeaderRow.BackgroundTransparency = 1
checklistHeaderRow.LayoutOrder = 1
checklistHeaderRow.Parent = checklistPanel
makeLabel(checklistHeaderRow, "Setup check", UDim2.new(1, -80, 1, 0), { Bold = true, TextSize = 14 })
local recheckButton = makeButton(checklistHeaderRow, "Re-check", UDim2.new(0, 80, 1, 0), "PANEL_ALT", true)
recheckButton.Position = UDim2.new(1, -80, 0, 0)
recheckButton.TextSize = 11
stroke(recheckButton, "BORDER")

-- Registered so the wizard's live-check page can share the exact same
-- detection logic and stay in sync with the Setup tab.
local autoCheckHandleSets: { { source: any, dest: any, engine: any, ownership: any } } = {}

local function buildAutoChecklistInto(parent: Instance, orderOffset: number)
	local sourceCheck = makeAutoCheckRow(parent, orderOffset + 1, ("Source folder: ReplicatedFirst/%s"):format(table.concat(SOURCE_PATH, "/")))
	local destCheck = makeAutoCheckRow(parent, orderOffset + 2, ("Destination folder: ReplicatedStorage/%s"):format(table.concat(DEST_PATH, "/")))
	local engineCheck = makeAutoCheckRow(parent, orderOffset + 3, "AssetService:CreateAssetAsync engine API")
	local ownershipCheck = makeAutoCheckRow(parent, orderOffset + 4, "Place ownership vs. upload target")
	local handles = { source = sourceCheck, dest = destCheck, engine = engineCheck, ownership = ownershipCheck }
	table.insert(autoCheckHandleSets, handles)
	return handles
end

local function resolvePath(rootInst: Instance, pathParts: { string }): Instance?
	local current = rootInst
	for _, part in ipairs(pathParts) do
		local child = current:FindFirstChild(part)
		if not child then
			return nil
		end
		current = child
	end
	return current
end

runSetupCheck = function()
	local sourceRoot = resolvePath(ReplicatedFirst, SOURCE_PATH)
	local destRoot = resolvePath(ReplicatedStorage, DEST_PATH)
	local hasCreateAsset = typeof((AssetService :: any).CreateAssetAsync) == "function"

	for _, handles in ipairs(autoCheckHandleSets) do
		if sourceRoot then
			handles.source.setStatus("ok", ("Found: ReplicatedFirst/%s"):format(table.concat(SOURCE_PATH, "/")))
		else
			handles.source.setStatus(
				"fail",
				("Missing: ReplicatedFirst/%s -- create it and add KeyframeSequences before scanning."):format(table.concat(SOURCE_PATH, "/"))
			)
		end

		if destRoot then
			handles.dest.setStatus("ok", ("Found: ReplicatedStorage/%s"):format(table.concat(DEST_PATH, "/")))
		else
			handles.dest.setStatus(
				"warn",
				("Not found yet: ReplicatedStorage/%s -- will be created automatically during migration."):format(table.concat(DEST_PATH, "/"))
			)
		end

		if hasCreateAsset then
			handles.engine.setStatus("ok", "AssetService:CreateAssetAsync is available on this client.")
		else
			handles.engine.setStatus("fail", "CreateAssetAsync API not found -- update Roblox Studio.")
		end

		if GAME_OWNER_TYPE == "Group" and GAME_OWNER_ID then
			if uploadTargetIsGroup and currentGroupIdNumber() == GAME_OWNER_ID then
				handles.ownership.setStatus(
					"ok",
					("This place is owned by Group %d and you're set to publish there. Good."):format(GAME_OWNER_ID)
				)
			else
				handles.ownership.setStatus(
					"fail",
					("This place is owned by Group %d -- publishing under your personal account is broken here. "
						.. "Set \"Upload to\" to Group and Group ID to %d (or use the button above)."):format(
						GAME_OWNER_ID,
						GAME_OWNER_ID
					)
				)
			end
		elseif GAME_OWNER_TYPE == "User" then
			handles.ownership.setStatus("ok", "This place is owned by your personal account -- User upload is correct.")
		else
			handles.ownership.setStatus("warn", "Could not determine this place's ownership.")
		end
	end

	refreshGroupOwnerBanner()
end

buildAutoChecklistInto(checklistPanel, 1)

recheckButton.MouseButton1Click:Connect(runSetupCheck)

local checklistManualHeader = Instance.new("Frame")
checklistManualHeader.Size = UDim2.new(1, 0, 0, 1)
checklistManualHeader.LayoutOrder = 6
checklistManualHeader.Parent = checklistPanel
setThemedProp(checklistManualHeader, "BackgroundColor3", "BORDER")

local checkBetaConfirmed = getSetting("RCEAnimationMigrator_CheckBeta", false) :: boolean
local checkHttpConfirmed = getSetting("RCEAnimationMigrator_CheckHttp", false) :: boolean

makeCheckRow(
	checklistPanel,
	7,
	"I enabled the \"CreateAssetAsync\" beta feature (File -> Beta Features) and restarted Studio.",
	checkBetaConfirmed,
	function(checked)
		checkBetaConfirmed = checked
		setSetting("RCEAnimationMigrator_CheckBeta", checked)
	end
)

makeCheckRow(
	checklistPanel,
	8,
	"(Optional) I allowed HTTP Requests in Game Settings -> Security.",
	checkHttpConfirmed,
	function(checked)
		checkHttpConfirmed = checked
		setSetting("RCEAnimationMigrator_CheckHttp", checked)
	end
)

----------------------------------------------------------------------
-- Migrate tab
----------------------------------------------------------------------

local migratePadding = Instance.new("UIPadding")
migratePadding.Parent = migratePage

local migrateLayout = Instance.new("UIListLayout")
migrateLayout.SortOrder = Enum.SortOrder.LayoutOrder
migrateLayout.Padding = UDim.new(0, 10)
migrateLayout.Parent = migratePage

-- Action buttons row
local actionsRow = Instance.new("Frame")
actionsRow.Size = UDim2.new(1, 0, 0, 36)
actionsRow.BackgroundTransparency = 1
actionsRow.LayoutOrder = 1
actionsRow.Parent = migratePage

local actionsLayout = Instance.new("UIListLayout")
actionsLayout.FillDirection = Enum.FillDirection.Horizontal
actionsLayout.Padding = UDim.new(0, 8)
actionsLayout.Parent = actionsRow

local scanButton = makeButton(actionsRow, "Scan", UDim2.new(0, 90, 1, 0), "PANEL", true)
stroke(scanButton, "BORDER")
local migrateButton = makeButton(actionsRow, "Migrate", UDim2.new(0, 140, 1, 0), "ACCENT_DIM")
migrateButton.AutoButtonColor = false
migrateButton.Active = false
local cancelButton = makeButton(actionsRow, "Cancel", UDim2.new(0, 90, 1, 0), "ERROR_DIM")
cancelButton.AutoButtonColor = false
cancelButton.Active = false
cancelButton.Visible = false
local retryFailedButton = makeButton(actionsRow, "Resume Unfinished", UDim2.new(1, -338, 1, 0), "WARN", true)
retryFailedButton.AutoButtonColor = false
retryFailedButton.Active = false
retryFailedButton.Visible = false

-- Search row
local searchRow = Instance.new("Frame")
searchRow.Size = UDim2.new(1, 0, 0, 26)
searchRow.BackgroundTransparency = 1
searchRow.LayoutOrder = 2
searchRow.Parent = migratePage

local searchLayout = Instance.new("UIListLayout")
searchLayout.FillDirection = Enum.FillDirection.Horizontal
searchLayout.Padding = UDim.new(0, 8)
searchLayout.Parent = searchRow

local searchBox = Instance.new("TextBox")
searchBox.Size = UDim2.new(1, -140, 1, 0)
searchBox.PlaceholderText = "Search animations by path..."
searchBox.ClearTextOnFocus = false
searchBox.Font = Enum.Font.Gotham
searchBox.TextSize = 13
searchBox.TextXAlignment = Enum.TextXAlignment.Left
searchBox.Parent = searchRow
setThemedProp(searchBox, "BackgroundColor3", "BG")
setThemedProp(searchBox, "TextColor3", "TEXT")
setThemedProp(searchBox, "PlaceholderColor3", "SUBTEXT")
corner(searchBox, 4)
stroke(searchBox, "BORDER")
local searchBoxPad = Instance.new("UIPadding")
searchBoxPad.PaddingLeft = UDim.new(0, 8)
searchBoxPad.PaddingRight = UDim.new(0, 8)
searchBoxPad.Parent = searchBox

local searchCountLabel = makeLabel(searchRow, "", UDim2.new(0, 132, 1, 0), {
	TextSize = 11,
	ColorKey = "SUBTEXT",
	Align = Enum.TextXAlignment.Right,
})

-- Scan tree
local treeScroll = Instance.new("ScrollingFrame")
treeScroll.Size = UDim2.new(1, 0, 0, 200)
treeScroll.BorderSizePixel = 0
treeScroll.ScrollBarThickness = 6
treeScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
treeScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
treeScroll.LayoutOrder = 3
treeScroll.Parent = migratePage
setThemedProp(treeScroll, "BackgroundColor3", "PANEL")
corner(treeScroll, 8)
stroke(treeScroll, "BORDER")

local treePad = Instance.new("UIPadding")
treePad.PaddingTop = UDim.new(0, 8)
treePad.PaddingBottom = UDim.new(0, 8)
treePad.PaddingLeft = UDim.new(0, 10)
treePad.PaddingRight = UDim.new(0, 10)
treePad.Parent = treeScroll

local treeLayout = Instance.new("UIListLayout")
treeLayout.SortOrder = Enum.SortOrder.LayoutOrder
treeLayout.Parent = treeScroll

-- Stats bar
local statsBar = Instance.new("Frame")
statsBar.Size = UDim2.new(1, 0, 0, 0)
statsBar.AutomaticSize = Enum.AutomaticSize.Y
statsBar.LayoutOrder = 4
statsBar.Parent = migratePage
setThemedProp(statsBar, "BackgroundColor3", "PANEL_ALT")
corner(statsBar, 6)

local statsPad = Instance.new("UIPadding")
statsPad.PaddingTop = UDim.new(0, 8)
statsPad.PaddingBottom = UDim.new(0, 8)
statsPad.PaddingLeft = UDim.new(0, 12)
statsPad.PaddingRight = UDim.new(0, 12)
statsPad.Parent = statsBar

local statsLabel = makeLabel(
	statsBar,
	"Success: 0    Retrying now: 0    Remaining: 0    Total retries: 0\nElapsed: 0:00    ETA: --:--",
	UDim2.new(1, 0, 0, 16),
	{ TextSize = 12, ColorKey = "SUBTEXT", Wrapped = true }
)

-- Status + progress
local statusLabel = makeLabel(migratePage, "Click Scan to find animations to migrate.", UDim2.new(1, 0, 0, 18), {
	TextSize = 13,
})
statusLabel.LayoutOrder = 5

local progressTrack = Instance.new("Frame")
progressTrack.Size = UDim2.new(1, 0, 0, 10)
progressTrack.LayoutOrder = 6
progressTrack.Parent = migratePage
setThemedProp(progressTrack, "BackgroundColor3", "PANEL")
corner(progressTrack, 5)

local progressFill = Instance.new("Frame")
progressFill.Size = UDim2.new(0, 0, 1, 0)
progressFill.BorderSizePixel = 0
progressFill.Parent = progressTrack
setThemedProp(progressFill, "BackgroundColor3", "ACCENT")
corner(progressFill, 5)

local function setProgress(fraction: number)
	fraction = math.clamp(fraction, 0, 1)
	progressFill.Size = UDim2.new(fraction, 0, 1, 0)
end

local function resizeMigrateTree()
	resizeFillChild(migratePage, migrateLayout, migratePadding, treeScroll, 140)
end

----------------------------------------------------------------------
-- Scan tree data + rendering
----------------------------------------------------------------------

type ScanEntry = { path: { string }, kf: KeyframeSequence }

type TreeNode = {
	name: string,
	fullPath: string,
	children: { [string]: TreeNode },
	childOrder: { string },
	entry: ScanEntry?,
}

local function buildTree(entries: { ScanEntry }): TreeNode
	local root: TreeNode = { name = "", fullPath = "", children = {}, childOrder = {}, entry = nil }
	for _, entry in ipairs(entries) do
		local node = root
		for i, part in ipairs(entry.path) do
			local isLeaf = (i == #entry.path)
			local existing = node.children[part]
			if not existing then
				existing = {
					name = part,
					fullPath = (node.fullPath == "" and part or (node.fullPath .. "/" .. part)),
					children = {},
					childOrder = {},
					entry = nil,
				}
				node.children[part] = existing
				table.insert(node.childOrder, part)
			end
			if isLeaf then
				existing.entry = entry
			end
			node = existing
		end
	end
	return root
end

local lastScanResults: { ScanEntry }? = nil
local lastFailedEntries: { ScanEntry }? = nil
local searchQuery = ""
local folderCollapsed: { [string]: boolean } = {}
local treeItemRefs: { [string]: { statusIcon: TextLabel } } = {}

local function nodeMatchesSearch(node: TreeNode): boolean
	if searchQuery == "" then
		return true
	end
	if node.entry then
		return string.find(string.lower(node.fullPath), searchQuery, 1, true) ~= nil
	end
	for _, childName in ipairs(node.childOrder) do
		if nodeMatchesSearch(node.children[childName]) then
			return true
		end
	end
	return false
end

local function renderChildren(node: TreeNode, depth: number, container: Instance)
	local order = 0
	for _, childName in ipairs(node.childOrder) do
		local child = node.children[childName]
		if nodeMatchesSearch(child) then
			order += 1
			if child.entry then
				local row = Instance.new("Frame")
				row.Size = UDim2.new(1, 0, 0, 20)
				row.BackgroundTransparency = 1
				row.LayoutOrder = order
				row.Parent = container

				local pad = Instance.new("UIPadding")
				pad.PaddingLeft = UDim.new(0, depth * 16)
				pad.Parent = row

				local rowLayout = Instance.new("UIListLayout")
				rowLayout.FillDirection = Enum.FillDirection.Horizontal
				rowLayout.VerticalAlignment = Enum.VerticalAlignment.Center
				rowLayout.Padding = UDim.new(0, 6)
				rowLayout.Parent = row

				local statusIcon = makeLabel(row, "\226\128\162", UDim2.new(0, 14, 1, 0), { TextSize = 12, ColorKey = "SUBTEXT" })
				statusIcon.LayoutOrder = 1
				local nameLabel = makeLabel(row, child.name, UDim2.new(1, -20, 1, 0), { TextSize = 12 })
				nameLabel.LayoutOrder = 2

				treeItemRefs[child.fullPath] = { statusIcon = statusIcon }
			else
				local collapsed = searchQuery ~= "" and false or (folderCollapsed[child.fullPath] == true)

				local headerRow = Instance.new("TextButton")
				headerRow.Text = ""
				headerRow.AutoButtonColor = false
				headerRow.Size = UDim2.new(1, 0, 0, 20)
				headerRow.BackgroundTransparency = 1
				headerRow.LayoutOrder = order
				headerRow.Parent = container

				local pad = Instance.new("UIPadding")
				pad.PaddingLeft = UDim.new(0, depth * 16)
				pad.Parent = headerRow

				local rowLayout = Instance.new("UIListLayout")
				rowLayout.FillDirection = Enum.FillDirection.Horizontal
				rowLayout.VerticalAlignment = Enum.VerticalAlignment.Center
				rowLayout.Padding = UDim.new(0, 6)
				rowLayout.Parent = headerRow

				local chevron = makeLabel(headerRow, collapsed and ">" or "v", UDim2.new(0, 14, 1, 0), { Bold = true, TextSize = 11, ColorKey = "SUBTEXT" })
				chevron.LayoutOrder = 1
				makeLabel(headerRow, ("%s/"):format(child.name), UDim2.new(1, -20, 1, 0), { Bold = true, TextSize = 12, ColorKey = "SUBTEXT" }).LayoutOrder = 2

				order += 1
				local childHolder = Instance.new("Frame")
				childHolder.Size = UDim2.new(1, 0, 0, 0)
				childHolder.AutomaticSize = Enum.AutomaticSize.Y
				childHolder.BackgroundTransparency = 1
				childHolder.Visible = not collapsed
				childHolder.LayoutOrder = order
				childHolder.Parent = container

				local innerLayout = Instance.new("UIListLayout")
				innerLayout.SortOrder = Enum.SortOrder.LayoutOrder
				innerLayout.Parent = childHolder

				headerRow.MouseButton1Click:Connect(function()
					local newCollapsed = not (folderCollapsed[child.fullPath] == true)
					folderCollapsed[child.fullPath] = newCollapsed
					childHolder.Visible = not newCollapsed
					chevron.Text = newCollapsed and ">" or "v"
				end)

				renderChildren(child, depth + 1, childHolder)
			end
		end
	end
end

local function countSearchMatches(): (number, number)
	if not lastScanResults then
		return 0, 0
	end
	local total = #lastScanResults
	if searchQuery == "" then
		return total, total
	end
	local shown = 0
	for _, e in ipairs(lastScanResults) do
		if string.find(string.lower(table.concat(e.path, "/")), searchQuery, 1, true) then
			shown += 1
		end
	end
	return shown, total
end

local function rebuildTree()
	for _, c in ipairs(treeScroll:GetChildren()) do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	treeItemRefs = {}

	if not lastScanResults or #lastScanResults == 0 then
		makeLabel(treeScroll, "No results yet. Click Scan.", UDim2.new(1, 0, 0, 20), { TextSize = 12, ColorKey = "SUBTEXT" })
		searchCountLabel.Text = ""
		return
	end

	local treeRoot = buildTree(lastScanResults)
	renderChildren(treeRoot, 0, treeScroll)

	local shown, total = countSearchMatches()
	searchCountLabel.Text = (searchQuery == "") and ("%d total"):format(total) or ("%d / %d shown"):format(shown, total)
end

local searchDebounceGen = 0
searchBox:GetPropertyChangedSignal("Text"):Connect(function()
	searchDebounceGen += 1
	local myGen = searchDebounceGen
	task.delay(0.15, function()
		if myGen == searchDebounceGen then
			searchQuery = string.lower(searchBox.Text)
			rebuildTree()
		end
	end)
end)

local function setItemStatus(displayPath: string, state: string)
	local ref = treeItemRefs[displayPath]
	if not ref then
		return
	end
	local icon = ref.statusIcon
	if state == "retrying" then
		icon.Text = "\226\128\166"
		setThemedProp(icon, "TextColor3", "WARN")
	elseif state == "success" then
		icon.Text = "\226\156\147"
		setThemedProp(icon, "TextColor3", "SUCCESS")
	elseif state == "error" then
		icon.Text = "\226\156\149"
		setThemedProp(icon, "TextColor3", "ERROR")
	else
		icon.Text = "\226\128\162"
		setThemedProp(icon, "TextColor3", "SUBTEXT")
	end
end

----------------------------------------------------------------------
-- Log tab
----------------------------------------------------------------------

local logPadding = Instance.new("UIPadding")
logPadding.Parent = logPage

local logPageLayout = Instance.new("UIListLayout")
logPageLayout.SortOrder = Enum.SortOrder.LayoutOrder
logPageLayout.Padding = UDim.new(0, 8)
logPageLayout.Parent = logPage

local logFilterRow = Instance.new("Frame")
logFilterRow.Size = UDim2.new(1, 0, 0, 26)
logFilterRow.BackgroundTransparency = 1
logFilterRow.LayoutOrder = 1
logFilterRow.Parent = logPage

local logFilterLayout = Instance.new("UIListLayout")
logFilterLayout.FillDirection = Enum.FillDirection.Horizontal
logFilterLayout.Padding = UDim.new(0, 8)
logFilterLayout.Parent = logFilterRow

local logFilterLabel = makeLabel(logFilterRow, "Log:", UDim2.new(0, 34, 1, 0), { TextSize = 12, ColorKey = "SUBTEXT" })
logFilterLabel.LayoutOrder = 1

local showErrorsOnly = false
local logFilterSeg = makeSegmented(logFilterRow, 2, "", { "All", "Errors only" }, 1, function(i)
	showErrorsOnly = (i == 2)
	-- applyLogFilter is defined below; wired after both exist.
end)
logFilterSeg.row.Size = UDim2.new(0, 200, 1, 0)

local clearLogButton = makeButton(logFilterRow, "Clear", UDim2.new(0, 70, 1, 0), "PANEL", true)
clearLogButton.LayoutOrder = 3
stroke(clearLogButton, "BORDER")
clearLogButton.TextSize = 12

local logFrame = Instance.new("ScrollingFrame")
logFrame.LayoutOrder = 2
logFrame.BorderSizePixel = 0
logFrame.ScrollBarThickness = 6
logFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
logFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
logFrame.Parent = logPage
setThemedProp(logFrame, "BackgroundColor3", "PANEL")
corner(logFrame, 8)
stroke(logFrame, "BORDER")

local logPad = Instance.new("UIPadding")
logPad.PaddingTop = UDim.new(0, 8)
logPad.PaddingBottom = UDim.new(0, 8)
logPad.PaddingLeft = UDim.new(0, 10)
logPad.PaddingRight = UDim.new(0, 10)
logPad.Parent = logFrame

local logLayout = Instance.new("UIListLayout")
logLayout.SortOrder = Enum.SortOrder.LayoutOrder
logLayout.Padding = UDim.new(0, 2)
logLayout.Parent = logFrame

local function resizeLog()
	resizeFillChild(logPage, logPageLayout, logPadding, logFrame, 140)
end

local logOrderCounter = 0

local function applyLogFilter()
	for _, child in ipairs(logFrame:GetChildren()) do
		if child:IsA("Frame") then
			local isError = child:GetAttribute("IsError") == true
			child.Visible = (not showErrorsOnly) or isError
		end
	end
end

-- Now that applyLogFilter exists, wire the segmented control to it too.
do
	local originalRow = logFilterSeg.row
	for _, child in ipairs(originalRow:GetDescendants()) do
		if child:IsA("TextButton") then
			child.MouseButton1Click:Connect(applyLogFilter)
		end
	end
end

-- Appends a log line. If detailLines is non-empty, the line becomes
-- clickable and expands to show per-attempt error history.
local function appendLogLine(text: string, colorKey: string, isError: boolean?, detailLines: { string }?)
	logOrderCounter += 1
	local container = Instance.new("Frame")
	container.Size = UDim2.new(1, 0, 0, 0)
	container.AutomaticSize = Enum.AutomaticSize.Y
	container.BackgroundTransparency = 1
	container.LayoutOrder = logOrderCounter
	container:SetAttribute("IsError", isError == true)
	container.Visible = (not showErrorsOnly) or (isError == true)
	container.Parent = logFrame

	local hasDetail = detailLines ~= nil and #detailLines > 0

	local containerLayout = Instance.new("UIListLayout")
	containerLayout.SortOrder = Enum.SortOrder.LayoutOrder
	containerLayout.Parent = container

	local lineBtn = Instance.new("TextButton")
	lineBtn.Text = (hasDetail and "\226\150\184 " or "") .. text
	lineBtn.AutoButtonColor = false
	lineBtn.Size = UDim2.new(1, 0, 0, 16)
	lineBtn.AutomaticSize = Enum.AutomaticSize.Y
	lineBtn.BackgroundTransparency = 1
	lineBtn.Font = Enum.Font.Code
	lineBtn.TextSize = 12
	lineBtn.TextXAlignment = Enum.TextXAlignment.Left
	lineBtn.TextWrapped = true
	lineBtn.LayoutOrder = 1
	lineBtn.Parent = container
	setThemedProp(lineBtn, "TextColor3", colorKey)

	if hasDetail then
		local lines = detailLines :: { string }
		local detailLabel = Instance.new("TextLabel")
		detailLabel.Text = table.concat(lines, "\n")
		detailLabel.Size = UDim2.new(1, -16, 0, 0)
		detailLabel.Position = UDim2.new(0, 16, 0, 0)
		detailLabel.AutomaticSize = Enum.AutomaticSize.Y
		detailLabel.BackgroundTransparency = 1
		detailLabel.Font = Enum.Font.Code
		detailLabel.TextSize = 11
		detailLabel.TextXAlignment = Enum.TextXAlignment.Left
		detailLabel.TextWrapped = true
		detailLabel.Visible = false
		detailLabel.LayoutOrder = 2
		detailLabel.Parent = container
		setThemedProp(detailLabel, "TextColor3", "SUBTEXT")

		lineBtn.MouseButton1Click:Connect(function()
			detailLabel.Visible = not detailLabel.Visible
			lineBtn.Text = (detailLabel.Visible and "\226\150\190 " or "\226\150\184 ") .. text
		end)
	end

	task.defer(function()
		logFrame.CanvasPosition = Vector2.new(0, math.max(0, logFrame.AbsoluteCanvasSize.Y))
	end)

	print(("[RCE Migrator] %s"):format(text))
	return container
end

local function clearLog()
	for _, child in ipairs(logFrame:GetChildren()) do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
	logOrderCounter = 0
end

clearLogButton.MouseButton1Click:Connect(clearLog)

----------------------------------------------------------------------
-- Tree helpers (folder ensure / recursive scan)
----------------------------------------------------------------------

local function ensureFolderPath(rootInst: Instance, pathParts: { string }): Instance
	-- No yields occur in this function, so it is safe under concurrent
	-- worker coroutines (Luau's cooperative scheduling means this body
	-- runs atomically between yield points).
	local current = rootInst
	for _, part in ipairs(pathParts) do
		local child = current:FindFirstChild(part)
		if not child then
			local folder = Instance.new("Folder")
			folder.Name = part
			folder.Parent = current
			child = folder
		end
		current = child
	end
	return current
end

local function findAllKeyframeSequences(container: Instance, currentPath: { string }, results: { ScanEntry })
	for _, child in ipairs(container:GetChildren()) do
		local newPath = table.clone(currentPath)
		table.insert(newPath, child.Name)

		if child:IsA("KeyframeSequence") then
			table.insert(results, { path = newPath, kf = child :: KeyframeSequence })
		else
			findAllKeyframeSequences(child, newPath, results)
		end
	end
end

----------------------------------------------------------------------
-- Publish + rewire
----------------------------------------------------------------------

local function publishKeyframeSequence(kf: KeyframeSequence, animationName: string, groupId: number?): (number?, string?)
	local params: { [string]: any } = {
		Name = animationName,
		Description = "Migrated via RCE Animation Migrator",
	}
	if groupId then
		params.CreatorType = Enum.AssetCreatorType.Group
		params.CreatorId = groupId
	end

	local pcallOk, statusOrErr, assetId = pcall(function()
		return AssetService:CreateAssetAsync(kf, Enum.AssetType.Animation, params)
	end)

	if not pcallOk then
		return nil, tostring(statusOrErr)
	end

	if statusOrErr == Enum.CreateAssetResult.Success then
		return assetId, nil
	end

	return nil, ("%s%s"):format(tostring(statusOrErr), assetId and (" -- " .. tostring(assetId)) or "")
end

local function findOrCreateAnimationInstance(container: Instance, name: string): Animation
	local existing = container:FindFirstChild(name)
	if existing and existing:IsA("Animation") then
		return existing
	end
	if existing then
		existing:Destroy()
	end

	local anim = Instance.new("Animation")
	anim.Name = name
	anim.Parent = container
	return anim
end

----------------------------------------------------------------------
-- Scan / Migrate state machine
----------------------------------------------------------------------

local isBusy = false
local cancelRequested = false

local function setButtonsForIdle(canMigrate: boolean)
	scanButton.Active = true
	scanButton.AutoButtonColor = true

	migrateButton.Active = canMigrate
	migrateButton.AutoButtonColor = canMigrate
	setThemedProp(migrateButton, "BackgroundColor3", canMigrate and "ACCENT" or "ACCENT_DIM")

	cancelButton.Visible = false
	cancelButton.Active = false

	retryFailedButton.Visible = lastFailedEntries ~= nil and #lastFailedEntries > 0
	retryFailedButton.Active = retryFailedButton.Visible
end

local function setButtonsForRunning()
	scanButton.Active = false
	scanButton.AutoButtonColor = false
	migrateButton.Active = false
	migrateButton.AutoButtonColor = false
	setThemedProp(migrateButton, "BackgroundColor3", "ACCENT_DIM")
	cancelButton.Visible = true
	cancelButton.Active = true
	retryFailedButton.Visible = false
	retryFailedButton.Active = false
end

cancelButton.MouseButton1Click:Connect(function()
	if isBusy then
		cancelRequested = true
		appendLogLine("Cancel requested -- finishing in-flight uploads, then stopping...", "WARN")
	end
end)

local function parseGroupId(): number?
	if not uploadTargetIsGroup then
		return nil
	end
	local text = groupIdBox.Text:gsub("%s+", "")
	if text == "" then
		appendLogLine("Group upload selected but no Group ID entered -- publishing under your account instead.", "WARN")
		return nil
	end
	local n = tonumber(text)
	if not n then
		appendLogLine(("Invalid Group ID '%s' -- publishing under your account instead."):format(text), "WARN")
		return nil
	end
	return n
end

local function formatDuration(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	local m = seconds // 60
	local s = seconds % 60
	return ("%d:%02d"):format(m, s)
end

local function doScan()
	if isBusy then
		return
	end
	isBusy = true
	setButtonsForRunning()
	cancelButton.Visible = false
	scanButton.Active = false
	clearLog()
	setProgress(0)
	statusLabel.Text = "Scanning source tree..."
	setThemedProp(statusLabel, "TextColor3", "SUBTEXT")

	local sourceRoot = resolvePath(ReplicatedFirst, SOURCE_PATH)
	if not sourceRoot then
		local msg = ("Source path not found: ReplicatedFirst/%s"):format(table.concat(SOURCE_PATH, "/"))
		appendLogLine(msg, "ERROR", true)
		statusLabel.Text = msg
		setThemedProp(statusLabel, "TextColor3", "ERROR")
		isBusy = false
		setButtonsForIdle(false)
		return
	end

	local destRoot = resolvePath(ReplicatedStorage, DEST_PATH)
	if not destRoot then
		local msg = ("Destination path not found: ReplicatedStorage/%s"):format(table.concat(DEST_PATH, "/"))
		appendLogLine(msg, "ERROR", true)
		statusLabel.Text = msg
		setThemedProp(statusLabel, "TextColor3", "ERROR")
		isBusy = false
		setButtonsForIdle(false)
		return
	end

	local found: { ScanEntry } = {}
	findAllKeyframeSequences(sourceRoot, {}, found)
	lastScanResults = found
	lastFailedEntries = nil

	appendLogLine(("Found %d KeyframeSequence(s). See the Migrate tab for the full tree."):format(#found), "TEXT")

	rebuildTree()

	statusLabel.Text = ("Found %d animation(s). Click Migrate to publish and rewire."):format(#found)
	setThemedProp(statusLabel, "TextColor3", "TEXT")
	isBusy = false
	setButtonsForIdle(#found > 0)
	runSetupCheck()
end

-- Core migration routine, parameterized over which entries to process so it
-- can be reused for both "Migrate" (full scan) and "Resume Unfinished".
local function runMigrationOnEntries(entries: { ScanEntry }, label: string)
	if isBusy then
		return
	end
	isBusy = true
	cancelRequested = false
	setButtonsForRunning()
	clearLog()
	setProgress(0)

	for _, entry in ipairs(entries) do
		setItemStatus(table.concat(entry.path, "/"), "idle")
	end

	local destRoot = resolvePath(ReplicatedStorage, DEST_PATH)
	if not destRoot then
		local msg = ("Destination path not found: ReplicatedStorage/%s"):format(table.concat(DEST_PATH, "/"))
		appendLogLine(msg, "ERROR", true)
		statusLabel.Text = msg
		setThemedProp(statusLabel, "TextColor3", "ERROR")
		isBusy = false
		setButtonsForIdle(true)
		return
	end

	local groupId = parseGroupId()
	local total = #entries

	appendLogLine(("Starting %s of %d animation(s), all in parallel."):format(label, total), "TEXT")

	local successCount = 0
	local interruptedCount = 0 -- items still mid-retry when Cancel was pressed
	local completedCount = 0 -- successCount + interruptedCount
	local retryingNowCount = 0 -- items currently past their first failed attempt
	local totalRetryAttempts = 0 -- cumulative extra attempts across all items, for visibility
	local newFailedEntries: { ScanEntry } = {}
	local itemErrors: { [string]: { string } } = {}

	local function publishUntilSuccess(
		kf: KeyframeSequence,
		animationName: string,
		displayPath: string
	): (number?, number)
		local attempt = 0
		local countedAsRetrying = false
		while true do
			attempt += 1
			if cancelRequested then
				if countedAsRetrying then
					retryingNowCount -= 1
				end
				return nil, attempt
			end

			local assetId, err = publishKeyframeSequence(kf, animationName, groupId)
			if assetId then
				if countedAsRetrying then
					retryingNowCount -= 1
				end
				return assetId, attempt
			end

			totalRetryAttempts += 1
			local errList = itemErrors[displayPath]
			if not errList then
				errList = {}
				itemErrors[displayPath] = errList
			end
			table.insert(errList, ("Attempt %d: %s"):format(attempt, tostring(err)))

			if not countedAsRetrying then
				countedAsRetrying = true
				retryingNowCount += 1
				setItemStatus(displayPath, "retrying")
			end

			task.wait(math.min(RETRY_MAX_DELAY, RETRY_BASE_DELAY * (2 ^ math.min(attempt - 1, 6))))
		end
	end

	local startTime = os.clock()

	local function updateStats()
		local elapsed = os.clock() - startTime
		local avgPerItem = completedCount > 0 and (elapsed / completedCount) or 0
		local remaining = total - completedCount
		local eta = avgPerItem > 0 and (avgPerItem * remaining) or -1
		statsLabel.Text = (
			"Success: %d    Retrying now: %d    Remaining: %d    Total retries: %d\nElapsed: %s    ETA: %s"
		):format(
			successCount,
			retryingNowCount,
			remaining,
			totalRetryAttempts,
			formatDuration(elapsed),
			eta >= 0 and formatDuration(eta) or "--:--"
		)
	end
	updateStats()

	local function processEntry(i: number)
		local entry = entries[i]
		local relPath = entry.path
		local kf = entry.kf
		local kfName = relPath[#relPath]
		local folderParts = table.clone(relPath)
		table.remove(folderParts, #folderParts)
		local displayPath = table.concat(relPath, "/")

		local assetId, attempts = publishUntilSuccess(kf, kfName, displayPath)

		if not assetId then
			-- Only reachable via cancellation mid-retry -- not a permanent
			-- failure, just unfinished work to pick up again later.
			interruptedCount += 1
			table.insert(newFailedEntries, entry)
			setItemStatus(displayPath, "error")
			appendLogLine(
				("[%d/%d] CANCELLED %s (was on attempt %d)"):format(i, total, displayPath, attempts),
				"WARN",
				true,
				itemErrors[displayPath]
			)
		else
			local destFolder = ensureFolderPath(destRoot, folderParts)
			local animInstance = findOrCreateAnimationInstance(destFolder, kfName)
			local oldId = animInstance.AnimationId
			animInstance.AnimationId = ("rbxassetid://%d"):format(assetId)
			successCount += 1
			setItemStatus(displayPath, "success")
			local retrySuffix = attempts > 1 and (" (%d attempts)"):format(attempts) or ""
			appendLogLine(
				("[%d/%d] OK %s (%s -> rbxassetid://%d)%s"):format(
					i,
					total,
					displayPath,
					oldId ~= "" and oldId or "empty",
					assetId,
					retrySuffix
				),
				"SUCCESS",
				false,
				itemErrors[displayPath]
			)
		end

		completedCount += 1
		setProgress(completedCount / total)
		statusLabel.Text = cancelRequested and ("Cancelling... %d/%d complete"):format(completedCount, total)
			or ("Migrating... %d/%d complete"):format(completedCount, total)
		setThemedProp(statusLabel, "TextColor3", "TEXT")
		updateStats()
	end

	-- Fire every entry at once -- no concurrency cap, no worker pool.
	local doneEvent = Instance.new("BindableEvent")
	local remainingToFinish = total

	if total == 0 then
		doneEvent:Fire()
	else
		for i = 1, total do
			task.spawn(function()
				if not cancelRequested then
					processEntry(i)
				else
					local entry = entries[i]
					interruptedCount += 1
					table.insert(newFailedEntries, entry)
					completedCount += 1
				end
				remainingToFinish -= 1
				if remainingToFinish == 0 then
					doneEvent:Fire()
				end
			end)
		end
	end
	doneEvent.Event:Wait()

	lastFailedEntries = newFailedEntries

	local summary = cancelRequested
		and ("Cancelled. Success: %d | Interrupted (unfinished): %d | Total retries made: %d"):format(
			successCount,
			interruptedCount,
			totalRetryAttempts
		)
		or ("Done. All %d animation(s) published successfully. Total retries needed: %d"):format(
			successCount,
			totalRetryAttempts
		)
	appendLogLine(summary, cancelRequested and "WARN" or "SUCCESS")
	statusLabel.Text = summary
	setThemedProp(statusLabel, "TextColor3", cancelRequested and "WARN" or "SUCCESS")
	updateStats()

	isBusy = false
	cancelRequested = false
	setButtonsForIdle(true)
end

local function doMigrate()
	if not lastScanResults then
		return
	end
	runMigrationOnEntries(lastScanResults, "migration")
end

local function doResumeUnfinished()
	if not lastFailedEntries or #lastFailedEntries == 0 then
		return
	end
	runMigrationOnEntries(lastFailedEntries, "resume")
end

scanButton.MouseButton1Click:Connect(function()
	task.spawn(doScan)
end)

migrateButton.MouseButton1Click:Connect(function()
	task.spawn(doMigrate)
end)

retryFailedButton.MouseButton1Click:Connect(function()
	task.spawn(doResumeUnfinished)
end)

----------------------------------------------------------------------
-- Onboarding wizard
----------------------------------------------------------------------

local wizardOverlay = Instance.new("Frame")
wizardOverlay.Size = UDim2.fromScale(1, 1)
wizardOverlay.Position = UDim2.fromScale(0, 0)
wizardOverlay.ZIndex = 100
wizardOverlay.Visible = false
wizardOverlay.Parent = widget
setThemedProp(wizardOverlay, "BackgroundColor3", "BG")

local wizardPad = Instance.new("UIPadding")
wizardPad.PaddingTop = UDim.new(0, 20)
wizardPad.PaddingBottom = UDim.new(0, 16)
wizardPad.PaddingLeft = UDim.new(0, 24)
wizardPad.PaddingRight = UDim.new(0, 24)
wizardPad.Parent = wizardOverlay

local wizardRootLayout = Instance.new("UIListLayout")
wizardRootLayout.SortOrder = Enum.SortOrder.LayoutOrder
wizardRootLayout.Padding = UDim.new(0, 14)
wizardRootLayout.Parent = wizardOverlay

local wizardContentHolder = Instance.new("Frame")
wizardContentHolder.Size = UDim2.new(1, 0, 1, -60)
wizardContentHolder.BackgroundTransparency = 1
wizardContentHolder.LayoutOrder = 1
wizardContentHolder.ZIndex = 100
wizardContentHolder.Parent = wizardOverlay

local WIZARD_PAGE_COUNT = 4
local wizardPages: { Frame } = {}

local function makeWizardPage(): Frame
	local page = Instance.new("Frame")
	page.Size = UDim2.fromScale(1, 1)
	page.BackgroundTransparency = 1
	page.Visible = false
	page.ZIndex = 100
	page.Parent = wizardContentHolder

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 10)
	layout.Parent = page

	table.insert(wizardPages, page)
	return page
end

local function wizardTitle(page: Frame, order: number, text: string)
	local t = makeLabel(page, text, UDim2.new(1, 0, 0, 30), { Bold = true, TextSize = 22 })
	t.LayoutOrder = order
	t.ZIndex = 100
	return t
end

local function wizardBody(page: Frame, order: number, text: string)
	local b = makeLabel(page, text, UDim2.new(1, 0, 0, 0), { TextSize = 13, Wrapped = true })
	b.AutomaticSize = Enum.AutomaticSize.Y
	b.TextYAlignment = Enum.TextYAlignment.Top
	b.LayoutOrder = order
	b.ZIndex = 100
	return b
end

-- Page 1: Welcome
local wizardPage1 = makeWizardPage()
wizardTitle(wizardPage1, 1, "Welcome to RCE Animation Migrator")
wizardBody(
	wizardPage1,
	2,
	table.concat({
		"This plugin recursively publishes every KeyframeSequence found under:",
		"",
		("  ReplicatedFirst/%s"):format(table.concat(SOURCE_PATH, "/")),
		"",
		"and rewires the matching Animation.AnimationId at the same relative path under:",
		"",
		("  ReplicatedStorage/%s"):format(table.concat(DEST_PATH, "/")),
		"",
		"Folders are matched by name/path and created automatically if missing. It's a first-party",
		"dev tool: it only touches instances inside the place you have open, using your own logged-in",
		"publish permissions. No cookies, no external HTTP calls.",
	}, "\n")
)

-- Page 2: Requirements
local wizardPage2 = makeWizardPage()
wizardTitle(wizardPage2, 1, "One-time setup required")
wizardBody(
	wizardPage2,
	2,
	table.concat({
		"This plugin publishes animations using AssetService:CreateAssetAsync, which still sits",
		"behind a Studio beta toggle. Skipping this makes every publish attempt fail immediately.",
		"",
		"1. File -> Beta Features -> search \"CreateAssetAsync\" -> enable it.",
		"2. Restart Studio completely (the toggle needs a relaunch).",
		"3. Reopen this place.",
	}, "\n")
)
makeCheckRow(
	wizardPage2,
	3,
	"I enabled the \"CreateAssetAsync\" beta feature and restarted Studio.",
	checkBetaConfirmed,
	function(checked)
		checkBetaConfirmed = checked
		setSetting("RCEAnimationMigrator_CheckBeta", checked)
	end
)
makeCheckRow(
	wizardPage2,
	4,
	"(Optional) I allowed HTTP Requests in Game Settings -> Security.",
	checkHttpConfirmed,
	function(checked)
		checkHttpConfirmed = checked
		setSetting("RCEAnimationMigrator_CheckHttp", checked)
	end
)
do
	local groupNote = wizardBody(
		wizardPage2,
		5,
		"One more thing: if this place is owned by a Group, you must publish to that Group -- publishing "
			.. "under your personal account is broken for group-owned games and every upload will fail. The "
			.. "live check on the next page will tell you whether that applies here, and the Setup tab has a "
			.. "one-click \"Use this Group\" fix if it does."
	)
	setThemedProp(groupNote, "TextColor3", "WARN")
end

-- Page 3: Live setup check
local wizardPage3 = makeWizardPage()
wizardTitle(wizardPage3, 1, "Let's check your place")
wizardBody(wizardPage3, 2, "These are detected automatically -- no need to take my word for it:")
local wizardChecklistPanel = Instance.new("Frame")
wizardChecklistPanel.Size = UDim2.new(1, 0, 0, 0)
wizardChecklistPanel.AutomaticSize = Enum.AutomaticSize.Y
wizardChecklistPanel.LayoutOrder = 3
wizardChecklistPanel.ZIndex = 100
wizardChecklistPanel.Parent = wizardPage3
setThemedProp(wizardChecklistPanel, "BackgroundColor3", "PANEL")
corner(wizardChecklistPanel, 8)
stroke(wizardChecklistPanel, "BORDER")
local wizardChecklistPad = Instance.new("UIPadding")
wizardChecklistPad.PaddingTop = UDim.new(0, 12)
wizardChecklistPad.PaddingBottom = UDim.new(0, 12)
wizardChecklistPad.PaddingLeft = UDim.new(0, 14)
wizardChecklistPad.PaddingRight = UDim.new(0, 14)
wizardChecklistPad.Parent = wizardChecklistPanel
local wizardChecklistLayout = Instance.new("UIListLayout")
wizardChecklistLayout.SortOrder = Enum.SortOrder.LayoutOrder
wizardChecklistLayout.Padding = UDim.new(0, 8)
wizardChecklistLayout.Parent = wizardChecklistPanel
buildAutoChecklistInto(wizardChecklistPanel, 0)
local wizardRecheckButton = makeButton(wizardPage3, "Re-check now", UDim2.new(0, 130, 0, 28), "PANEL", true)
wizardRecheckButton.LayoutOrder = 4
wizardRecheckButton.ZIndex = 100
stroke(wizardRecheckButton, "BORDER")
wizardRecheckButton.MouseButton1Click:Connect(runSetupCheck)

-- Page 4: Ready
local wizardPage4 = makeWizardPage()
wizardTitle(wizardPage4, 1, "You're ready")
wizardBody(
	wizardPage4,
	2,
	table.concat({
		"Head to the Setup tab to pick where uploads go (your account or a group) and pick a theme.",
		"",
		"Then in the Migrate tab: click Scan to list every animation that will be migrated -- nothing",
		"uploads yet. Review the tree, then click Migrate. Failed uploads just keep retrying with",
		"backoff until they succeed, so you don't need to babysit it.",
		"",
		"You can reopen this guide anytime from the \"Guide\" button, top-right.",
	}, "\n")
)

-- Nav row
local wizardNavRow = Instance.new("Frame")
wizardNavRow.Size = UDim2.new(1, 0, 0, 40)
wizardNavRow.BackgroundTransparency = 1
wizardNavRow.LayoutOrder = 2
wizardNavRow.ZIndex = 100
wizardNavRow.Parent = wizardOverlay

local wizardDotsRow = Instance.new("Frame")
wizardDotsRow.Size = UDim2.new(0, 80, 1, 0)
wizardDotsRow.Position = UDim2.new(0, 0, 0, 0)
wizardDotsRow.BackgroundTransparency = 1
wizardDotsRow.ZIndex = 100
wizardDotsRow.Parent = wizardNavRow
local wizardDotsLayout = Instance.new("UIListLayout")
wizardDotsLayout.FillDirection = Enum.FillDirection.Horizontal
wizardDotsLayout.VerticalAlignment = Enum.VerticalAlignment.Center
wizardDotsLayout.Padding = UDim.new(0, 6)
wizardDotsLayout.Parent = wizardDotsRow

local wizardDots: { Frame } = {}
for i = 1, WIZARD_PAGE_COUNT do
	local dot = Instance.new("Frame")
	dot.Size = UDim2.new(0, 8, 0, 8)
	dot.ZIndex = 100
	dot.Parent = wizardDotsRow
	corner(dot, 4)
	setThemedProp(dot, "BackgroundColor3", "BORDER")
	table.insert(wizardDots, dot)
end

local wizardSkipButton = makeButton(wizardNavRow, "Skip", UDim2.new(0, 70, 1, 0), "PANEL", true)
wizardSkipButton.Position = UDim2.new(1, -260, 0, 0)
wizardSkipButton.ZIndex = 100
stroke(wizardSkipButton, "BORDER")

local wizardBackButton = makeButton(wizardNavRow, "Back", UDim2.new(0, 80, 1, 0), "PANEL", true)
wizardBackButton.Position = UDim2.new(1, -180, 0, 0)
wizardBackButton.ZIndex = 100
stroke(wizardBackButton, "BORDER")

local wizardNextButton = makeButton(wizardNavRow, "Next", UDim2.new(0, 100, 1, 0), "ACCENT")
wizardNextButton.Position = UDim2.new(1, -100, 0, 0)
wizardNextButton.ZIndex = 100

local wizardPageIndex = 1

local function showWizardPage(i: number)
	wizardPageIndex = i
	for idx, pg in ipairs(wizardPages) do
		pg.Visible = (idx == i)
	end
	for idx, dot in ipairs(wizardDots) do
		setThemedProp(dot, "BackgroundColor3", idx == i and "ACCENT" or "BORDER")
	end
	wizardBackButton.Visible = i > 1
	wizardNextButton.Text = i < WIZARD_PAGE_COUNT and "Next" or "Get Started"
	if i == 3 then
		runSetupCheck()
	end
end

local function closeWizard()
	wizardOverlay.Visible = false
	setSetting("RCEAnimationMigrator_WizardSeen", true)
end

openWizard = function()
	showWizardPage(1)
	wizardOverlay.Visible = true
end

wizardBackButton.MouseButton1Click:Connect(function()
	if wizardPageIndex > 1 then
		showWizardPage(wizardPageIndex - 1)
	end
end)
wizardNextButton.MouseButton1Click:Connect(function()
	if wizardPageIndex < WIZARD_PAGE_COUNT then
		showWizardPage(wizardPageIndex + 1)
	else
		closeWizard()
	end
end)
wizardSkipButton.MouseButton1Click:Connect(closeWizard)

----------------------------------------------------------------------
-- Resize wiring
----------------------------------------------------------------------

root:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
	resizeContentArea()
	-- contentArea's own AbsoluteSize hasn't propagated to migratePage/logPage
	-- yet within this same frame -- defer so the fill-child calcs read the
	-- post-layout sizes instead of last frame's.
	task.defer(function()
		resizeMigrateTree()
		resizeLog()
	end)
end)
header:GetPropertyChangedSignal("AbsoluteSize"):Connect(resizeContentArea)
tabBar:GetPropertyChangedSignal("AbsoluteSize"):Connect(resizeContentArea)
statsBar:GetPropertyChangedSignal("AbsoluteSize"):Connect(resizeMigrateTree)

task.defer(function()
	resizeContentArea()
	resizeMigrateTree()
	resizeLog()
end)

----------------------------------------------------------------------
-- Initial state
----------------------------------------------------------------------

runSetupCheck()

do
	local lastTab = getSetting("RCEAnimationMigrator_LastTab", "Migrate") :: string
	local idx = 2
	for i, name in ipairs(TAB_NAMES) do
		if name == lastTab then
			idx = i
		end
	end
	selectTab(idx)
end

do
	local wizardSeen = getSetting("RCEAnimationMigrator_WizardSeen", false) :: boolean
	if not wizardSeen then
		openWizard()
	end
end

print("[RCE Migrator] Plugin loaded. Open the panel from the Plugins toolbar.")
