'use client'

import { motion } from 'motion/react'
import { useRef, useState } from 'react'
import { ease, lively } from '@/lib/motion'
import { useArrival } from '@/components/ui/useArrival'
import { useStill } from '@/components/ui/useStill'
import { write } from '@/components/ui/hand'
import { ClothCover } from '../../ui/ClothCover'
import styles from './SearchDemo.module.css'

type Kind = 'title' | 'hand' | 'typed' | 'pdf' | 'scan' | 'said'

type Place = {
  kind: Kind
  name: string
  book: string
  spot?: string
  before: string
  match: string
  after: string
  how: string
}

const places: Place[] = [
  { kind: 'title', name: 'Titles', book: 'Notebook', before: '', match: 'Tides', after: ' and Currents', how: 'The word is in a notebook’s title.' },
  { kind: 'hand', name: 'Handwriting', book: 'Field Notes', spot: 'Page 4', before: 'Spring ', match: 'tides', after: ' come at full and new moon', how: 'Read from handwriting, on the iPad.' },
  { kind: 'typed', name: 'Typed text', book: 'Field Notes', spot: 'Page 7', before: 'Neap ', match: 'tides', after: ' fall between them', how: 'Typed in a text box on the page.' },
  { kind: 'pdf', name: 'PDF text', book: 'Tide Tables', spot: 'Page 2', before: 'Predicted ', match: 'tides', after: ' for the week', how: 'From the PDF’s own text.' },
  { kind: 'scan', name: 'Scans', book: 'Field Notes', spot: 'Page 11', before: 'Notice of ', match: 'tides', after: ' and sailing times', how: 'The print on a scanned sheet, read on the iPad.' },
  { kind: 'said', name: 'Recordings', book: 'Field Notes', spot: 'Recording', before: 'and the ', match: 'tides', after: ' follow the moon', how: 'Said in a recording you had transcribed.' },
]

/** A search for one word, and the result it gives in each of the places search looks. */
export function SearchDemo() {
  const [chosen, setChosen] = useState<Kind>('hand')
  const [touched, setTouched] = useState(false)
  const field = useRef<HTMLDivElement>(null)
  const { arrived } = useArrival(field, { amount: 0.9 })
  const place = places.find((item) => item.kind === chosen) ?? places[1]

  return (
    <div className={styles.demo}>
      <div ref={field} className={styles.field} data-waiting={arrived ? undefined : ''}>
        <svg className={styles.glass} viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">
          <circle cx="7" cy="7" r="4.6" />
          <path d="M10.6 10.6 14 14" />
        </svg>
        <span className="visually-hidden">A search for the word</span>
        <span className={styles.query}>tides</span>
        <span className={styles.caret} aria-hidden="true" />
      </div>

      <div className={styles.places} role="group" aria-label="Where the word was found">
        {places.map((item) => (
          <button
            key={item.kind}
            type="button"
            className={styles.place}
            aria-pressed={item.kind === chosen}
            onClick={() => {
              setChosen(item.kind)
              setTouched(true)
            }}
          >
            <span>{item.name}</span>
            <svg className={styles.check} viewBox="0 0 12 12" width="12" height="12" aria-hidden="true">
              <path d="M2 6.5 5 9.5 10 3" />
            </svg>
          </button>
        ))}
      </div>

      <div className={styles.result} aria-live="polite">
        <motion.div
          key={chosen}
          className={styles.thumb}
          aria-hidden="true"
          data-more-art
          initial={touched ? { y: 14, rotate: -4 } : false}
          animate={{ y: 0, rotate: 0 }}
          transition={lively}
        >
          <Thumb kind={chosen} replay={touched} />
        </motion.div>
        <div className={styles.found}>
          <p className="caps">
            <span className={styles.spot}>{place.book}</span>{' '}
            {place.spot ? <span className={styles.spot}>· {place.spot}</span> : null}
          </p>
          <p className={styles.snippet}>
            {place.before}
            <mark key={chosen} className={`${styles.match} ${touched ? styles.swept : ''}`}>
              {place.match}
            </mark>
            {place.after}
          </p>
          <p className={styles.how}>{place.how}</p>
        </div>
      </div>
    </div>
  )
}

