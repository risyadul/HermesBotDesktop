---
version: alpha
name: Hermes Bot
description: Native macOS conversation desk for one engineer running a team of Hermes bots. Graphite chrome, colour belongs to the bots.
colors:
  primary: "#1D1D1F"
  on-primary: "#FFFFFF"
  primary-soft: "#EEEEF0"
  window: "#FFFFFF"
  surface: "#F7F6F3"
  ink: "#1D1D1F"
  muted: "#6B6B70"
  hairline: "#E8E8E9"
  hover: "#F4F4F4"
  selected: "#EDEDED"
  danger: "#B3261E"
  danger-soft: "#FBE9E7"
  attention: "#955A00"
  attention-soft: "#FDF3E1"
  status-ok: "#1C7A82"
  find-match: "#FFE58A"
  find-current: "#C99700"
  primary-dark: "#F2F2F4"
  on-primary-dark: "#1D1D1F"
  primary-soft-dark: "#34343A"
  window-dark: "#232326"
  surface-dark: "#2A2A2E"
  ink-dark: "#F2F2F4"
  muted-dark: "#AEAEB5"
  hairline-dark: "#39393C"
  hover-dark: "#2C2C2F"
  selected-dark: "#38383B"
  danger-dark: "#F2B8B5"
  danger-soft-dark: "#3B2422"
  attention-dark: "#F0BE5E"
  attention-soft-dark: "#3A2F1A"
  find-match-dark: "#5C4A00"
  find-current-dark: "#E0B000"
  bot-rose: "#B0436A"
  bot-red: "#B3362F"
  bot-teal: "#1C7A82"
  bot-brown: "#8A5526"
  bot-green: "#3B7535"
  bot-blue: "#2A6FA0"
  bot-violet: "#6E4FA8"
  bot-olive: "#6B6A1F"
typography:
  title-pane:
    fontFamily: SF Pro Display
    fontSize: 15px
    fontWeight: 600
    lineHeight: 1.2
  title-state:
    fontFamily: SF Pro Display
    fontSize: 17px
    fontWeight: 600
    lineHeight: 1.25
  body:
    fontFamily: SF Pro Text
    fontSize: 13px
    fontWeight: 400
    lineHeight: 1.45
  body-strong:
    fontFamily: SF Pro Text
    fontSize: 13px
    fontWeight: 600
    lineHeight: 1.45
  body-medium:
    fontFamily: SF Pro Text
    fontSize: 13px
    fontWeight: 500
    lineHeight: 1.45
  meta:
    fontFamily: SF Pro Text
    fontSize: 12px
    fontWeight: 400
    lineHeight: 1.35
  meta-strong:
    fontFamily: SF Pro Text
    fontSize: 12px
    fontWeight: 600
    lineHeight: 1.35
  caption:
    fontFamily: SF Pro Text
    fontSize: 11px
    fontWeight: 500
    lineHeight: 1.3
  caption-strong:
    fontFamily: SF Pro Text
    fontSize: 11px
    fontWeight: 600
    lineHeight: 1.3
  monogram:
    fontFamily: SF Pro Rounded
    fontSize: 11px
    fontWeight: 700
    lineHeight: 1
  code:
    fontFamily: SF Mono
    fontSize: 12px
    fontWeight: 400
    lineHeight: 1.45
spacing:
  s0: 2px
  s1: 4px
  s2: 8px
  s3: 12px
  s4: 16px
  s5: 24px
  s6: 40px
  gutter: 10px
  timeline: 14px
rounded:
  inline: 4px
  control: 6px
  chip: 8px
  avatar: 8px
  avatar-small: 5px
  card: 10px
  bubble: 12px
  sheet: 14px
