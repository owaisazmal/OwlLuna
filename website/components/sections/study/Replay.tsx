'use client'

import { motion, useAnimationFrame, useInView, useMotionValue, useMotionValueEvent, useReducedMotion, useTransform, type MotionValue } from 'motion/react'
import { useEffect, useRef, useState, type KeyboardEvent } from 'react'
import { Replayed, Written, useInk } from './Ink'
import { Sheet } from './Sheet'
import { write } from '@/components/ui/hand'
import styles from './Replay.module.css'

const length = 16
const opening = 6.4
const step = 0.15
const knob = 14

const heading = write('The Moon')

const notes = [
  { at: 1.2, line: write('Orbit = 27 days', 2) },
  { at: 5.2, line: write('Pulls the tides', 5) },
  { at: 9.2, line: write('We see one side', 8) },
  { at: 13.2, line: write('Light = sunlight', 4) },
]

const spoken = [
  { at: 0, words: 'The Moon goes round the Earth about every twenty-seven days.' },
  { at: 4, words: 'Its pull is what raises the tides.' },
  { at: 8, words: 'It turns once for each orbit, so we only ever see one side.' },
  { at: 12, words: 'It gives no light of its own. What we see is sunlight.' },
]

const sketch = [
  { at: 11.5, d: 'M34,50 Q33,32 51,31 Q70,31 70,50 Q70,69 52,69 Q34,69 34,50 Z' },
  { at: 11.75, d: 'M35,51 Q52,60 69,50 M52,32 Q43,50 53,68' },
  { at: 12, d: 'M10,58 Q0,22 56,12 Q112,4 119,36 Q124,70 70,82 Q26,90 12,64' },
  { at: 12.4, d: 'M108,13 Q116,13 116,21 Q116,29 108,29 Q100,29 100,21 Q100,13 108,13 Z', fill: 'M108,13 Q116,13 116,21 Q116,29 108,29 Z' },
  { at: 12.7, d: 'M4,66 L11,62 L16,69' },
]

const stamp = (seconds: number) => `${Math.floor(seconds / 60)}:${String(Math.floor(seconds % 60)).padStart(2, '0')}`
const lineAt = (seconds: number) => spoken.reduce((found, line, index) => (line.at <= seconds ? index : found), 0)

