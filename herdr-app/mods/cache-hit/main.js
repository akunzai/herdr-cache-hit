// Experimental Herdr App (GUI) front end for the cache-hit plugin.
// Install: scripts/install-herdr-app-mod.sh (copies this folder and records the checkout).
// Every 15 s it runs watch.sh through scripts/herdr-app-shim.sh, then shows
// the metadata the shim stored for each agent terminal. Display only: the
// shim refuses to type into terminals, so the cache warmer cannot run here.
import { View, div } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { agents, appHome, exec, home, readTextFile, run, setShared, shared, theme } from "herdr";

const SCAN_MS = 15000;
// Separate from a Herdr TUI install of the plugin: pane ids, locks and timers differ.
const STATE_DIR = ".local/state/herdr/plugins/cache-hit-app";
// Its own config too, so settings for a Herdr TUI install do not apply here.
const CONFIG_DIR = ".config/herdr/plugins/config/cache-hit-app";

export default class CacheHit extends View {
  init(_props, cx) {
    this.meta = {};
    this.error = null;
    cx.spawn(async (cx) => {
      // The installer records where the plugin checkout lives.
      const dir = `${appHome()}/mods/cache-hit`;
      this.root = (await readTextFile(`${dir}/plugin-root`))?.trim() || null;
      // Windows: the Git Bash and tool folders the installer found.
      this.bash = (await readTextFile(`${dir}/bash-path`))?.trim() || null;
      this.path = (await readTextFile(`${dir}/runtime-path`))?.trim() || "";
      if (!this.root) this.error = "plugin-root missing: run scripts/install-herdr-app-mod.sh";
      this.scan(cx);
    });
    cx.timer.every(SCAN_MS, (cx) => this.scan(cx));
  }

  // The plugin's environment, pointed at Herdr App.
  env() {
    return [
      `HERDR_BIN_PATH=${this.root}/scripts/herdr-app-shim.sh`, "HERDR_NO_TIMER=1",
      `HERDR_PLUGIN_STATE_DIR=${home()}/${STATE_DIR}`,
      `HERDR_PLUGIN_CONFIG_DIR=${home()}/${CONFIG_DIR}`,
    ];
  }

  // Runs a plugin script with env(). Windows has no `env` on Herdr App's PATH,
  // so start the recorded Git Bash and put the tool folders first.
  bashExec(vars, script, args = []) {
    if (this.bash) {
      return exec(this.bash, ["-c", 'PATH="$1:$PATH"; shift; exec env "$@"', "cache-hit",
        this.path, ...vars, "bash", script, ...args], { cwd: this.root });
    }
    return exec("env", [...vars, "sh", `${this.root}/scripts/run-bash.sh`, script, ...args], { cwd: this.root });
  }

  scan(cx) {
    if (!this.root || this.busy) return;
    this.busy = true;
    cx.spawn(async (cx) => {
      try {
        const r = await this.bashExec(this.env(), `${this.root}/watch.sh`);
        this.error = r.code === 0 ? null : (r.stderr.trim() || `watch.sh exited ${r.code}`);
        const dir = `${home()}/${STATE_DIR}/app-metadata`;
        const meta = {};
        for (const a of agents()) {
          const text = await readTextFile(`${dir}/${a.address}.json`);
          if (text) try { meta[a.address] = JSON.parse(text); } catch {}
        }
        this.meta = meta;
        this.publish(meta);
      } catch (e) {
        this.error = String(e);
      }
      this.busy = false;
      cx.notify();
    });
  }

  // Other mods (e.g. a cloned Agents sidebar) read shared("cache-hit").
  publish(meta) {
    const panes = {};
    for (const [address, m] of Object.entries(meta)) {
      const tok = m.tokens ?? {};
      if (!tok.cache) continue;
      panes[address] = { cache: tok.cache, state: tok.cache_state ?? null, deadline: Number(tok.cache_deadline) || null, expires_ms: m.expires_ms };
    }
    const value = { panes };
    if (JSON.stringify(shared("cache-hit")) !== JSON.stringify(value)) setShared("cache-hit", value);
  }

  render() {
    const t = theme();
    const now = Date.now();
    const color = { hot: t.done, expiring: t.blocked, unknown: t.dim, cold: t.dim };
    const rows = agents().map((a) => {
      const m = this.meta[a.address];
      const tok = m && m.expires_ms > now ? m.tokens : {};
      const remaining = Number(tok.cache_remaining_secs);
      const deadline = Number.isFinite(remaining) && remaining > 0 ? remaining : Infinity;
      return { a, tok, deadline };
    }).sort((x, y) => x.deadline - y.deadline);
    return v_flex().size_full().bg(t.chrome).p(10).gap(4).text_size(12.5).text_color(t.foreground)
      .child(div().text_color(t.muted).text_size(11).child("PROMPT CACHE"))
      .when(Boolean(this.error), (el) => el.child(div().text_color(t.blocked).child(this.error)))
      .children(rows.map(({ a, tok }) =>
        h_flex().id(`c-${a.address}`).gap(8).px(6).py(3).rounded(5).justify_between()
          .hover((s) => s.bg(t.hover))
          .on_click(() => run("agent.focus", { terminal: a.address }))
          .child(v_flex().flex_1().min_w(0)
            .child(div().truncate().child(`${a.space_name} / ${a.tab_name || a.tab_index}`))
            .child(div().truncate().text_color(t.dim).text_size(11).child(`${a.app ?? "agent"} · ${a.address}`)))
          .child(div().text_color(color[tok.cache_state] ?? t.dim).child(tok.cache ?? "–"))));
  }
}