components:
  button-primary:
    backgroundColor: "{colors.primary}"
    textColor: "{colors.on-primary}"
    typography: "{typography.body-strong}"
    rounded: "{rounded.control}"
    padding: 6px 12px
    height: 28px
  button-primary-dark:
    backgroundColor: "{colors.primary-dark}"
    textColor: "{colors.on-primary-dark}"
    typography: "{typography.body-strong}"
    rounded: "{rounded.control}"
    padding: 6px 12px
    height: 28px
  button-primary-disabled:
    backgroundColor: "{colors.primary-soft}"
    textColor: "{colors.muted}"
    typography: "{typography.body-strong}"
    rounded: "{rounded.control}"
  button-primary-disabled-dark:
    backgroundColor: "{colors.primary-soft-dark}"
    textColor: "{colors.muted-dark}"
    typography: "{typography.body-strong}"
    rounded: "{rounded.control}"
  button-secondary:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.ink}"
    typography: "{typography.body}"
    rounded: "{rounded.control}"
    padding: 6px 12px
    height: 28px
  button-secondary-hover:
    backgroundColor: "{colors.selected}"
    textColor: "{colors.ink}"
  button-secondary-dark:
    backgroundColor: "{colors.surface-dark}"
    textColor: "{colors.ink-dark}"
    rounded: "{rounded.control}"
  button-danger:
    backgroundColor: "{colors.window}"
    textColor: "{colors.danger}"
    typography: "{typography.body-strong}"
    rounded: "{rounded.control}"
    padding: 6px 12px
    height: 28px
  button-danger-hover:
    backgroundColor: "{colors.danger-soft}"
    textColor: "{colors.danger}"
  button-danger-dark:
    backgroundColor: "{colors.window-dark}"
    textColor: "{colors.danger-dark}"
    typography: "{typography.body-strong}"
    rounded: "{rounded.control}"
  sidebar-row:
    textColor: "{colors.ink}"
    typography: "{typography.body}"
    rounded: "{rounded.control}"
    padding: 6px 8px
    height: 44px
  sidebar-row-hover:
    backgroundColor: "{colors.hover}"
    textColor: "{colors.ink}"
  sidebar-row-selected:
    backgroundColor: "{colors.selected}"
    textColor: "{colors.ink}"
  sidebar-row-selected-dark:
    backgroundColor: "{colors.selected-dark}"
    textColor: "{colors.ink-dark}"
  sidebar-row-hover-dark:
    backgroundColor: "{colors.hover-dark}"
    textColor: "{colors.ink-dark}"
  avatar:
    textColor: "{colors.on-primary}"
    typography: "{typography.monogram}"
    rounded: "{rounded.avatar}"
    size: 28px
  avatar-message:
    rounded: "{rounded.avatar}"
    size: 32px
  avatar-hero:
    rounded: "{rounded.avatar}"
    size: 28px
  avatar-inspector:
    rounded: "{rounded.avatar}"
    size: 36px
  avatar-chat-empty:
    rounded: "{rounded.avatar}"
    size: 96px
  avatar-chip:
    rounded: "{rounded.avatar-small}"
    size: 20px
  avatar-rose:
    backgroundColor: "{colors.bot-rose}"
    textColor: "{colors.on-primary}"
  avatar-red:
    backgroundColor: "{colors.bot-red}"
    textColor: "{colors.on-primary}"
  avatar-teal:
    backgroundColor: "{colors.bot-teal}"
    textColor: "{colors.on-primary}"
  avatar-brown:
    backgroundColor: "{colors.bot-brown}"
    textColor: "{colors.on-primary}"
  avatar-green:
    backgroundColor: "{colors.bot-green}"
    textColor: "{colors.on-primary}"
  avatar-blue:
    backgroundColor: "{colors.bot-blue}"
    textColor: "{colors.on-primary}"
  avatar-violet:
    backgroundColor: "{colors.bot-violet}"
    textColor: "{colors.on-primary}"
  avatar-olive:
    backgroundColor: "{colors.bot-olive}"
    textColor: "{colors.on-primary}"
  status-chip:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.muted}"
    typography: "{typography.meta}"
    rounded: "{rounded.chip}"
    padding: 4px 10px 4px 4px
    height: 28px
  status-chip-dark:
    backgroundColor: "{colors.surface-dark}"
    textColor: "{colors.muted-dark}"
    typography: "{typography.meta}"
    rounded: "{rounded.chip}"
  status-chip-attention:
    backgroundColor: "{colors.attention-soft}"
    textColor: "{colors.attention}"
    typography: "{typography.meta}"
    rounded: "{rounded.chip}"
  status-chip-attention-dark:
    backgroundColor: "{colors.attention-soft-dark}"
    textColor: "{colors.attention-dark}"
    rounded: "{rounded.chip}"
  status-chip-failed:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.danger}"
    rounded: "{rounded.chip}"
  status-chip-failed-dark:
    backgroundColor: "{colors.surface-dark}"
    textColor: "{colors.danger-dark}"
    rounded: "{rounded.chip}"
  message-member:
    backgroundColor: "{colors.window}"
    textColor: "{colors.ink}"
    typography: "{typography.body}"
    width: 720px
  message-member-dark:
    backgroundColor: "{colors.window-dark}"
    textColor: "{colors.ink-dark}"
    typography: "{typography.body}"
  message-user:
    backgroundColor: "{colors.primary-soft}"
    textColor: "{colors.ink}"
    typography: "{typography.body}"
    rounded: "{rounded.bubble}"
    padding: 8px 12px
    width: 520px
  message-user-dark:
    backgroundColor: "{colors.primary-soft-dark}"
    textColor: "{colors.ink-dark}"
    rounded: "{rounded.bubble}"
  message-meta:
    backgroundColor: "{colors.window}"
    textColor: "{colors.muted}"
    typography: "{typography.caption}"
  message-meta-dark:
    backgroundColor: "{colors.window-dark}"
    textColor: "{colors.muted-dark}"
    typography: "{typography.caption}"
  code-block:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.ink}"
    typography: "{typography.code}"
    rounded: "{rounded.chip}"
    padding: 10px 12px
  code-block-dark:
    backgroundColor: "{colors.surface-dark}"
    textColor: "{colors.ink-dark}"
    typography: "{typography.code}"
    rounded: "{rounded.chip}"
  action-card:
    backgroundColor: "{colors.attention-soft}"
    textColor: "{colors.ink}"
    typography: "{typography.body}"
    rounded: "{rounded.card}"
    padding: 12px 16px
    width: 560px
  action-card-dark:
    backgroundColor: "{colors.attention-soft-dark}"
    textColor: "{colors.ink-dark}"
    rounded: "{rounded.card}"
  action-card-failure:
    backgroundColor: "{colors.danger-soft}"
    textColor: "{colors.ink}"
    rounded: "{rounded.card}"
    padding: 12px 16px
  action-card-failure-dark:
    backgroundColor: "{colors.danger-soft-dark}"
    textColor: "{colors.ink-dark}"
    rounded: "{rounded.card}"
  composer:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.ink}"
    typography: "{typography.body}"
    rounded: "{rounded.card}"
    padding: 8px 8px 8px 12px
  composer-dark:
    backgroundColor: "{colors.surface-dark}"
    textColor: "{colors.ink-dark}"
    rounded: "{rounded.card}"
  round-divider:
    backgroundColor: "{colors.window}"
    textColor: "{colors.muted}"
    typography: "{typography.caption}"
  round-divider-dark:
    backgroundColor: "{colors.window-dark}"
    textColor: "{colors.muted-dark}"
    typography: "{typography.caption}"
  error-line:
    backgroundColor: "{colors.window}"
    textColor: "{colors.danger}"
    typography: "{typography.meta}"
  error-line-dark:
    backgroundColor: "{colors.window-dark}"
    textColor: "{colors.danger-dark}"
    typography: "{typography.meta}"
  hairline-rule:
    backgroundColor: "{colors.hairline}"
    height: 1px
  hairline-rule-dark:
    backgroundColor: "{colors.hairline-dark}"
    height: 1px
  connection-dot:
    backgroundColor: "{colors.status-ok}"
    size: 7px
  sheet:
    backgroundColor: "{colors.window}"
    textColor: "{colors.ink}"
    rounded: "{rounded.sheet}"
    padding: 24px
    width: 460px
  sheet-dark:
    backgroundColor: "{colors.window-dark}"
    textColor: "{colors.ink-dark}"
    rounded: "{rounded.sheet}"
  empty-state:
    backgroundColor: "{colors.window}"
    textColor: "{colors.muted}"
    typography: "{typography.body}"
    padding: 40px
  empty-state-dark:
    backgroundColor: "{colors.window-dark}"
    textColor: "{colors.muted-dark}"
    typography: "{typography.body}"
