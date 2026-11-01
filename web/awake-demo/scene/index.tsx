import { useEffect, useRef, type CSSProperties, type ReactNode } from 'react'
import { BatteryMedium, Check, ChevronLeft, Coffee, Laptop, Moon, Plus, Settings, Wifi } from 'lucide-react'
import { Stage } from '../kit/stage'
import type { Act } from '../kit/act'
import { Bar, Caret, Prompt, Window } from '../kit/window'
import { Camera } from '../kit/motion/Camera'
import { Collapse } from '../kit/motion/Collapse'
import { Roll } from '../kit/motion/Roll'
import { Swap } from '../kit/motion/Swap'
import { Spinner } from '../kit/parts/Spinner'
import { Toggle } from '../kit/controls/Toggle'
import claude from './claude.svg'
import codex from './codex.png'
import appIcon from './notchbar.png'
import './keep-awake.css'

// Why Keep Awake exists, on a MacBook Pro, in two acts.
//
// Act 1, without it: Claude is mid-task, the lid closes, the Mac sleeps.
//   The night races by and nothing moves. Next morning the tests are still
//   at 148/212.
// Act 2, with it: the pointer opens the notch, taps the cup, flips "Keep
//   going with the lid closed" and types the password once. The lid closes
//   and the night races by again, but the agents keep shipping. Morning:
//   "All done. Napping now".
// The Mac napping (the screen going black) is the cut between the acts.
//
// The notch is the MacBook's real one: NotchBar grows out of it, keeps its
// words clear of the camera, and is one black shape whose box springs
// between bar, home, the Keep Awake page and done, with content on its own
// layer (dynamic-island).

type Mode = 'bar' | 'home' | 'page' | 'done'
type S = {
  act: 1 | 2
  mode: Mode
  closed: boolean
  screen: boolean
  hour: number
  step: number
  froze: boolean
  sw: boolean
  auth: boolean
  dots: number
  pending: boolean
  ready: boolean
  dawn: boolean
}

const START: S = { act: 1, mode: 'bar', closed: false, screen: true, hour: 0, step: 0, froze: false, sw: false, auth: false, dots: 0, pending: false, ready: false, dawn: false }
const ACT2: S = { ...START, act: 2 }
const POSTER: S = { ...ACT2, sw: true, ready: true, closed: true, hour: 3, step: 3 }

const CLOCK = ['11:43', '12:37', '1:58', '3:15', '4:41', '5:52', '6:58']
const ampm = (h: number) => (h === 0 ? 'PM' : 'AM')

// What NotchBar reports through the night in act 2, one per clock step
const FEED: { icon: string; text: string }[] = [
  { icon: claude, text: 'claude · running the tests' },
  { icon: claude, text: 'claude · 212 tests passed' },
  { icon: claude, text: 'claude · pushed to main' },
  { icon: codex, text: 'codex · took the next task' },
  { icon: codex, text: 'codex · CI all green' },
  { icon: codex, text: 'codex · last task wrapped' },
  { icon: codex, text: 'codex · last task wrapped' },
]

// ---- geometry, in the wide design's px ----
const LID = { x: 90, y: 40, w: 860, h: 560 }
const BEZEL = { side: 12, top: 12, chin: 26 }
const SCREEN = { w: LID.w - BEZEL.side * 2, h: LID.h - BEZEL.top - BEZEL.chin }
const CAM = { w: 124, h: 30 }

/** A damped spring as a CSS linear() easing */
function spring(zeta: number, omega: number, ms: number, n = 48) {
  const wd = omega * Math.sqrt(1 - zeta * zeta)
  const pts: string[] = []
  for (let i = 0; i <= n; i++) {
    const t = (i / n) * (ms / 1000)
    const x = i === n ? 1 : 1 - Math.exp(-zeta * omega * t) * (Math.cos(wd * t) + ((zeta * omega) / wd) * Math.sin(wd * t))
    pts.push(x.toFixed(4))
  }
  return `linear(${pts.join(', ')})`
}
const GROW = { ease: spring(0.74, 14, 560), ms: 560 }
const SHRINK = { ease: spring(0.98, 18, 420), ms: 420 }

const BOX: Record<Mode, { w: number; h: number; r: number }> = {
  bar: { w: CAM.w + 92, h: CAM.h, r: 10 },
  home: { w: 520, h: 108, r: 24 },
  page: { w: 520, h: 248, r: 26 },
  done: { w: 520, h: 112, r: 24 },
}
const RANK: Record<Mode, number> = { bar: 0, home: 1, done: 1, page: 2 }

