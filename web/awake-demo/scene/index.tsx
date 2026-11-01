import { useRef, type CSSProperties } from 'react'
import { BatteryMedium, Check, Coffee, Laptop, Moon, Wifi } from 'lucide-react'
import { Stage } from '../kit/stage'
import type { Act } from '../kit/act'
import { Bar, Caret, Prompt, Window } from '../kit/window'
import { Collapse } from '../kit/motion/Collapse'
import { Roll } from '../kit/motion/Roll'
import { Swap } from '../kit/motion/Swap'
import { Spinner } from '../kit/parts/Spinner'
import { Toggle } from '../kit/controls/Toggle'
import claude from './claude.svg'
import codex from './codex.png'
import './keep-awake.css'

// NotchBar's Keep Awake, told on the Mac's own screen. The stage is the
// display: menu bar, the black notch, a terminal where Claude is mid-task.
//
// Beats (about 16s):
//   1. The pointer reaches the notch; it springs open on the Keep Awake page.
//   2. One click on "Keep going with the lid closed": Getting ready, then
//      Ready to close the lid, in green.
//   3. The pointer leaves the screen (the person goes to close the lid). The
//      notch folds to its bar with the green laptop; the lid comes down over
//      the screen and a big clock appears.
//   4. Night as a time-lapse: the clock rolls 11:42 PM to 6:58 AM while the
//      terminal under the lid keeps shipping and the notch narrates.
//   5. Dawn: the lid lifts, the notch opens on "All done. Napping now".
//      After the hold the Mac naps (the screen goes black), which is the
//      cause of the reset; it wakes on the opening frame.
//
// One shape for the notch: its box and radius spring between bar, page and
// done, while the content sits on its own layer and fades (dynamic-island).
//
// Real strings: the agent's task and its test run, the two switches on the
// Keep Awake page, the notch's status lines, the clock, the payoff.

type Mode = 'bar' | 'open' | 'done'
type S = {
  mode: Mode
  lid: boolean
  pending: boolean
  ready: boolean
  closed: boolean
  dawn: boolean
  step: number
  asleep: boolean
}

const START: S = { mode: 'bar', lid: false, pending: false, ready: false, closed: false, dawn: false, step: 0, asleep: false }
const POSTER: S = { ...START, lid: true, ready: true, closed: true, step: 3 }

const CLOCK = ['11:42', '12:36', '1:58', '3:15', '4:41', '5:52', '6:58']
const AMPM = (step: number) => (step === 0 ? 'PM' : 'AM')

// What the notch says through the night, one per clock step
const NIGHT: { icon: string; text: string }[] = [
  { icon: claude, text: 'Lid closed. Still going.' },
  { icon: claude, text: '212 tests passed' },
  { icon: claude, text: 'Pushed to main' },
  { icon: codex, text: 'Codex took the next task' },
  { icon: codex, text: 'CI all green' },
  { icon: codex, text: 'Last task wrapped' },
  { icon: codex, text: 'Last task wrapped' },
]

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
const GROW = { ease: spring(0.72, 14, 560), ms: 560 }
const SHRINK = { ease: spring(0.98, 18, 420), ms: 420 }

type Box = { w: number; h: number; r: number }
const SIZE: Record<Mode, number> = { bar: 0, done: 1, open: 2 }
const geo = (compact: boolean): Record<Mode, Box> => ({
  bar: { w: compact ? 300 : 360, h: 32, r: 12 },
  open: { w: compact ? 340 : 480, h: 206, r: 26 },
  done: { w: compact ? 340 : 480, h: 104, r: 26 },
})

