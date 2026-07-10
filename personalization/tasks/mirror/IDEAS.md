# IDEAS

## Messaging Integration: Telegram Bot API

Two-way messaging bridge between the agent framework and the user's phone via Telegram Bot API. Enables remote notifications from continuous agents and remote control of agents via text replies.

- Bot API is HTTP POST -- no SDK, no library, no OAuth. Two curl calls, ~50 lines of elisp.
- Two-way: bot can send AND receive via long polling (`getUpdates`). No inbound port, no NAT traversal.
- Free: bot tokens from BotFather, no per-message cost.
- Alternatives considered: ntfy.sh (one-way only), Matrix (overkill), Signal (fragile Java CLI), Email (wrong medium), IRC (terrible on phone), SMS/Twilio (costs money).

### Integration points
- Continuous agents: Gardener finds failing test -> sends Telegram -> user replies -> next tick reads reply
- Long-running delegates: async delegate finishes -> sends Telegram notification
- Token budget: cloud budget running low -> sends Telegram warning
- Remote execution: command fails or produces output -> sends Telegram with results

### The vision
Once two-way messaging exists, continuous agents become remotely controllable. You're away from your desk, the gardener finds a problem, sends you a message, you reply with instructions, and by the time you return the work is done.

### Prerequisites
- [ ] Create Telegram bot via BotFather, get token
- [ ] Get chat ID (send message to bot, read update payload)
- [ ] Verify curl works from Emacs container to api.telegram.org

### Priority
Long-term. Build after core features (Phases 1-6) are polished. Most relevant once continuous agents are working.

---

## Physical Status Display: NeoPixel LED Strip via Raspberry Pi Pico 2 W

100-LED WS2812 strip driven by a Raspberry Pi Pico 2 W, acting as a physical status display for the agent framework. The Pico accepts state updates over WiFi and renders them as light. The first real use case for a continuous agent -- a "monitor" agent that polls infrastructure and pushes LED updates.

### Layout: 4 zones of 25 LEDs
- **Zone 1 (1-25):** Tier health bars. Green/yellow/red by load. Tier 1 (local CPU), Tier 2 (0b.ar CPU), Tier 3 (3080 GPU), Tier 4 (cloud budget).
- **Zone 2 (26-50):** Agent activity. LEDs light up when agent is actively generating. Color by agent. Dim when idle, bright when working, pulsing when delegated.
- **Zone 3 (51-75):** Cloud token budget fuel gauge. Full green = budget full, drains toward red. All red blinking when empty.
- **Zone 4 (76-100):** Event log / pulse. New events send a pulse of light scrolling across. Color by event type: blue=delegate, green=success, red=failure, yellow=warning, white=continuous tick. Fades after a few seconds.

### Architecture
- Pico 2 W: MicroPython HTTP server or C with lwIP. One endpoint: `POST /state` accepts JSON state object, Pico renders it.
- Emacs side: `status_leds.el` timer fires every 1-2 seconds, collects state (CPU, GPU, budget, active agents), builds JSON, POSTs to Pico.
- Fallback: if no data received in N seconds, Pico switches to slow breathing -- so you can tell the framework is down vs the strip is down.
- High-level mode recommended: Pico handles rendering (pulses, transitions, color interpolation), Emacs sends state, Pico sends photons.

### Why this is the perfect first continuous agent
1. Read-only. Zero risk. If it breaks, the LEDs go dark. Nobody dies.
2. Proves the entire continuous agent pipeline: timer, spawn, prompt construction, autonomous execution, output capture, repeat.
3. Immediate feedback. You see it working. The lights are on or they're not.
4. Useful from day one. Infrastructure monitoring driven by the agent framework.

### Prerequisites
- [ ] Pico 2 W running HTTP server, driving 100-LED strip
- [ ] Verify WiFi connectivity from Pico to local network
- [ ] Verify curl can reach Pico from Emacs container
- [ ] Continuous agent infrastructure (Phase 6) in place

### Priority
Medium. Becomes the first test case for Phase 6 (continuous agents). Pico firmware can be developed independently.

---

## Framework Improvements (Post-CTF, from finch)

- Consider a "frozen" mode for CTFs where file modification tools (`write_file`, `replace_in_file`) are disabled entirely
- Explore sandboxed execution -- separate the AI's reasoning context from its execution context to reduce prompt injection surface
- Evaluate per-agent network policies -- different agents may need different network access levels
- Create a FLAGS.md collection point -- single file where the AI writes captured flags with challenge name and timestamp

---

## ignisp Hardware Path (from ignisp agent)

The FPGA/ASIC goal is real. Design decisions should keep this possible (minimal reducer, lambda calculus terms, graph reduction) without over-constraining the language for current hardware.

- Phase 7 (long-term dream): implement reducer in Verilog, run on FPGA
- Graph reduction on FPGA is a well-studied technique
- In 10-20 years, potentially a custom ASIC
- The reducer is small enough to implement in Verilog (~300-500 lines of C today, similar complexity in Verilog)
