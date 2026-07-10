# IDEAS -- Long-Term Features & Future Directions

## Messaging Integration: Telegram Bot API

### Concept
Two-way messaging bridge between the agent framework and the user's phone via Telegram Bot API. Enables remote notifications from continuous agents and remote control of agents via text replies.

### Why Telegram
- Bot API is HTTP POST -- no SDK, no library, no OAuth. `curl -d "message" https://api.telegram.org/bot<TOKEN>/sendMessage?chat_id=<CHAT_ID>`
- Two-way: bot can send AND receive messages via long polling (`getUpdates`). No inbound port, no server, no NAT traversal. Perfect for a laptop that changes networks.
- Free: bot tokens from BotFather, no per-message cost.
- Excellent phone app with push notifications.
- Emacs integration is trivial: two curl calls, ~50 lines of elisp.

### Alternatives considered
| Platform | Verdict |
|----------|---------|
| ntfy.sh | Simpler, one-way push only. Could complement Telegram for urgent alerts. |
| Matrix (ement.el) | Most Emacs-native, self-hostable, but heavy setup. Overkill for messaging. |
| Signal | signal-cli is Java, heavy, fragile. Not worth it. |
| Email | Wrong medium. High latency, cluttered, no push. |
| IRC (erc/circe) | Built into Emacs but IRC on phone is terrible for notifications. |
| SMS (Twilio) | Works but costs money. Telegram is free. |

### Design sketch

#### Module: `telegram_notify.el`
- `defcustom my-gptel-telegram-bot-token` -- from BotFather
- `defcustom my-gptel-telegram-chat-id` -- user's chat ID (get from first message)
- `my-gptel-telegram-send (message)` -- POST to sendMessage API, returns success/error
- `my-gptel-telegram-read (&optional since)` -- GET from getUpdates API, returns new messages since offset
- `my-gptel-telegram-poll` -- timer-based polling for incoming messages

#### Tools for agents
- `send_message` -- agent sends a message to user's Telegram. Used by continuous agents for noteworthy events, long-running delegates for completion notifications.
- `read_messages` -- agent polls for user replies. Continuous agent checks at start of each tick: "did the user respond? If so, incorporate their instruction."

#### Integration points
- **Continuous agents (Phase 6):** Gardener finds failing test -> sends Telegram -> user replies "delegate to coder" -> next tick reads reply, delegates to coder.
- **Long-running delegates (Phase 4):** Async delegate finishes -> sends Telegram notification with summary.
- **Token budget (Phase 3):** Cloud budget running low -> sends Telegram warning.
- **Remote execution (Phase 1):** Remote command fails or produces output -> sends Telegram with results.

### The vision
Once two-way messaging exists, continuous agents become remotely controllable. You're away from your desk, the gardener finds a problem, sends you a message, you reply with instructions, and by the time you return the work is done. The agent framework becomes a mobile-accessible autonomous system.

### Prerequisites (when we get here)
- [ ] Create Telegram bot via BotFather, get token
- [ ] Get chat ID (send a message to the bot, read update payload)
- [ ] Verify curl works from Emacs container to api.telegram.org

### Priority
Long-term. Build after core features (Phases 1-6) are polished. Most relevant once continuous agents are working and we move to UI/UX refinement. The integration itself is trivial -- the value depends on having agents worth notifying about.
---

## Physical Status Display: NeoPixel LED Strip via Raspberry Pi Pico 2 W

### Concept
100-LED WS2812 strip driven by a Raspberry Pi Pico 2 W, acting as a physical status display for the agent framework. The Pico accepts state updates over WiFi and renders them as light. The first real use case for a continuous agent (Phase 6) -- a "monitor" agent that polls infrastructure and pushes LED updates every few seconds.

### Hardware
- Raspberry Pi Pico 2 W (WiFi capable)
- Two separate LED channels:
  - Channel 1: 610 LEDs (room illumination, not part of this project)
  - Channel 2: ~100 LEDs (status display, this project)
- WS2812 / NeoPixel addressable LEDs

### Layout: 4 zones of 25 LEDs

#### Zone 1 (LEDs 1-25): Tier health bars
- 25 LEDs split across 4 tiers (roughly 6 each)
- Each tier: brightness = alive/dead, color = load
  - Green: healthy, low load
  - Yellow: moderate load
  - Red: overloaded or unreachable
  - Off: server down
- Tier 1 (local): CPU usage of Emacs container
- Tier 2 (0b.ar): CPU usage (via SSH)
- Tier 3 (3080): GPU utilization (via Ollama `/api/ps`) -- you can *see* a model loading
- Tier 4 (cloud): green if budget remaining, yellow if >75% used, red if exhausted

#### Zone 2 (LEDs 26-50): Agent activity
- 7 agents, ~3-4 LEDs each
- Each agent's LEDs light up when it's actively generating (inference in progress)
- Color by agent: mccarthy=blue, coder=green, reviewer=yellow, researcher=purple, finch=cyan, machine=white, ouroboros=orange
- Dim when idle, bright when working, pulsing when delegated
- Glance up and see which agents are alive

#### Zone 3 (LEDs 51-75): Cloud token budget
- 25 LEDs as a fuel gauge
- Full green = budget full, drains toward red as the week progresses
- When it hits zero: all red, blinking
- Changes your behavior -- you see the gauge dropping and think about whether to delegate to the researcher