function Item({ on, w, children, className = '' }: { on: boolean; w: number; children: ReactNode; className?: string }) {
  return (
    <div className={`ka-item ${className}`} data-on={on || undefined} style={{ width: w }}>
      {children}
    </div>
  )
}

/** The menu-bar band: left of the camera, a gap the camera's width, right of it */
function Band({ left, right }: { left: ReactNode; right?: ReactNode }) {
  return (
    <div className="ka-band">
      <span className="ka-band__side">{left}</span>
      <span className="ka-band__cam" />
      <span className="ka-band__side ka-band__right">{right}</span>
    </div>
  )
}

function CupButton({ on, lid, target }: { on: boolean; lid: boolean; target?: boolean }) {
  return (
    <span className="ka-circle ka-cup" data-on={on || undefined} data-target={target ? 'cup' : undefined}>
      <span className="ka-cup__glyph" data-on={!lid || undefined}>
        <Coffee size={14} strokeWidth={2.4} />
      </span>
      <span className="ka-cup__glyph" data-on={lid || undefined}>
        <Laptop size={14} strokeWidth={2.4} />
      </span>
    </span>
  )
}

function Notch({ s }: { s: S }) {
  const last = useRef<{ mode: Mode; grow: boolean }>({ mode: s.mode, grow: true })
  if (last.current.mode !== s.mode) last.current = { mode: s.mode, grow: RANK[s.mode] >= RANK[last.current.mode] }
  const grow = last.current.grow
  const b = BOX[s.mode]
  const shape: CSSProperties = {
    width: b.w,
    height: b.h,
    borderBottomLeftRadius: b.r,
    borderBottomRightRadius: b.r,
    transitionDuration: `${grow ? GROW.ms : SHRINK.ms}ms`,
    transitionTimingFunction: grow ? GROW.ease : SHRINK.ease,
    transitionDelay: grow ? '0ms' : '110ms',
  }
  const working = s.act === 2 // Keep Awake is on while agents work
  const agent = FEED[s.step]!.icon
  return (
    <div className="ka-notch">
      <span className="ka-notch__shape" style={shape} />

      {/* The bar beside the camera: the agent on the left, status on the right */}
      <Item on={s.mode === 'bar'} w={BOX.bar.w} className="ka-bar">
        <Swap id={agent} className="ka-bar__icon">
          <img src={agent} alt="" width={16} height={16} />
        </Swap>
        <span className="ka-bar__right">
          <span className="ka-bar__laptop" data-on={s.ready || undefined}>
            <Laptop size={14} strokeWidth={2.4} />
          </span>
          <Spinner size={14} className="ka-bar__ring" />
        </span>
      </Item>

      {/* Home: who's working, and the header buttons */}
      <Item on={s.mode === 'home'} w={BOX.home.w} className="ka-panel">
        <Band
          left={<span className="ka-head">1 agent working</span>}
          right={
            <>
              <CupButton on={working} lid={false} target />
              <span className="ka-circle"><Plus size={14} strokeWidth={2.6} /></span>
              <span className="ka-circle"><Settings size={14} strokeWidth={2.4} /></span>
            </>
          }
        />
        <div className="ka-row">
          <img src={claude} alt="" width={24} height={24} className="ka-row__icon" />
          <span className="ka-lines">
            <span className="ka-title">shop</span>
            <span className="ka-sub">Running the tests</span>
          </span>
          <span className="ka-row__meta">148/212</span>
          <Spinner size={14} className="ka-row__ring" />
        </div>
      </Item>

      {/* The Keep Awake page */}
      <Item on={s.mode === 'page'} w={BOX.page.w} className="ka-panel">
        <Band
          left={
            <>
              <span className="ka-circle"><ChevronLeft size={14} strokeWidth={2.8} /></span>
              <span className="ka-head">Keep awake</span>
            </>
          }
        />
        <div className="ka-card ka-card--status">
          <div className="ka-card__row">
            <span className="ka-disc" data-on>
              <Coffee size={16} strokeWidth={2.4} />
            </span>
            <span className="ka-lines">
              <span className="ka-title">Awake while agents work</span>
              <span className="ka-sub">It naps again once they're done.</span>
            </span>
          </div>
          <div className="ka-pills">
            <span className="ka-for">For</span>
            {['30 min', '1 hr', '2 hr', '4 hr', 'Until I stop'].map((p) => (
              <span key={p} className="ka-pill">{p}</span>
            ))}
          </div>
        </div>
        <div className="ka-card">
          <div className="ka-card__row">
            <span className="ka-disc" data-on={s.ready || undefined}>
              <Laptop size={16} strokeWidth={2.4} />
            </span>
            <span className="ka-lines">
              <span className="ka-title">Keep going with the lid closed</span>
              <span className="ka-status">
                <span className="ka-status__opt" data-on={(!s.sw && !s.pending && !s.ready) || undefined}>
                  One switch. Your Mac asks for your password once.
                </span>
                <span className="ka-status__opt" data-on={(s.sw && !s.pending && !s.ready) || undefined}>
                  Setting up, check for the password box
                </span>
                <span className="ka-status__opt" data-on={s.pending || undefined}>
                  <Spinner size={11} />
                  Getting ready, hold the lid a sec
                </span>
                <span className="ka-status__opt ka-green ka-strong" data-on={s.ready || undefined}>
                  <i className="ka-dot" />
                  Ready to close the lid
                </span>
              </span>
            </span>
            <Toggle on={s.sw} className="ka-switch" data-target="switch" />
          </div>
        </div>
      </Item>

      {/* Morning */}
      <Item on={s.mode === 'done'} w={BOX.done.w} className="ka-panel">
        <Band
          left={<span className="ka-head">All caught up</span>}
          right={
            <>
              <CupButton on lid={false} />
              <span className="ka-circle"><Plus size={14} strokeWidth={2.6} /></span>
              <span className="ka-circle"><Settings size={14} strokeWidth={2.4} /></span>
            </>
          }
        />
        <div className="ka-row">
          <span className="ka-row__done">
            <img src={claude} alt="" width={24} height={24} className="ka-row__icon" />
            <span className="ka-row__check"><Check size={9} strokeWidth={3.6} /></span>
          </span>
          <span className="ka-lines">
            <span className="ka-title">All done. Napping now</span>
            <span className="ka-sub">4 tasks shipped while you slept</span>
          </span>
          <span className="ka-row__meta">6:58 AM</span>
        </div>
      </Item>
    </div>
  )
}