---

## Overview

Hermes Bot is a native macOS desk for one engineer who runs a small team of Hermes bots: 1:1 Bot Chat
and multi-bot Group Chat over a local `hermes serve` backend. It is an operate surface, read for long
stretches, so the chrome stays quiet and Mac-native while the bots carry the colour.

Design read: operate surface (multi-bot conversation inbox) for one engineer, native macOS visual
language, dial **ENERGY 2 / RHYTHM 2 / MOTION 3**. Motion is high because every animation reports a
state change (a reply arrived, a turn settled, an approval is waiting); none of it is decoration.

Three ideas carry the identity:

1. **Graphite chrome, coloured bots.** The single accent is graphite (near-black in light, near-white in
   dark). Bot avatars are already colourful, so a neutral accent keeps colour as the bots' identity.
2. **The turn ribbon.** A row of member chips above the Group Chat timeline answers "who answered,
   who passed, who needs me" at a glance. It is the app's recurring motif.
3. **Answers first.** Passes collapse into one thin line, round ends become a hairline divider, so the
   timeline holds real answers.

Reference visual: the reviewed web mockup `hermes-bot-app-ui-plan/ui-plan.html` (outside this repo).
The avatar images in that mockup folder are preview copies only and are never bundled.

## Colors

All colour lives in the tokens above; SwiftUI reads them from `Sources/HermesBotApp/DesignSystem.swift`
(`DS.Palette`). Every role has a light value and a `-dark` value. Dark is designed, not inverted:
surfaces step up in lightness from window to surface to soft, text drops to `#F2F2F4`, and the danger
role becomes a light coral so it still reads on charcoal.

- **Primary / graphite (`#1D1D1F`, dark `#F2F2F4`):** the only accent. Used on the Send button, the
  primary action of an action card, @mentions in the user's own messages, and the focus ring of the
  composer. Nothing else is tinted with it. In dark mode the enabled affordances (Send, Approve once,
  Retry) are the bright `#F2F2F4` fill with graphite text (15:1), the brightest thing in the pane.
- **Primary soft (`#EEEEF0`, dark `#34343A`):** the user's own message bubble and every disabled primary
  button (muted label on soft fill, 4.6:1 light / 5.6:1 dark). Disabled is a designed state, never an
  opacity fade: a faded graphite button on charcoal turns into an unreadable grey.
- **Attention (`#955A00` / soft `#FDF3E1`, dark `#F0BE5E` / `#3A2F1A`):** "waiting on you", used only for
  a pending approval or retry: the action card fill and ring, and the `needs approval` / `needs retry`
  ribbon chip; and for `@user` in Group Chat messages (a bot asking for the user), as text at 600 (5.6:1 on
  window, 4.8:1 on the user bubble, light; 7:1 or more dark). It is the one warm hue in the chrome so the state that blocks a bot is the most urgent
  thing on screen and is never confused with `waiting` (a bot that has not answered yet). Text passes
  5.1:1 (light, on soft) and 7.6:1 (dark, on soft).
- **Window / surface (`#FFFFFF` / `#F7F6F3`):** content stays on solid surfaces for long reading. The
  surface tone is warm by a hair so code blocks and the composer separate from the window without a
  border.
- **Ink / muted:** body text and secondary text. Muted passes 4.5:1 on window, surface and primary soft
  in both modes (lowest pairs: `#6B6B70` on `#EEEEF0` = 4.57:1; dark `#AEAEB5` on `#34343A` = 5.6:1,
  on the surface chips 6.5:1). Muted text is never dimmed further with opacity.
- **Hairline, hover, selected:** solid equivalents of 9% / 4.5% / 7.5% black (light) and 10% / 6% / 10%
  white (dark) on the window colour. In code they are applied as translucent black/white so they also
  work over the sidebar material.
- **Danger (`#B3261E`, dark `#F2B8B5`):** failed turns, failed actions, the Deny button, destructive
  menu items. Never used for "working".
- **Status ok (`#1C7A82`):** the 7 px connection dot in the sidebar footer only.
- **Find match (`#FFE58A`, dark `#5C4A00`) / find current (`#C99700`, dark `#E0B000`):** Find in chat only.
  Every match's text sits on the match fill (ink on it 14:1 light, 7.8:1 dark; link blue 4.6:1 light); the
  message holding the current match gets a 1.5 pt ring in find current. Highlighter yellow, so it is never
  read as the attention role.

### Bot identity colours

Eight categorical colours (`bot-rose` … `bot-olive`), each passing 5:1 or better with white text and
4.6:1 or better as text on window and surface. They are an identity system, not a palette: they appear
only on avatar tiles, member names, ribbon chip borders and the composer's mention suggestions.

- Assignment is derived from the profile name: FNV-1a of the lowercased name selects a slot; when two
  profiles in the roster land on the same slot, the later name (sorted order) probes to the next free
  slot. Colours are therefore stable across launches and unique for up to eight bots.
- In dark mode a member name is drawn in the bot colour mixed 45% with white, i.e. 55% bot colour (all
  ≥ 5.5:1 on the dark window); avatar tiles keep the base colour.

## Typography

SF Pro, the macOS system face, everywhere: a native app should read like the other Mac apps beside it,
so the typeface is a platform decision, not a style pick. SF Mono for code and commands. SF Pro
Rounded only for avatar monograms, where the rounded terminals keep two letters legible at 9-11 px.

