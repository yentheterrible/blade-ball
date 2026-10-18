# havoc public — blade ball pack

> public release client for roblox blade ball. built on top of the havoc ui framework with advanced auto parry, trajectory prediction, ping compensation, and lobby training support.

```text
language : luau
version  : auto-parry-1
status   : active
```

---

### quick start

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/yentheterrible/blade-ball/main/bladeball.luau"))()
```

---

### features

#### auto parry & lobby ap
- **match auto parry** : real-time automatic parry for live balls targeting you during active matches.
- **lobby ap** : fully autonomous parry loop for lobby training balls with independent state management.
- **custom keybinds** : toggleable hotkeys for both match auto parry and lobby ap.

#### trajectory & detection engine
- **fast & curving ball detection** : adds dynamic lead time (up to 100ms) for high-speed balls and predicts curved trajectories after sharp turns.
- **special ability detection** : selectively bypasses parry attempts when invulnerable or restricted states are active (death slash, infinity, singularity, time hole).
- **ping compensation** : adaptive lead calculations that dynamically adjust for latency spikes and network jitter (>100ms).

#### customization & fine-tuning
- **parry accuracy slider** : adjust timing tightness from early-biased parries (1%) to pixel-perfect frames (100%).
- **range multiplier** : expand allowed distance and timing window multipliers from 1x to 10x.
- **auto-configuration** : automatically saves and restores user preferences using local JSON storage (`HavocHub/default.json`).

#### developer tools & analytics
- **developer logging** : detailed console output tracking TTC (time-to-contact), speed, distance, range, and network latency.
- **death trace telemetry** : logs a frame-by-frame diagnostic trace upon player elimination to analyze missed timings or environment factors.

---

### tech & architecture

- **physics & contact solver** : quadratic contact solver incorporating radial closing speed and second-order acceleration curves.
- **cleanup & lifecycle safety** : automatically disconnects active RBXScriptSignals, clears coroutines, and removes debug visualization artifacts on script re-execution or close.
- **cross-platform input** : seamless mobile and desktop support using native mouse events and VirtualInputManager fallback dispatching.

---

### socials

- **discord** : [convictedx](https://discord.com/users/convictedx)
- **email** : [yenthet3rrible@gmail.com](mailto:yenthet3rrible@gmail.com)
- **github** : [@yentheterrible](https://github.com/yentheterrible/blade-ball)