/** The macOS password sheet, the one time the lid helper is installed */
function Auth({ s }: { s: S }) {
  return (
    <div className="ka-auth" data-on={s.auth || undefined}>
      <span className="ka-auth__icon">
        <img src={appIcon} alt="" width={52} height={52} />
      </span>
      <div className="ka-auth__title">NotchBar wants to keep your Mac awake with the lid closed.</div>
      <div className="ka-auth__text">You only need to do this once. Enter your password to allow this.</div>
      <div className="ka-auth__field ka-auth__field--user">dev</div>
      <div className="ka-auth__field" data-focus>
        <span className="ka-auth__dots">{'•'.repeat(s.dots)}</span>
        {s.auth && s.dots < 8 && <i className="ka-auth__caret" />}
        {s.dots === 0 && <span className="ka-auth__ph">Password</span>}
      </div>
      <div className="ka-auth__btns">
        <span className="ka-auth__btn">Cancel</span>
        <span className="ka-auth__btn ka-auth__btn--ok" data-target="ok">OK</span>
      </div>
    </div>
  )
}

function Terminal({ s }: { s: S }) {
  const passed = s.act === 2 && s.step >= 1
  return (
    <Window chrome="terminal" title="shop · claude" className="ka-term">
      <div className="ka-term__body">
        <Prompt path="~/shop">claude</Prompt>
        <div className="ss-term__line">
          <span className="ka-claude">✻</span> Refactor checkout, keep tests green
        </div>
        <div className="ss-term__line">
          <span className="ok">●</span> Edit <span className="dim">src/cart/</span>total.ts
        </div>
        <div className="ss-term__line">
          <span className="ok">●</span> npm test{' '}
          <span className={passed ? 'ok' : 'dim'}>
            <Roll>{passed ? '212/212 passed' : '148/212'}</Roll>
          </span>
        </div>
        <Collapse open={s.froze}>
          <div className="ss-term__line">
            <span className="err">✗</span> <span className="err">Mac slept at 11:43 PM.</span> <span className="dim">Nothing ran overnight.</span>
          </div>
        </Collapse>
        <Collapse open={s.act === 2 && s.step >= 2}>
          <div className="ss-term__line"><span className="ok">●</span> git push origin main <span className="dim">done</span></div>
        </Collapse>
        <Collapse open={s.act === 2 && s.step >= 3}>
          <div className="ss-term__line"><span className="ka-codex">◆</span> codex: fix the flaky login test</div>
        </Collapse>
        <Collapse open={s.act === 2 && s.step >= 4}>
          <div className="ss-term__line"><span className="ok">●</span> CI <span className="ok">8/8 green</span></div>
        </Collapse>
        <Collapse open={s.act === 2 && s.step >= 5}>
          <div className="ss-term__line"><span className="ok">✓</span> 4 of 4 shipped</div>
        </Collapse>
        <div className="ss-term__line ka-term__cue">
          <Swap id={s.act === 2 && s.step >= 5 ? 'idle' : 'cook'} className="dim">{s.act === 2 && s.step >= 5 ? 'idle' : 'still cooking'}</Swap>
          <Caret />
        </div>
        {[180, 132, 210, 96].map((w, i) => (
          <div key={i} className="ka-term__filler">
            <Bar w={w} h={7} r={3.5} tone={1} />
          </div>
        ))}
      </div>
    </Window>
  )
}

