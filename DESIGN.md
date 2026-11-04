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
  ribbon chip. It is the one warm hue in the chrome so the state that blocks a bot is the most urgent
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
- **Sidebar:** Group Chats first (the main work), then Bots. Rows are 44 pt high: avatar (or the room's
  two-avatar stack), title, one muted subtitle line. A breathing dot marks a room whose round is
  running. Footer: connection dot plus the backend in two or three words ("Hermes Desktop", "hermes
  serve", "Private hermes serve") so it never truncates at the 220 pt minimum; the full mode is the
  tooltip.
- **Group Chat:** toolbar (room name + member count, Stop, room menu), turn ribbon, timeline, note bar,
  composer. Member messages are not bubbled: avatar + coloured name + text at reading width (max
  720 pt), which keeps long answers comfortable. The user's messages are right-aligned soft bubbles (max
  520 pt). Action cards (approval, retry) start on the content edge and are capped at 560 pt. Room-level
  "working" is said once, by the ribbon's room chip; the timeline does not repeat it.
- **Bot Chat:** toolbar (avatar hero + name + model, detail toggle), timeline in the same message
  grammar, composer, and a native inspector (240 pt, resizable 200–260 pt): identity header (name,
  @handle, a "Default profile" tag when it is the default), then About, Model, Provider, Skills. The
  @handle is the profile name, so no separate Profile field repeats it. The inspector state is
  remembered. The chat column has no minimum width of its own: it takes what the sidebar and the
  inspector leave (312 pt at the 820 pt minimum with default column widths). The inspector's 260 pt
  maximum is what still fits at the 820 pt minimum next to a 280 pt sidebar column, so dragging it
  wide, or shrinking a window with a wide inspector, never pushes it past the window edge.
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
  20 chip, 22 suggestion, 28 row and toolbar hero, 32 message, 36 inspector, 44 new-chat empty state.
- `room-avatar-stack`: the first two members as 18 pt tiles in the 28 pt slot, the second offset 10 pt
  down-right. The back tile is cut out 1.5 pt around the front one (a real transparent gap, not a
  stroke in a guessed background colour), so it reads over the sidebar material and the toolbar and
  neither tile is clipped.
- `sidebar-row`: avatar, title, subtitle; hover tint; the selection background is one shared shape that
  slides between rows.
- `status-chip`: avatar 20, member name, state label. States come only from real room data: `waiting`
  (no terminal turn yet; bot-colour hairline at 45%), `replied` (ink label + checkmark), `passed` and
  `cancelled` (muted label, full opacity), `failed` (danger label, ring and symbol), `needs retry` and
  `needs approval` (attention fill, ring, semibold label and a symbol: the most urgent chip). A
  room-level chip leads the ribbon and is the only room-level working indicator: `Working · 1 running`,
  `Waiting for bots`, `Idle`, `Blocked` (danger ring).
- `message-member` / `message-user`: see Layout. Text is selectable; markdown inline styles render,
  fenced code renders as `code-block` with horizontal scroll.
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
- `round-divider`: hairline, caption label, hairline; the two rules take equal widths so the label is
  centred on the timeline. Labels are plain words: "Discussion settled", "Discussion ended · round limit
  reached", "Stopped", "Renamed to …" (the backend `reason_code` stays in the log, not on screen).
- `composer`: surface box with focus ring in graphite; Send is `button-primary`; a hint row below shows
  the Return shortcut and, in Group Chat, the sync footer ("Synced 10:42:07 · every 5s · seq 12"). Typing
  `@` opens member suggestions above the box (click, or Tab for the first match); they only edit the
  draft.
- `empty-state`: SF Symbol (28 pt, muted), `title-state`, one sentence, optional primary action.
  Variants: connecting (with step list), connection failed (Try again), nothing selected, empty room,
  new 1:1 chat.

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
| Bot details inspector | the system slide; with motion off it opens and closes in one frame | `.inspector` bound to `@State` and toggled in a `disablesAnimations` transaction (an `@AppStorage` binding loses the transaction) |

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
