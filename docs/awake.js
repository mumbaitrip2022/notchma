/* Keep Awake scene: scroll drives one night. 0 to .14 lid open and ready,
   .14 to .34 the lid closes, .36 to .8 the night races by while agents ship,
   .8 to 1 dawn, work's done, the Mac naps. */
(() => {
  "use strict";
  const sec = document.getElementById("awake");
  if (!sec) return;
  const $ = (id) => document.getElementById(id);
  const track = $("awkTrack"), lid = $("awkLid"), isle = $("awkIsle"), cap = $("awkCap");
  const tx = isle.querySelector(".awk-tx"), ic = $("awkIc").querySelector("img");
  const mac = sec.querySelector(".awk-mac");
  const still = matchMedia("(prefers-reduced-motion: reduce)").matches;

  // Stars: two box-shadow layers, placed the same way on every visit.
  const stars = (el, n, seed) => {
    let s = seed;
    const r = () => (s = (s * 16807) % 2147483647) / 2147483647;
    const out = [];
    for (let i = 0; i < n; i++) {
      out.push(`${(r() * 100).toFixed(2)}vw ${(r() * 72).toFixed(2)}vh 0 ${r() < 0.12 ? 0.6 : 0}px rgba(255,255,255,${(0.3 + r() * 0.7).toFixed(2)})`);
    }
    el.style.boxShadow = out.join(",");
  };
  stars($("awkStars"), 110, 7);
  stars($("awkStars2"), 70, 91);

  const clamp = (v) => Math.min(1, Math.max(0, v));
  const seg = (p, a, b) => clamp((p - a) / (b - a));
  const ease = (t) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);

  const AG = { claude: "images/agents/claude.svg", codex: "images/agents/codex.png", cursor: "images/agents/cursor.png" };
  // What the island says through the night: [agent, title, detail].
  const NIGHT = [
    ["claude", "Lid closed. Still going.", "claude · npm test 148/212"],
    ["claude", "212 tests passed", "claude · checkout refactor done ✓"],
    ["codex", "Codex picked up the next one", "codex · fixing the flaky login test"],
    ["codex", "Pushed to main", "codex · CI is on it, 8 jobs"],
    ["cursor", "CI all green", "cursor · polishing the empty states"],
    ["cursor", "Last task wrapped", "cursor · 4 of 4 shipped"],
  ];
  const CAPS = {
    ready: "Your agents are mid-task. Flip one switch.",
    closing: "Close the lid. Go live your life.",
    night: "Lid shut, fans chill, agents cooking.",
    done: "Work's done, so it naps. Like a responsible adult.",
  };

  let state = "", line = -1, last = { tasks: -1, tests: -1 };

  const say = (el, text, swapEl = el) => {
    if (el.textContent === text) return;
    if (still) { el.textContent = text; return; }
    swapEl.classList.add("swap");
    setTimeout(() => { el.textContent = text; swapEl.classList.remove("swap"); }, 180);
  };
  const island = (agent, title, detail) => {
    if (still) { ic.src = AG[agent]; $("awkT").textContent = title; $("awkS").textContent = detail; return; }
    tx.classList.add("swap");
    setTimeout(() => { ic.src = AG[agent]; $("awkT").textContent = title; $("awkS").textContent = detail; tx.classList.remove("swap"); }, 200);
  };
  const bump = (el, v) => {
    el.textContent = v;
    if (still) return;
    el.classList.remove("bump"); void el.offsetWidth; el.classList.add("bump");
  };

  function render(p) {
    const close = ease(seg(p, 0.14, 0.34));
    const night = seg(p, 0.36, 0.8);
    const dawn = ease(seg(p, 0.78, 0.95));
    sec.style.setProperty("--close", close.toFixed(4));
    sec.style.setProperty("--night", night.toFixed(4));
    sec.style.setProperty("--dawn", dawn.toFixed(4));
    lid.style.setProperty("--lid", `${(10 - 99.5 * close).toFixed(2)}deg`);

    // 11:42 PM to 6:58 AM.
    const mins = Math.round(23 * 60 + 42 + night * (7 * 60 + 16));
    const h24 = Math.floor(mins / 60) % 24, m = mins % 60;
    $("awkClock").textContent = `${h24 % 12 || 12}:${String(m).padStart(2, "0")}`;
    $("awkAmpm").textContent = h24 >= 12 ? "PM" : "AM";

    const tasks = [0.18, 0.42, 0.66, 0.9].filter((t) => night >= t).length;
    const tests = Math.round(212 * ease(seg(night, 0.04, 0.24)) + 96 * ease(seg(night, 0.5, 0.74)));
    if (tasks !== last.tasks) { last.tasks === -1 ? ($("awkTasks").textContent = tasks) : bump($("awkTasks"), tasks); last.tasks = tasks; }
    if (tests !== last.tests) { $("awkTests").textContent = tests; last.tests = tests; }

    const s = p < 0.14 ? "ready" : p < 0.36 ? "closing" : dawn < 0.35 ? "night" : "done";
    if (s !== state) {
      state = s;
      isle.dataset.s = s;
      say(cap, CAPS[s]);
      if (s === "ready") { line = -1; island("claude", "Ready to close the lid", "claude · refactoring checkout"); }
      if (s === "closing") { line = -1; island("claude", "Keeping your Mac up", "lid can close, agents keep going"); }
      if (s === "done") { line = -1; island("claude", "All done. Napping now", "4 tasks shipped while you slept 💤"); }
    }
    if (s === "night") {
      const n = Math.min(NIGHT.length - 1, Math.floor(night * NIGHT.length));
      if (n !== line) { line = n; island(...NIGHT[n]); }
      isle.style.setProperty("--ring", ((night * NIGHT.length) % 1).toFixed(3));
    } else {
      isle.style.setProperty("--ring", s === "done" ? 1 : 0);
    }
  }

  const fit = () => {
    const s = Math.max(0.45, Math.min(1.1, (innerHeight - 440) / 400, (innerWidth - 32) / 470));
    mac.style.setProperty("--s", s.toFixed(3));
  };
  fit();
  addEventListener("resize", fit);

  if (still) {
    sec.classList.add("still");
    render(0.6);
    return;
  }

  let ticking = false, near = false;
  const update = () => {
    ticking = false;
    const r = track.getBoundingClientRect();
    render(clamp(-r.top / Math.max(1, r.height - innerHeight)));
  };
  const onScroll = () => { if (near && !ticking) { ticking = true; requestAnimationFrame(update); } };
  new IntersectionObserver(([e]) => { near = e.isIntersecting; if (near) onScroll(); }, { rootMargin: "200px 0px" }).observe(track);
  addEventListener("scroll", onScroll, { passive: true });
  addEventListener("resize", onScroll);
  render(0);
})();