function Editor() {
  return (
    <Window title="total.ts" className="ka-editor" receded>
      <div className="ka-editor__body">
        {[[0, 120], [0, 200], [16, 160], [16, 130], [32, 180], [16, 90], [0, 60], [0, 0], [0, 150], [16, 210], [16, 120], [32, 140], [16, 70], [0, 50]].map(([x, w], i) => (
          <div key={i} className="ka-editor__line">
            <span className="ka-editor__no">{i + 1}</span>
            {w ? <Bar w={w} h={7} r={3.5} tone={i % 3 === 1 ? 3 : 2} style={{ marginLeft: x }} /> : null}
          </div>
        ))}
      </div>
    </Window>
  )
}

function MenuBar({ s }: { s: S }) {
  return (
    <div className="ka-menu">
      <span className="ka-menu__left">
        <b>Terminal</b>
        <span>Shell</span>
        <span>Edit</span>
        <span>View</span>
      </span>
      <span className="ka-menu__right">
        <BatteryMedium size={17} strokeWidth={1.8} />
        <Wifi size={14} strokeWidth={2.2} />
        <span className="ka-menu__clock">
          <Roll>{CLOCK[s.hour]!}</Roll> {ampm(s.hour)}
        </span>
      </span>
    </div>
  )
}

/** A 14" MacBook Pro, front on: space black lid, the notch, the base's lip */
function MacBook({ s }: { s: S }) {
  return (
    <div className="ka-mac" data-closed={s.closed || undefined}>
      <div className="ka-lid">
        <div className="ka-screen" data-off={!s.screen || s.closed || undefined}>
          <div className="ka-wall" />
          <Editor />
          <Terminal s={s} />
          <MenuBar s={s} />
          <span className="ka-hit" data-target="notch" />
          <Notch s={s} />
          <Auth s={s} />
          <div className="ka-off" />
        </div>
        <span className="ka-cam" />
      </div>
      <div className="ka-base">
        <span className="ka-base__scoop" />
      </div>
    </div>
  )
}

const wait = (a: Act<S>, ms: number) => a.wait(ms)

async function night(a: Act<S>, progress: boolean) {
  for (let h = 1; h <= 6; h++) {
    a.put(progress ? { hour: h, step: h } : { hour: h })
    await wait(a, progress ? 900 : 520)
  }
}