- `title-pane` 15/600: pane titles (room name, bot name) and sheet titles.
- `title-state` 17/600: empty, loading and error state headings.
- `body` 13/400: messages, rows, controls. `body-medium` 13/500 for sidebar row titles. `body-strong`
  13/600 for names, primary and danger buttons.
- `meta` 12/400: subtitles, chip labels, bubble timestamps, error lines. `meta-strong` 12/600 for form
  labels and the `needs approval` / `needs retry` chip label.
- `caption` 11/500: round dividers, composer hints, sync footer, inspector field labels.
  `caption-strong` 11/600 for sidebar section labels and the "Command" label.
- SF Symbols follow the text they sit beside: 13 pt medium next to body text and in icon buttons, 11 pt
  semibold next to meta/caption, 28 pt regular in empty states.
- `code` 12 SF Mono: fenced code blocks, inline code, approval commands.

Hierarchy comes from size and weight, never from uppercase tracking.

## Layout

A two-column window: a 260 pt sidebar (system sidebar material) and a detail pane with the unified
toolbar. Minimum window 820 × 520.

- Spacing scale 2 / 4 / 8 / 12 / 16 / 24 / 40, plus two named steps: `gutter` 10 (avatar to text, chip
  trailing padding) and `timeline` 14 (gap between timeline items). Rows and chips use 4-8, panes use
  16 horizontal padding, the timeline has 24 side and 16 top padding, empty states sit in 40 of air.
  Every view value comes from `DesignSystem.swift`; a number that is not a token is a design change.
- **Content edge:** member text starts at avatar 32 + gutter 10 = 42 pt. Pass lines, status lines,
  failure and action cards start on that same edge, so the timeline has one left margin for content.