#### Zone 4 (LEDs 76-100): Event log / pulse
- Rolling display of recent events
- A new event (delegate spawned, test failed, continuous agent tick) sends a pulse of light scrolling across the zone
- Color by event type: blue=delegate, green=success, red=failure, yellow=warning, white=continuous tick
- Fades after a few seconds, leaving the zone dark until the next event
- Peripheral awareness without reading anything

### Architecture

#### Pico 2 W side
- MicroPython HTTP server (simplest) or C with lwIP (faster, more reliable)
- One endpoint: `POST /leds` accepts a JSON array of 100 `[r, g, b]` tuples
- Or higher-level: `POST /state` accepts a JSON state object and the Pico renders it itself
- Drives the strip via WS2812 library
- **Fallback pattern:** if no data received in N seconds, switches to slow breathing on all LEDs -- so you can tell the framework is down vs. the strip is down
- **Autonomous error detection:** if a tier goes unreachable, the Pico can hold that zone red even without Emacs updating it (in higher-level mode)

#### Two protocol modes

**Raw mode** (Emacs renders, Pico just drives):
```json
{
  "leds": [
    [0, 255, 0], [0, 255, 0], ...
  ],
  "brightness": 128
}
```

**High-level mode** (Pico renders, Emacs sends state):
```json
{
  "tiers": [
    {"name": "local",   "status": "ok",    "load": 0.3, "agents": ["mccarthy"], "continuous": ["monitor"]},
    {"name": "0b.ar",   "status": "ok",    "load": 0.15, "containers": 3},
    {"name": "3080",    "status": "ok",    "load": 0.6, "vram": 0.8, "gpu_active": true},
    {"name": "cloud",   "status": "ok",    "budget": 0.72, "active": false}
  ],
  "events": ["delegate:coder->3080", "tick:gardener"]
}
```

High-level mode is better -- the Pico handles rendering (pulses, transitions, color interpolation) and Emacs doesn't need to compute 100 RGB values every tick. Emacs sends state, Pico sends photons.

#### Emacs side
- `status_leds.el` -- a timer (or continuous agent) that fires every 1-2 seconds
- Collects state:
  - `execute_code_local` for local CPU
  - SSH to 0b.ar for remote CPU and container count
  - curl to Ollama `/api/ps` for GPU/VRAM stats
  - Token budget file for cloud usage
  - `my-gptel--async-tasks` and gptel buffer state for active agents
- Builds state JSON, sends one HTTP POST to the Pico
- Hooks into `gptel-post-response-functions` to trigger event pulses in zone 4

#### Data flow
```
Continuous "monitor" agent (ticks every 2-5s)
  -> Gather: CPU (local), CPU (0b.ar via SSH), GPU (Ollama /api/ps),
            cloud budget (file), active agents (gptel state)
  -> Build state JSON
  -> curl POST to Pico HTTP endpoint
  -> Pico renders state to LEDs
```

#### Event pulses (zone 4)
- Triggered by gptel hooks, not just the timer
- `gptel-post-response-functions` -> delegate completed -> green pulse scrolls across zone 4
- Continuous agent tick -> white pulse
- Test failure on 0b.ar -> red pulse
- Working in Emacs, see a red flash peripherally -- know something happened without switching buffers

### Why this is the perfect first continuous agent

1. **Read-only.** The monitor agent only polls and pushes. It never modifies the codebase, never delegates, never makes decisions. Zero risk. If it breaks, the LEDs go dark. Nobody dies.
2. **Proves the loop.** It exercises the entire continuous agent pipeline: timer, spawn, prompt construction from state, autonomous execution, output capture, repeat. If this works, the gardener and watcher are just different prompts on the same machinery.
3. **Immediate feedback.** You see it working. No need to check logs or buffers. The lights are on or they're not. The bars move or they don't. This is rare in software -- a feature where verification is literally looking at it.
4. **Useful from day one.** Even before the rest of the framework is built, the LED display tells you whether your servers are up and how loaded they are. It's infrastructure monitoring that happens to be driven by the agent framework.

### Philosophical note
Every machine room in the 1960s had physical indicator lights. You could walk past a PDP-6 and know what it was doing without reading a printout. We replaced those with log files and buried them in tmux panes. This puts them back. McCarthy's time-sharing system had a console with lights. The operators knew the system's state by glancing at it. We lost that when we moved to headless servers. You're getting it back with addressable LEDs.

### Prerequisites (when we get here)
- [ ] Pico 2 W running HTTP server, driving the 100-LED strip
- [ ] Verify WiFi connectivity from Pico to the local network
- [ ] Verify curl can reach Pico from Emacs container
- [ ] Decide: MicroPython vs C SDK for Pico firmware
- [ ] Decide: raw mode vs high-level mode (recommend high-level)
- [ ] Continuous agent infrastructure (Phase 6) in place

### Files
- `/root/.emacs.d/init.d/status_leds.el` -- Emacs-side state collection and push
- `agents.d/monitor/prompt.org` -- continuous agent profile for the monitor
- Pico firmware (separate repo or directory, not in .emacs.d)

### Priority
Medium. Becomes the first test case for Phase 6 (continuous agents). Build after or alongside Phase 6. The Pico firmware can be developed independently of the Emacs side.