const script = async (a: Act<S>) => {
  const compact = a.layout === 'compact'
  // ---- Act 1: without Keep Awake ----
  await wait(a, 1400)
  a.mark('close1')
  a.put({ closed: true })
  await wait(a, 1600)
  await night(a, false)
  await wait(a, 300)
  a.mark('open1')
  a.put({ closed: false })
  await wait(a, 1100)
  a.put({ froze: true })
  a.mark('froze')
  await wait(a, 2600)
  // The Mac naps, and wakes in act 2
  a.put({ screen: false })
  await wait(a, 700)
  await a.snap({ ...ACT2, screen: false })
  await wait(a, 150)
  a.put({ screen: true })
  await wait(a, 900)

  // ---- Act 2: with Keep Awake ----
  a.mark('hover')
  await a.enter({ at: 'notch', x: 0.7, y: 0.6 }, { duration: 1000 })
  a.put({ mode: 'home' })
  await wait(a, 700)
  await a.move({ at: 'cup', x: 0.5, y: 0.55 }, { duration: 520 })
  await a.click()
  a.put({ mode: 'page' })
  await wait(a, 800)
  await a.move({ at: 'switch', x: 0.5, y: 0.55 }, { duration: 620 })
  a.mark('switch')
  await a.click()
  a.put({ sw: true })
  await wait(a, 350)
  a.put({ auth: true })
  a.mark('auth')
  await wait(a, 700)
  for (let i = 1; i <= 8; i++) {
    a.put({ dots: i })
    await wait(a, 75)
  }
  await wait(a, 250)
  await a.move({ at: 'ok', x: 0.5, y: 0.55 }, { duration: 500 })
  await a.click()
  a.put({ auth: false, pending: true })
  await wait(a, 1000)
  a.put({ pending: false, ready: true })
  a.mark('ready')
  await wait(a, 1300)
  // Off the screen: the hand goes to the lid
  void a.move(compact ? { x: 330, y: 360 } : { x: 1000, y: 760 }, { duration: 700 })
  await wait(a, 260)
  a.put({ mode: 'bar' })
  await wait(a, 900)
  a.mark('close2')
  a.put({ closed: true })
  await wait(a, 1700)
  await night(a, true)
  a.mark('dawn')
  a.put({ dawn: true, closed: false })
  await wait(a, 1000)
  a.put({ mode: 'done' })
  a.mark('done')
  await wait(a, 3000)
  a.put({ screen: false })
  await wait(a, 700)
  await a.snap({ ...START, screen: false })
  await wait(a, 150)
  a.put({ screen: true })
  await wait(a, 400)
}

function Readout({ s }: { s: S }) {
  const on = s.closed && s.screen
  const good = s.act === 2
  return (
    <div className="ka-read" data-on={on || undefined}>
      <div className="ka-read__clock">
        <span className="ka-read__time"><Roll align="end">{CLOCK[s.hour]!}</Roll></span>
        <span className="ka-read__ampm">{ampm(s.hour)}</span>
      </div>
      <div className="ka-read__pill" data-good={good || undefined}>
        <span className="ka-read__state">
          {good ? <i className="ka-dot ka-green" /> : <Moon size={13} strokeWidth={2.4} />}
          {good ? 'Lid closed. Agents still going' : 'Lid closed. Mac asleep, agents frozen'}
        </span>
      </div>
      <div className="ka-read__feed" data-on={good || undefined}>
        <Swap id={s.step}>
          <span className="ka-read__line">
            <img src={FEED[s.step]!.icon} alt="" width={16} height={16} />
            {FEED[s.step]!.text}
          </span>
        </Swap>
      </div>
    </div>
  )
}

/** Lets the page's sky follow the demo's clock: night at 11:43, sunrise at 6:58 */
function SkySync({ hour }: { hour: number }) {
  useEffect(() => {
    const el = document.getElementById('awake')
    if (!el) return
    el.style.setProperty('--awk-p', String(hour / 6))
    el.toggleAttribute('data-morning', hour === 6)
  }, [hour])
  return null
}

export default function KeepAwake() {
  return (
    <Stage<S>
      width={1040}
      height={680}
      compact={{ below: 720, width: 358, height: 310 }}
      theme="dark"
      initial={START}
      poster={POSTER}
      script={script}
      cursor={{ at: { wide: { x: 1000, y: 760 }, compact: { x: 330, y: 360 } }, style: 'real' }}
      className="ka"
    >
      {(s, _rect, layout) => {
        const compact = layout === 'compact'
        // On a phone the laptop is small: push in on the notch while it's used
        const panel = s.mode === 'home' || s.mode === 'page' || s.mode === 'done'
        const focus = !compact ? null : s.auth ? { x: 124, y: 126, width: 110, height: 118 } : panel ? { x: 89, y: 64, width: 180, height: 92 } : null
        return (
          <div className="ka-world" data-act={s.act} data-dawn={s.dawn || undefined} data-zoom={focus ? true : undefined}>
            <SkySync hour={s.hour} />
            <div className="ka-sky" />
            <div className="ka-chip" data-act={s.act}>
              <Swap id={s.act}>
                <span className="ka-chip__in">
                  <i className="ka-dot" />
                  {s.act === 1 ? 'Without Keep Awake' : 'With NotchBar Keep Awake'}
                </span>
              </Swap>
            </div>
            <Readout s={s} />
            {compact ? (
              <Camera focus={focus} max={3.2} pad={0} feather={0}>
                <div className="ka-fitc"><MacBook s={s} /></div>
              </Camera>
            ) : (
              <MacBook s={s} />
            )}
          </div>
        )
      }}
    </Stage>
  )
}