- **Sidebar:** Group Chats first (the main work), then Bots, then Boards (kanban). Rows are 44 pt high:
  avatar (or the room's two-avatar stack, or a board tile), title, one muted subtitle line. A board row
  carries a breathing dot + count for running cards and an attention count for blocked ones; when the
  kanban plugin is off the section is one muted line, "Kanban is off in Hermes". A breathing dot marks a room whose round is
  running. Bots are ordered pinned first, then newest activity (Desktop's roster order); the Bots header
  carries a `folder.badge.plus` icon button for New Section, and user sections draw as `bot-section` blocks
  above an "Unassigned" block (no sections: the flat list). Footer: connection dot plus the backend in two or three words ("Hermes Desktop", "hermes
  serve", "Private hermes serve") so it never truncates at the 220 pt minimum; the full mode is the
  tooltip.
  Group Chats are ordered pinned first, then the user's order (Move Up / Move Down in the row menu, or drag a
  row onto another in the same group: the target row gets a 2 pt `ring` outline while a room hovers over it).
- **Group Chat:** toolbar (room picture or avatar stack, room name + "N of M available", Stop, room menu),
  turn ribbon, timeline, note bar,
  composer. Member messages are not bubbled: avatar + coloured name + text at reading width (max
  720 pt), which keeps long answers comfortable. The user's messages are right-aligned soft bubbles (max
  520 pt). Action cards (approval, retry) start on the content edge and are capped at 560 pt. Room-level
  "working" is said once, by the ribbon's room chip; the timeline does not repeat it.
- **Bot Chat:** toolbar (avatar hero + name + model, detail toggle), timeline in the same message
  grammar, composer, and a native inspector (240 pt, resizable 200–260 pt): identity header (name,
  @handle, a "Default profile" tag when it is the default, and a muted ••• menu for Edit… / Duplicate /
  Delete… at its trailing edge, so it costs no row at the 520 pt minimum height), then About, Model,
  Provider, Skills. The
  @handle is the profile name, so no separate Profile field repeats it. The inspector state is
  remembered. The chat column has no minimum width of its own: it takes what the sidebar and the
  inspector leave (312 pt at the 820 pt minimum with default column widths). The inspector's 260 pt
  maximum is what still fits at the 820 pt minimum next to a 280 pt sidebar column, so dragging it
  wide, or shrinking a window with a wide inspector, never pushes it past the window edge.
- **Kanban board:** toolbar (board name + task count, New Task, card details toggle), a header row
  (board switcher when there are two or more boards, filter field 220 pt, the filter menu: profile, Show
  archived, Group Running by profile, its symbol filled while a profile or archived is on; Workers as
  `button-secondary`, opening a 560 × 420 sheet of worker rows on `surface` with an amber heartbeat line after
  two minutes without one; dispatcher chip; Running grouped by profile shows a caption per group: 18 pt
  avatar, @name, count), a note bar
  (failed action in danger, the server's create warning in attention), then the lanes in server order
  as a horizontally scrolling row of 248 pt `surface` columns (card radius) with label + count; an empty
  archive lane is hidden and the dispatcher-only lanes (running, review, scheduled) show a lock and
  refuse drops. Other empty lanes fold into a 36 pt strip (count, label running top to bottom, lock) so the
  lanes with cards fit; a click unfolds one (a chevron in its header folds it again), it still takes
  dropped cards, and nothing folds while the whole board is empty. The selected card's lane and the card
  itself scroll into view (the least distance) when the selection changes and when the board narrows. Cards are `window` tiles (chip radius, hairline; the open card has the graphite ring):
  title, a `P<n>` tag when prioritised, state flags (running dot; attention for blocked / needs input /
  no heartbeat; danger for failed runs; muted "won't run" for a ready card with no assignee), then
  assignee avatar 20 + @handle, comment count and age; the card's tooltip is its id. The card details
  inspector uses the Bot Chat inspector's widths. It is closed until a card is selected and opens on
  selection, unless the user closed it with a card selected: that choice is remembered, a click then only
  selects, and the toggle (⌥⌘I) or the card's Open opens it again. Its Attachments section has a paperclip icon button in the
  header, one row per file (doc icon, name in `link`, then size · date · uploader in caption muted, a trash
  icon button that asks first) and takes dropped files with the composer's dashed `DropHighlight`. On a
  running card the comment box reads "Message the running worker…", a caption-muted hint sits under the
  full-width field, and Requeue with note (secondary) sits left of Send (primary); otherwise the field and
  Comment share one row. The dispatcher chip is a `status-chip`: muted when running,
  attention when stopped (with Start) or not installed (its popover shows `hermes gateway install` to
  copy).
  K6/K7/K9 additions: the header row has a Board menu (`ellipsis.circle`, borderless, no indicator) after the
  switcher: New Board…, Rename Board…, Export Board…, Import Board…, Orchestration Settings…, Delete Board…
  (destructive, disabled for `default`; its confirmation says the board is archived, not erased, and warns
  when it is Hermes' current board). New / Rename and Orchestration are `sheetWidth` sheets like New Task
  (name field with the derived id in caption muted, a taken id in danger; orchestration: two profile pickers
  with "Default (resolved)" first and two toggles, each with a caption-muted line, saved on change). Board
  action results use the note bar (muted with a check, danger on failure). The card inspector gains a Model
  field under Priority (a borderless menu: Profile Default, one submenu per provider, Other Model…, a
  Reasoning submenu; label "provider: model · Effort"), an Assignee chat icon button (Open Bot Chat) when the
  assignee is a bot in the roster, and an "AI actions" section after the fields: Estimate, Decompose…,
  Specify… as `button-secondary` (one row, or stacked when narrow; Decompose / Specify only enabled on
  triage cards), a mini spinner with "Estimating…", the estimate as "~120k tokens · Medium" (meta strong)
  with the rationale and "Rough guess, not a bill · model" muted, and the last outcome as a meta label (muted
  check, or danger) with the created subtasks as `link` rows. Decompose and Specify confirm first. The card
  menu adds Open Bot Chat with @x, the three AI actions and a "Notify When Done or Blocked" toggle (also in
  the inspector's ••• menu).
- **Create Task from Message** (Group Chat and Bot Chat message menus, after Copy): the New Task sheet with a
  caption line "From Alice in Launch" under its title, a Board picker first, and the title, description and
  assignee prefilled.
- **Group Chat Activity panel** (the room inspector, 200–260 pt): tool titles wrap to two lines with the
  count and duration kept beside them, and the "Turn finished · 4.2s" divider label never shrinks (its
  trailing rule gives way). Two or more finished turns in a row with nothing between them share one divider,
  "3 turns finished · 4.3–15s" (the range of their durations).
- **Change Members sheet** (`sheet`, 460 pt): step 1 is the create-room form titled "Change members" with a muted
  `meta` line explaining that a new room is made, the current bots ticked, and Create New Room (primary). Step 2
  says what was created, then "What about the previous room?" as a radio group: Keep it (default; a checkbox to
  rename it "… (old)", Return = Open New Room) or Disband it (a danger `meta` line, `button-danger` "Disband and
  Open New Room" with no Return shortcut). No Cancel once the room exists. Long names and errors stop at a few
  lines (full text in the tooltip) so both steps fit the 520 pt window minimum.
- **Bot sheets** (`sheet`, 460 pt): Edit shows the avatar preview (44 pt) with Choose Image… / Remove, Title
  (placeholder: the name the bot shows now) and Description, and an Advanced disclosure. With Advanced open the
  sheet is the main window's height less 80 pt (440 pt at the 520 pt minimum): the title stays on top, the
  fields scroll, and Cancel / Save stay pinned at the bottom. Each field's failure is a danger `meta` line under
  that field.
  Duplicate shows the running step, then the result with Open (primary). Delete names the profile folder in
  SF Mono, says "This cannot be undone." in danger, and its Delete Bot button is `button-danger` with no Return
  shortcut.
- **Settings window:** 420 pt wide and as tall as its content, so every section (General, Notifications,
  Background, Kanban dispatcher) is on screen without scrolling; it follows rows that come and go.
  Notifications is one switch, "Show notifications", with a footnote on what notifies and that only the
  packaged app can post them (a `swift run` build also says so in a muted info line).
- **Empty states** are centred in the pane, never pinned to the composer by a bottom-anchored scroll.
- **Window resize:** the detail pane flexes; bubbles and messages wrap within their max widths; the
  ribbon scrolls horizontally instead of wrapping; nothing clips at the 820 pt minimum. The sidebar
  drags 220–272 pt (its column is 8 pt wider): the widest 280 pt column plus the 540 pt detail
  minimum fills the 820 pt minimum exactly, so a sidebar dragged wide, or a window shrunk with a wide
  sidebar, never pushes the split past the window edge.

## Elevation & Depth

Depth is used for exactly three things, each with a reason:

- **Sidebar material** (system vibrancy): the single translucent element, it separates navigation from
  content the way every Mac app does. Content stays solid.
- **Action cards** sit 1 level up (`0 1px 2px` at 8% black plus a 1 px attention ring) because they
  are the only items in the timeline that wait for the user. Hover lifts nothing; the ring is the cue.
- **Sheets** use the system shadow; the mention popover uses `0 6px 14px` at 16% black.

Everything else is flat and separated by hairlines or surface tone. Hover states are a background tint
(`hover`; the danger button tints `danger-soft`), pressed states scale controls to 0.96.

## Shapes

Radius encodes role, smallest for the densest elements: inline code 4, controls 6, chips and code
blocks 8, avatars 8 (28 pt tile and up) and 5 (`avatar-small`, 18-20 pt tiles), action cards and the composer 10, bubbles 12 (the corner nearest the
sender is 4, pointing at who spoke), sheets 14. Nothing is pill-shaped except the 7 pt status dots.

## Components

- `avatar`: the profile's own avatar image from `profiles.get_asset {name, asset: "avatar"}`, fetched
  at runtime, drawn pixel-sharp (nearest-neighbour), cropped to the head, over a 22% tint of the bot
  colour. When the profile has no avatar the tile is a monogram: two initials in SF Pro Rounded on a
  subtle same-hue gradient that only darkens (base colour at the top, base mixed 14% with black at the
  bottom), so the fallback still has depth and the lightest pixel behind the white letters is the base
  colour itself: white on every tile stays at 5:1 or better over the whole glyph area, which a gradient
  lifted toward white did not (3.9-4.8:1 behind the letters, measured on rendered tiles). Sizes: 18 pass line,
  20 chip, 22 suggestion, 28 row and toolbar hero, 32 message, 36 inspector, 44 edit-sheet preview, 96 empty
  Bot Chat.
- `room-avatar-stack`: the first two members as 18 pt tiles in the 28 pt slot, the second offset 10 pt
  down-right. The back tile is cut out 1.5 pt around the front one (a real transparent gap, not a
  stroke in a guessed background colour), so it reads over the sidebar material and the toolbar and
  neither tile is clipped. A room with a local picture (room menu → Choose Picture…) shows that instead: one
  28 pt tile at the avatar radius with a hairline ring, in the toolbar and the sidebar row. Its tooltip in the
  toolbar lists the members that are not available and why.
- `sidebar-row`: avatar, title, subtitle; hover tint; the selection background is one shared shape that
  slides between rows. A room row puts the last message's age (caption, muted, `5m` / `3h` / `2d` / `Nov 3`)
  after its title and the last message ("Alpha: …", "You: …") as its subtitle, falling back to the members
  before any message. Its trailing slot holds the `needs-you` badge, else the breathing round dot; a pinned
  room (or bot) shows a muted `pin.fill` before it.
- `bot-row` (sidebar): avatar 28, title (`bodyMedium`; `bodyStrong` while unread) and the age of the bot's last
  activity (caption, muted, the room row's `5m` / `3h` / `2d` / `Nov 3`), then the last message (meta, muted; ink
  while unread; italic with "@sender: " when another bot sent it), falling back to the model or description.
  Trailing, in this order: the pin, the `needs-attention` badge, then the Bot Chat state (waiting count, the
  breathing reply dot) or the `unread-dot`.
- `unread-dot`: a static 7 pt graphite dot ("New activity"); the breathing dot stays "a reply runs". Never on
  the bot on screen.
- `needs-attention` badge: `exclamationmark.triangle.fill` in `attention` at icon-small size, tooltip with the
  fix ("Sign in again for this profile", "Quota or balance exhausted", "Provider not configured — run hermes
  model", "Bot is blocked — see its last message").
- `bot-section`: a 24 pt header (chevron, `folder` symbol, name in `captionStrong`, member count in caption,
  muted) that collapses the block on click and holds Rename Section…, Move Up, Move Down and Delete Section in
  its context menu (Unassigned has none). The block takes a dragged bot row (the drag preview is the bot's
  title); while one is over it the header, or an empty section's slot, fills `selected`. An empty section shows
  a dashed hairline slot, "Drag bots here" (meta, muted). After a delete, a meta line under the Bots header
  says what moved ("Deleted “Clients”: 2 bots moved to Unassigned") with an ink **Undo**; it goes after 8 s.
- `recent-session` sheet (560 × 440): header (avatar 28, the session's title in `title-pane`, "<bot> ·
  read-only · 3h ago" in meta muted), the transcript in the Bot Chat's message grammar (no composer), and a
  footer with "Read-only. Continue this conversation in Hermes Desktop or the CLI." and Close (primary).
- `needs-you` badge: a small `attention` capsule (soft fill, hairline ring) with an SF Symbol: `at` when a bot
  wrote `@user` that the user has neither answered nor seen, `hand.raised.fill` when a bot waits on an
  approval. Never on the room that is on screen.
- `thread-pane`: the room's inspector column shows an open thread instead of the Activity panel (Activity
  takes the column back and closes the thread): "Thread" (`title-pane`) + its first message (meta, muted) and
  a close button, the message the thread hangs off, a `round-divider` with the reply count, the thread's rows,
  and its own composer ("Reply in thread"). In the room timeline a thread message has a `thread-link` above it
  ("Thread · <first message>", caption muted, text-bubble symbol) and the message a thread hangs off has one
  below it ("2 replies ›"); both tint `hover` on hover and open the thread.
- `message-actions`: on hover, a strip of icon buttons over the message's top trailing corner (window fill,
  hairline ring, control radius, no shadow): Reply to @bot (`at`, bot messages), Reply in thread
  (`text.bubble`, not inside the thread pane) and Copy (`doc.on.doc`). The same actions are the message's
  context menu.
- `status-chip`: avatar 20, member name, state label. States come only from real room data: `waiting`
  (no terminal turn yet; bot-colour hairline at 45%), `replied` (ink label + checkmark), `passed` and
  `cancelled` (muted label, full opacity), `failed` (danger label, ring and symbol), `needs retry` and
  `needs approval` (attention fill, ring, semibold label and a symbol: the most urgent chip). A
  room-level chip leads the ribbon and is the only room-level working indicator: `Working · 1 running`,
  `Waiting for bots`, `Idle`, `Blocked` (danger ring).
- `message-member` / `message-user`: see Layout. Text is selectable and renders as markdown blocks:
  headings (h1 `title-state`, h2-h3 `title-pane`, deeper `body` 600), paragraphs (a single newline is a
  line break), bulleted and numbered lists (nested, muted markers), block quotes (hairline bar, muted
  text), horizontal rules, GFM tables (header in `body` 600, hairline rules between rows, chip-radius
  hairline frame, columns sized to their content, cells wrap) and fenced code as `code-block` (language
  label and Copy in a caption row, horizontal scroll). Raw HTML stays text. Links open only as http/https.
- `link` (`#0B63CE` light / `#6CB4FF` dark, ≥ 4.5:1 on window, surface and user bubble): the one blue in
  the app. Links in bot and user messages are `link` and underlined; a link that would not open (an
  autolinked `mailto:`) is plain text. In Group Chat, @mentions of room members (and @all / @everyone) are
  `link` at 600, `@user` is `attention` at 600; other @words stay ink.
- `bot-turn` (Bot Chat): only the first bot-side row of a turn carries the avatar and name; later text,
  Thought and tool rows of the same turn line up under it at the content inset.
- `thought-row`: "Thinking" (muted, mini spinner) and open while reasoning streams, as a 160 pt preview
  that keeps its latest lines in view; "Thought" and collapsed once the step ends or when loaded from
  history. Reasoning text is `meta`, muted, behind a hairline bar. The user's toggle wins.
- `tool-row` / `tool-group`: a tool call is a category glyph (spinner while running, danger cross when
  failed), a title in plain words ("Ran git status", "Ran code import json + 3 commands", "Read
  a.swift", or the connector label "Atlassian · getjiraissue"), then muted caption meta: a count from the
  result ("3 items", "360 stdout_bytes") and the duration. Click expands what it did: command or
  arguments, diff, output and exit code as `code-block`s (cut at 20,000 characters). Two or more adjacent
  calls fold into a `tool-group`: one muted summary line ("Ran 2 commands, used 1 tool"), collapsed by
  default; while a call runs, the collapsed line shows it after a mini spinner.
- `system-notice` (Bot Chat): a user-role row Hermes wrote itself (a control frame: `[IMPORTANT: …`,
  `[System: …`, `[CONTEXT SUMMARY]`, `[PRIOR CONTEXT`…, hermes-agent `CONTROL_FRAME_OPENERS`) is not a user
  bubble: one muted `meta` row on the content edge (info symbol, "Hermes note" at 600, the frame's first
  line, chevron), collapsed; a click shows the whole text behind a hairline bar, like a Thought. Only a
  message that starts with a frame counts, and frames that carry the user's words (the mid-turn steer
  marker, skill invocations) stay bubbles, so nothing a person typed is folded away.
- `action-card`: approval and retry, in the attention role. Approval: hand symbol, member avatar and
  "<member> needs your approval", the flagged reason (`description`), the exact command in a
  `code-block` under a "Command" label, then Approve once (`button-primary`) and Deny (`button-danger`).
  Both buttons share weight, height and a 72 pt minimum width, and Deny has a full danger ring, so the
  destructive choice is never visually smaller than the other. The approval payload carries no tool
  name (`command`, `description`, `pattern_key(s)`, `choices`, `request_id` only), so the card labels the
  block by what it holds instead of guessing a tool. The command is drawn verbatim in SF Mono; `Text`
  never substitutes characters, so `-` stays ASCII (SF Mono's hyphen is wide, not an en dash). Retry:
  explanation, Retry as `button-primary`. `action-card-failure` for failed turns.
- `note-bar`: the room's latest action result or error in plain words ("Approved once. The bot
  continues.", "Stop failed: …") above the composer; the raw log line is the tooltip. Errors use danger;
  a success note has a dismiss button.
- `media-thumb` / `media-chip`: files a bot sends as `MEDIA:<path>` tags, under the message text in Bot
  Chat and Group Chat. Images show inline as a thumbnail (fits 320×240 pt, never upscaled, chip radius);
  other files show as a chip (kind symbol, file name, size; max width 320 pt). Nothing opens without a
  click, and every Open / Reveal re-checks the path (`MediaSafety`): a missing or refused file shows a
  disabled chip with the reason. Context menu: Quick Look, Open, Reveal in Finder, Copy Path. A thumbnail click
  previews in Quick Look (the system panel, out of process); Space over a tile previews it unless a text field
  has focus; a checked tile drags out as its file (D8). Reveal-only formats are never previewed.
  Files the user sent in a room (the app's own copies) use the same tiles; a click opens Quick Look (formats
  that can run code are still only revealed); a deleted copy's chip reads "This copy was deleted, so the bots
  can no longer open it either."
- `palette` (⌘K Go to / ⇧⌘F Messages, D5/D10): a sheet 560 pt wide (`paletteWidth`) in the window fill: a
  borderless `title-pane` field with a leading muted symbol and a segmented scope picker (Tab switches), a
  hairline, then a 360 pt list (`paletteListHeight`) of 44 pt rows styled like `sidebar-row` (the keyboard
  selection takes `selected`, hover takes `hover`). Go to rows: kind symbol, title, muted subtitle, then
  `bell.slash` for a muted item and the `⌘n` caption it answers to. Message rows: "<chat> · <author>" in
  `meta` 600 muted over a two-line `body` snippet with the query terms in 600. Empty and too-short queries say
  so in one muted `meta` line.
- `template-sheet` (Save as Template, D13): a `sheetWidth` sheet like New Group Chat: name field, the members
  as one `body` line, an opening-prompt editor 96 pt high (`templatePromptHeight`, surface fill, hairline,
  control radius), Cancel and Save Template.
- Own window (D9): a Bot Chat or room window is the detail pane alone (no sidebar) at the main window's default
  size, with the same toolbar; a gone bot or room shows an `empty-state` ("Not available").
- `round-divider`: hairline, caption label, hairline; the two rules take equal widths so the label is
  centred on the timeline. Labels are plain words: "Discussion settled", "Discussion ended · round limit
  reached", "Stopped", "Renamed to …" (the backend `reason_code` stays in the log, not on screen).
- `composer`: surface box with focus ring in graphite; Send is `button-primary`; a hint row below shows
  the Return shortcut and, in Group Chat, the sync footer ("Synced 10:42:07 · every 5s · seq 12"). Typing
  `@` opens member suggestions above the box (click, or Tab for the first match); they only edit the
  draft (in Bot Chat, the other bots: `mention-suggestions`). In Bot Chat ↑ at the start of the text and ↓ at
  its end walk the user's earlier messages. In Bot Chat the button says what Return does: Send, Steer (a reply runs; ⌘Return queues), Queue
  (a reply runs that this chat cannot steer, or files are attached) or Save (a queued message is being
  edited). The row below leads with the chat's controls in `caption`, muted, hover tint: the model
  (name truncates in the middle, 150 pt cap), the reasoning effort (brain symbol + level, symbol only on a
  narrow row) and the context gauge (28 × 4 pt ink bar on a hairline track + percentage, `~` when
  estimated; click for the breakdown popover). Key hints drop first when the row is narrow. Status on the
  right: an action in flight, then "Compacting the conversation…", then "<bot> is replying".
- `queue-panel` (Bot Chat): above the composer, `surface` fill, card radius: a caption header ("2 queued",
  "· paused" after Stop, with Resume), then one row per message (two lines, `meta`) with Edit, Send now and
  Delete as 22 pt icon buttons; the row being edited has the `selected` fill and the graphite ring.
- `message-actions` (Bot Chat): hovering a message shows when it was sent (caption, muted: "3:27 PM",
  "Yesterday, 3:27 PM", "Sep 28, 3:27 PM"; the full date is the tooltip) and Copy (and Copy full response for a
  reply in several parts) at its top trailing corner on a `window` plate with a hairline; the same actions are
  in its context menu. A reply is timed from its completion.
- `turn-duration` (Bot Chat): under the last reply text of a turn watched from its start, a `timer` symbol and
  the duration ("12s", "2:05") in caption, muted. Not shown for history or a turn joined mid-way.
- `mention-suggestions` (Bot Chat): typing `@` lists the other bots (avatar 22, title, the `@tag` that will be
  inserted in meta muted, at most 8) in the Group Chat suggestion popover; click or Tab inserts. Tagged bots in
  the user's own messages are `link` at 600, as in Group Chat.
- `scroll-to-bottom` (Bot Chat): while the user is scrolled up, a capsule centred above the composer
  (`window` fill, hairline, popover shadow, caption): down arrow and "3 new messages", or "Scroll to bottom".
  Scales in from 0.96 with `ease`; muted label, ink on hover.
- `find-bar` (Bot Chat, ⌘F): a `surface` strip above the transcript with a hairline below: magnifier, the query
  field, "3 of 12" / "No results" (caption, muted, tabular), previous and next icon buttons and Done
  (`button-secondary`). Slides down from the top with `ease`.
- `empty-state`: SF Symbol (28 pt, muted), `title-state`, one sentence, optional primary action.
  Variants: connecting (with step list), connection failed (Try again), nothing selected, empty room,
  new 1:1 chat. The new 1:1 chat puts the bot's own face (96 pt) where the symbol goes, its name as the title,
  "Say something to get started." in body muted, and the shared-chat note in meta muted (Hermes Desktop's
  `chat-empty`).

### Motion

All motion is bound to a state change and keyed to the identity of the event that caused it (room id +
event seq, approval request id), so reopening a room, an identical poll, or toggling motion never
replays history. Motion never delays data or controls: rows, focus and Send/Stop/Approve eligibility
update immediately; only their appearance animates.

| Moment | Movement | SwiftUI |
|---|---|---|
| Switch room or bot | selection background slides between sidebar rows; detail fades in 12 pt | `matchedGeometryEffect`, `.transition(.move.combined(with: .opacity))` |
| New message | rises 10 pt and scales from 0.97, anchored to the sender side | `.transition(.scale(0.97, anchor:).combined(with: .opacity))` |
| Member passes | avatar pops into the aggregated pass line | `.transition(.scale)` |
| Ribbon status changes | the changed chip bounces once | `keyframeAnimator` keyed to the state |
| Approval needed | card arrives, one attention-colour ring ripple (0.45 s delay, 1.1 s), once per request id; gone in the same frame motion turns off, never replayed when it turns back on | `TimelineView(.animation)` progress from a start time keyed by request id |
| Round settles | divider rules draw outward from the centre | `.scaleEffect(x:)` transition |
| Room working | dots pulse; sidebar dot breathes while the round runs | `phaseAnimator` while `active` |
| Streaming 1:1 | text grows with an opacity content transition, caret blinks in the bot colour | `.contentTransition(.opacity)` |
| Sheets | the system slide and parent dimmer fade; with motion off the sheet and the dimmer appear and disappear in one frame, on open and on close | `motionSheet`: AppKit `beginSheet`/`endSheet`, run in a zero-duration `NSAnimationContext` when motion is off (SwiftUI `.sheet` cannot be gated) |
| Bot / card details inspector | the system slide; with motion off it opens and closes in one frame | `.inspector` bound to `@State` and toggled in a `disablesAnimations` transaction (an `@AppStorage` binding loses the transaction) |

Curves: spring `response 0.38, dampingFraction 0.72` for things that arrive; ease-out 0.25 s for state
changes. Everything above turns off when macOS Reduce Motion is on, and the in-app setting
(Settings, "Animate interface changes") turns it off independently.

The per-member "is typing" animation from the mockup is not used: `groups.state` reports working
counts for the room, not which member is generating, so the working indicator is room-level.

## Do's and Don'ts

- Do keep graphite as the only accent; let bot colours do the colouring. Attention (amber) and danger
  are status roles, not accents.
- Do draw disabled and de-emphasised states with tokens (soft fill, muted label), never with opacity.
- Do derive every chip state from `groups.log` / `groups.state`; never animate a member as active on a
  guess.
- Do give every list a loading, empty and error state.
- Do check new colours against both window colours (4.5:1 text, 3:1 large text).
- Don't add a second translucent surface; the sidebar is the one.
- Don't tint body text, buttons or icons with bot colours.
- Don't bundle avatar images; fetch them with `profiles.get_asset` and fall back to the monogram.
- Don't use emoji as icons; use SF Symbols that name the thing they mark.