/** A recording replayed with its ink: the notes are faint until the sound reaches them. */
export function Replay() {
  const figure = useRef<HTMLElement>(null)
  const scrub = useRef<HTMLInputElement>(null)
  const dragging = useRef(false)
  const stopped = useRef(false)
  const rest = useRef(0)
  const reduced = useReducedMotion()
  const inView = useInView(figure, { amount: 0.35 })
  const clock = useMotionValue(opening)
  const [playing, setPlaying] = useState(false)
  const [second, setSecond] = useState(Math.floor(opening))
  const [saying, setSaying] = useState(lineAt(opening))
  const fill = useTransform(clock, (value) => `calc(${knob / 2}px + (100% - ${knob}px) * ${value / length})`)

  useEffect(() => {
    if (!inView) setPlaying(false)
    else if (!reduced && !stopped.current) setPlaying(true)
  }, [inView, reduced])

  useAnimationFrame((_, delta) => {
    if (!playing || dragging.current) return
    const now = clock.get()
    if (now < length) {
      clock.set(Math.min(length, now + Math.min(delta, 80) / 1000))
      return
    }
    rest.current += delta
    if (rest.current > 1500) {
      rest.current = 0
      clock.set(0)
    }
  })

  useMotionValueEvent(clock, 'change', (value) => {
    setSecond(Math.floor(value))
    setSaying(lineAt(value))
    if (scrub.current && !dragging.current) scrub.current.value = String(value)
  })

  const toggle = () => {
    stopped.current = playing
    if (!playing && clock.get() >= length) clock.set(0)
    rest.current = 0
    setPlaying(!playing)
  }

  const hold = () => {
    const release = () => {
      dragging.current = false
      window.removeEventListener('pointerup', release)
      window.removeEventListener('pointercancel', release)
    }
    dragging.current = true
    window.addEventListener('pointerup', release)
    window.addEventListener('pointercancel', release)
  }

  const jump = (seconds: number) => {
    stopped.current = false
    rest.current = 0
    clock.set(seconds)
    setPlaying(true)
  }

  const nudge = (event: KeyboardEvent<HTMLInputElement>) => {
    const back = event.key === 'ArrowLeft' || event.key === 'ArrowDown'
    if (!back && event.key !== 'ArrowRight' && event.key !== 'ArrowUp') return
    event.preventDefault()
    rest.current = 0
    clock.set(Math.min(length, Math.max(0, clock.get() + (back ? -1 : 1))))
  }

  return (
    <figure ref={figure} className={styles.figure}>
      <div className={styles.desk}>
        <Sheet lead="Astronomy" trail="P. 11" className={styles.page}>
          <div className={styles.row}>
            <Written line={heading} className={styles.heading} />
          </div>
          {notes.map((note) => (
            <div key={note.at} className={styles.row}>
              <button type="button" className={styles.ink} aria-label={`Jump to ${stamp(note.at)}, when “${note.line.text}” was written`} onClick={() => jump(note.at)}>
                <Replayed line={note.line} clock={clock} at={note.at} step={step} />
              </button>
            </div>
          ))}
          <svg className={styles.sketch} viewBox="0 0 124 90" overflow="visible" aria-hidden="true">
            {sketch.map((stroke) => (
              <Sketched key={stroke.d} d={stroke.d} fill={stroke.fill} at={stroke.at} clock={clock} />
            ))}
          </svg>
        </Sheet>

        <div className={styles.bar}>
          <button type="button" className={styles.play} aria-label="Play the recording" aria-pressed={playing} onClick={toggle}>
            <svg viewBox="0 0 24 24" width="24" height="24" aria-hidden="true">
              {playing ? <path d="M8 5v14M16 5v14" fill="none" stroke="currentColor" strokeWidth="3.6" strokeLinecap="round" /> : <path d="M8 4.8 19 12 8 19.2Z" fill="currentColor" stroke="currentColor" strokeWidth="1.6" strokeLinejoin="round" />}
            </svg>
          </button>
          <span className={styles.time}>{stamp(second)}</span>
          <span className={styles.scrub}>
            <span className={styles.track} aria-hidden="true">
              <motion.span className={`cloth ${styles.fill}`} style={{ width: fill }} />
            </span>
            <input
              ref={scrub}
              type="range"
              min={0}
              max={length}
              step={0.1}
              defaultValue={opening}
              aria-label="Place in the recording"
              aria-valuetext={`${stamp(second)} of ${stamp(length)}`}
              onChange={(event) => {
                rest.current = 0
                clock.set(Number(event.currentTarget.value))
              }}
              onPointerDown={hold}
              onKeyDown={nudge}
            />
          </span>
          <span className={styles.length}>{stamp(length)}</span>
        </div>

        <div className={styles.transcript}>
          <div className={styles.transcriptHead}>
            <span className="caps">Transcript</span>
            <span className="caps">Made on the device</span>
          </div>
          <ol className={styles.said}>
            {spoken.map((line, index) => (
              <li key={line.at}>
                <button
                  type="button"
                  className={`${styles.line} ${index === saying ? styles.saying : ''}`}
                  aria-current={index === saying ? 'true' : undefined}
                  onClick={() => jump(line.at)}
                >
                  <span className={styles.stamp}>{stamp(line.at)}</span>
                  <span className={styles.words}>
                    <span className={styles.room} aria-hidden="true">
                      {line.words}
                    </span>
                    <span>{line.words}</span>
                  </span>
                </button>
              </li>
            ))}
          </ol>
          <p className={`caps ${styles.hint}`}>Tap a line to hear it</p>
        </div>
      </div>
      <figcaption className={`meta ${styles.caption}`}>Tap a line of ink to jump the sound to the moment it was written.</figcaption>
    </figure>
  )
}

function Sketched({ d, fill, at, clock }: { d: string; fill?: string; at: number; clock: MotionValue<number> }) {
  const opacity = useInk(clock, at)
  return (
    <motion.g style={{ opacity }}>
      {fill ? <path d={fill} fill="currentColor" /> : null}
      <path d={d} fill="none" stroke="currentColor" strokeWidth="2.6" strokeLinecap="round" strokeLinejoin="round" />
    </motion.g>
  )
}