function Thumb({ kind, replay }: { kind: Kind; replay: boolean }) {
  if (kind === 'title') return <ClothCover title="Tides and Currents" color="jade" className={styles.cover} />
  if (kind === 'hand') return <HandSheet replay={replay} />
  if (kind === 'typed') {
    return (
      <div className={`print ${styles.sheet} ${styles.ruled}`}>
        <p className={styles.typed}>
          Neap <Hit /> fall between them
        </p>
      </div>
    )
  }
  if (kind === 'pdf') {
    return (
      <div className={`print ${styles.sheet} ${styles.pdf}`}>
        <span className={styles.pdfTag}>PDF</span>
        <p className={styles.pdfHead}>Tide Tables</p>
        <p className={styles.pdfBody}>
          Predicted <Hit /> for the week, with the height of each high water.
        </p>
        <svg className={styles.pdfTable} viewBox="0 0 86 30" aria-hidden="true">
          <path d="M0.5,0.5 H85.5 V29.5 H0.5 Z M0.5,10 H85.5 M0.5,20 H85.5 M29,0.5 V29.5 M57,0.5 V29.5" />
        </svg>
      </div>
    )
  }
  if (kind === 'scan') {
    return (
      <div className={`print ${styles.sheet} ${styles.scan}`}>
        {[styles.cropA, styles.cropB, styles.cropC, styles.cropD].map((corner) => (
          <i key={corner} className={`${styles.crop} ${corner}`} />
        ))}
        <p className={styles.scanHead}>Harbour Office</p>
        <p className={styles.scanText}>
          Notice of <Hit /> and sailing times
        </p>
      </div>
    )
  }
  return (
    <div className={`print ${styles.sheet} ${styles.said}`}>
      <svg className={styles.sound} viewBox="0 0 88 20" aria-hidden="true">
        <path d="M2,10 V10 M8,7 V13 M14,4 V16 M20,8 V12 M26,2 V18 M32,6 V14 M38,9 V11 M44,3 V17 M50,7 V13 M56,5 V15 M62,9 V11 M68,6 V14 M74,2 V18 M80,8 V12 M86,10 V10" />
      </svg>
      <div className={styles.line}>
        <b>12:31</b>
        <i />
      </div>
      <div className={`${styles.line} ${styles.lineSaid}`}>
        <b>12:40</b>
        <span>
          and the <Hit /> follow the moon
        </span>
      </div>
      <div className={styles.line}>
        <b>12:52</b>
        <i />
      </div>
    </div>
  )
}

function Hit() {
  return <mark className={styles.hit}>tides</mark>
}

const word = write('tides')
const rules = [34, 50, 66, 82, 98, 114, 130].map((y) => `M0,${y} H108`).join(' ')
const stroke = { hidden: { pathLength: 0, opacity: 0 }, shown: { pathLength: 1, opacity: 1 } }

function HandSheet({ replay }: { replay: boolean }) {
  const still = useStill()
  const play = replay ? { animate: 'shown' } : { whileInView: 'shown', viewport: { once: true, amount: 0.6 } }
  return (
    <motion.svg className={`print ${styles.sheet}`} viewBox="0 0 108 144" initial="hidden" {...play}>
      <path className={styles.rules} d={rules} />
      <path className={styles.ink} d="M13,23 q3,-6 6,0 t6,0 t6,0 t6,0 t6,0" />
      <motion.rect
        data-drawn
        className={styles.band}
        x="8"
        y="34"
        width="63"
        height="19"
        rx="2"
        style={{ transformBox: 'fill-box', originX: 0 }}
        variants={{ hidden: { scaleX: 0 }, shown: { scaleX: 1 } }}
        transition={{ duration: 0.28, ease: ease.glide, delay: 0.66 }}
      />
      <g transform="translate(13 36.6) scale(0.64)">
        {word.letters.map((letter, index) => (
          <g key={index} transform={letter.transform}>
            <motion.path
              data-drawn
              className={styles.letter}
              d={letter.d}
              variants={stroke}
              transition={still ? { duration: 0 } : { duration: 0.2, ease: ease.inOut, delay: 0.16 + index * 0.08, opacity: { duration: 0.01, delay: 0.16 + index * 0.08 } }}
            />
          </g>
        ))}
      </g>
      <path
        className={styles.ink}
        d="M13,64 q3,-6 6,0 t6,0 t6,0 t6,0 t6,0 t6,0 t6,0 m8,0 q3,-6 6,0 t6,0 t6,0 M13,80 q3,-6 6,0 t6,0 t6,0 t6,0 m8,0 q3,-6 6,0 t6,0 t6,0 t6,0 t6,0 M13,96 q3,-6 6,0 t6,0 t6,0 t6,0 t6,0 t6,0"
      />
    </motion.svg>
  )
}