function Notch({ s, compact }: { s: S; compact: boolean }) {
  const G = geo(compact)
  const last = useRef<{ mode: Mode; grow: boolean }>({ mode: s.mode, grow: true })
  if (last.current.mode !== s.mode) last.current = { mode: s.mode, grow: SIZE[s.mode] > SIZE[last.current.mode] }
  const grow = last.current.grow
  const b = G[s.mode]
  const shape: CSSProperties = {
    width: b.w,
    height: b.h,
    borderBottomLeftRadius: b.r,
    borderBottomRightRadius: b.r,
    transitionDuration: `${grow ? GROW.ms : SHRINK.ms}ms`,
    transitionTimingFunction: grow ? GROW.ease : SHRINK.ease,
    transitionDelay: grow ? '0ms' : '110ms',
  }
  const line = s.closed || s.step > 0 ? NIGHT[s.step]! : s.ready ? { icon: claude, text: 'Ready to close the lid' } : { icon: claude, text: 'Running the tests' }
  const held = s.ready || s.closed
  return (
    <div className="ka-notch" style={{ width: G.open.w }}>
      <span className="ka-notch__shape" style={shape} />

      {/* The bar: agent, what it's doing, and on the right the ring or the laptop */}
      <div className="ka-item ka-bar" data-on={s.mode === 'bar' || undefined} style={{ width: G.bar.w }}>
        <Swap id={line.icon} className="ka-bar__icon">
          <img src={line.icon} alt="" width={16} height={16} />
        </Swap>
        <Swap id={line.text} className="ka-bar__text">
          {line.text}
        </Swap>
        <span className="ka-bar__end">
          <span className="ka-bar__mark" data-on={!held || undefined}>
            <Spinner size={14} />
          </span>
          <span className="ka-bar__mark ka-green" data-on={held || undefined}>
            <Laptop size={16} strokeWidth={2.2} />
          </span>
        </span>
      </div>

      {/* The Keep Awake page */}
      <div className="ka-item ka-page" data-on={s.mode === 'open' || undefined} style={{ width: G.open.w }}>
        <div className="ka-page__head">Keep awake</div>
        <div className="ka-card">
          <span className="ka-disc" data-on>
            <Coffee size={16} strokeWidth={2.4} />
          </span>
          <span className="ka-lines">
            <span className="ka-title">Awake while agents work</span>
            <span className="ka-sub">It naps again once they're done.</span>
          </span>
        </div>
        <div className="ka-card">
          <span className="ka-disc" data-on={s.ready || undefined}>
            <Laptop size={16} strokeWidth={2.4} />
          </span>
          <span className="ka-lines">
            <span className="ka-title">Keep going with the lid closed</span>
            <span className="ka-status">
              <span className="ka-status__opt" data-on={(!s.lid && !s.ready) || undefined}>
                {compact ? 'One switch, one password.' : 'One switch. Your Mac asks for your password once.'}
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
          <Toggle on={s.lid} className="ka-switch" data-target="switch" />
        </div>
      </div>

      {/* Morning */}
      <div className="ka-item ka-done" data-on={s.mode === 'done' || undefined} style={{ width: G.done.w }}>
        <span className="ka-done__icon">
          <img src={claude} alt="" width={30} height={30} />
          <span className="ka-done__check">
            <Check size={10} strokeWidth={3.4} />
          </span>
        </span>
        <span className="ka-lines">
          <span className="ka-done__title">All done. Napping now</span>
          <span className="ka-done__sub">4 tasks shipped while you slept</span>
        </span>
        <span className="ka-done__time">6:58 AM</span>
      </div>
    </div>
  )
}

function Terminal({ s, compact }: { s: S; compact: boolean }) {
  const passed = s.step >= 1
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
        <TermLine on={s.step >= 2}>
          <span className="ok">●</span> git push origin main <span className="dim">done</span>
        </TermLine>
        <TermLine on={s.step >= 3}>
          <span className="ka-codex">◆</span> codex: fix the flaky login test
        </TermLine>
        <TermLine on={s.step >= 4}>
          <span className="ok">●</span> CI <span className="ok">8/8 green</span>
        </TermLine>
        <TermLine on={s.step >= 5}>
          <span className="ok">✓</span> 4 of 4 shipped{compact ? '' : <span className="dim">, nothing left to do</span>}
        </TermLine>
        <div className="ss-term__line ka-term__cue">
          <Swap id={s.step < 5 ? 'cook' : 'idle'} className="dim">{s.step < 5 ? 'still cooking' : 'idle'}</Swap>
          <Caret />
        </div>
        {!compact &&
          [180, 132, 210, 96].map((w, i) => (
            <div key={i} className="ka-term__filler">
              <Bar w={w} h={7} r={3.5} tone={1} />
            </div>
          ))}
      </div>
    </Window>
  )
}

function TermLine({ on, children }: { on: boolean; children: React.ReactNode }) {
  return (
    <Collapse open={on}>
      <div className="ss-term__line">{children}</div>
    </Collapse>
  )
}

function Editor() {
  return (
    <Window title="total.ts" className="ka-editor" receded>
      <div className="ka-editor__body">
        {[
          [0, 120], [0, 220], [16, 180], [16, 150], [32, 200], [16, 90], [0, 60], [0, 0],
          [0, 170], [16, 240], [16, 130], [32, 160], [32, 110], [16, 70], [0, 50],
        ].map(([x, w], i) => (
          <div key={i} className="ka-editor__line">
            <span className="ka-editor__no">{i + 1}</span>
            {w ? <Bar w={w} h={7} r={3.5} tone={i % 3 === 1 ? 3 : 2} style={{ marginLeft: x }} /> : null}
          </div>
        ))}
      </div>
    </Window>
  )
}

function MenuBar({ s, compact }: { s: S; compact: boolean }) {
  return (
    <div className="ka-menu">
      {compact ? null : (<>
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
          <Roll>{CLOCK[s.step]!}</Roll> {AMPM(s.step)}
        </span>
      </span>
      </>)}
    </div>
  )
}

const script = async (a: Act<S>) => {
  const compact = a.layout === 'compact'
  await a.wait(1000)
  a.mark('hover')
  // The pointer comes in from the corner, already on its way to the notch
  await a.enter({ at: 'notch', x: 0.62, y: 0.6 }, { duration: 1100 })
  a.put({ mode: 'open' })
  await a.wait(800)
  await a.move({ at: 'switch', x: 0.5, y: 0.55 }, { duration: 620 })
  a.mark('switch')
  await a.click()
  a.put({ lid: true, pending: true })
  await a.wait(950)
  a.put({ pending: false, ready: true })
  a.mark('ready')
  await a.wait(1300)
  // Off the screen: the person reaches for the lid
  void a.move(compact ? { x: 300, y: 520 } : { x: 900, y: 700 }, { duration: 700 })
  await a.wait(260)
  a.put({ mode: 'bar' })
  await a.wait(1000)
  a.mark('close')
  a.put({ closed: true })
  await a.wait(1500)
  for (let i = 1; i <= 6; i++) {
    a.put({ step: i })
    await a.wait(i === 6 ? 700 : 950)
  }
  a.mark('dawn')
  a.put({ dawn: true })
  await a.wait(450)
  a.put({ closed: false })
  await a.wait(750)
  a.put({ mode: 'done' })
  a.mark('done')
  await a.wait(2600)
  // The Mac naps: the cause of the reset
  a.mark('nap')
  a.put({ asleep: true })
  await a.wait(900)
  await a.snap({ ...START, asleep: true })
  await a.wait(250)
  a.put({ asleep: false })
  await a.wait(500)
}

export default function KeepAwake() {
  return (
    <Stage<S>
      width={1040}
      height={600}
      compact={{ below: 720, width: 358, height: 480 }}
      theme="dark"
      initial={START}
      poster={POSTER}
      script={script}
      cursor={{ at: { wide: { x: 900, y: 700 }, compact: { x: 300, y: 520 } }, style: 'real' }}
      className="ka"
    >
      {(s, _rect, layout) => {
        const compact = layout === 'compact'
        const W = compact ? 358 : 1040
        const G = geo(compact)
        return (
          <div className="ka-screen" data-closed={s.closed || undefined} data-dawn={s.dawn || undefined}>
            <div className="ka-wall" />
            {!compact && <Editor />}
            <Terminal s={s} compact={compact} />
            <MenuBar s={s} compact={compact} />

            {/* The lid coming down over the screen, and the night it brings */}
            <div className="ka-lid" aria-hidden>
              <div className="ka-night">
                <div className="ka-night__clock">
                  <span className="ka-night__time"><Roll align="end">{CLOCK[s.step]!}</Roll></span>
                  <span className="ka-night__ampm">{AMPM(s.step)}</span>
                </div>
                <div className="ka-night__note">
                  <Moon size={13} strokeWidth={2.4} />
                  Lid closed, agents still going
                </div>
              </div>
            </div>

            <span
              className="ka-hit"
              data-target="notch"
              style={{ left: Math.round((W - G.bar.w) / 2), width: G.bar.w, height: G.bar.h }}
            />
            <Notch s={s} compact={compact} />
            <div className="ka-sleep" data-on={s.asleep || undefined} />
          </div>
        )
      }}
    </Stage>
  )
}
