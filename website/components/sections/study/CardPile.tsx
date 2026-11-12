'use client'

import { AnimatePresence, motion, useAnimationControls, useReducedMotion } from 'motion/react'
import { useEffect, useRef, useState } from 'react'
import { Button } from '@/components/ui/Button'
import { lively, quick } from '@/lib/motion'
import { IndexCard } from '../../ui/IndexCard'
import { Tape } from '../../ui/Tape'
import { Written } from './Ink'
import { write } from '@/components/ui/hand'
import styles from './CardPile.module.css'

type Grade = 'again' | 'good' | 'easy'
type Side = { says: string; clipping?: 'taped' | 'lifted' | 'ink' }
type Card = { id: string; made: string; front: Side; back: Side }

const pulls = write('Pulls the', 5)
const tides = write('tides', 1)
const light = write('Light = sunlight', 4)

const deck: Card[] = [
  {
    id: 'tape',
    made: 'From study tape',
    front: { clipping: 'taped', says: 'A clipping from the page: “Pulls the”, then a strip of study tape.' },
    back: { clipping: 'lifted', says: 'The same clipping with the tape lifted: “Pulls the tides”.' },
  },
  {
    id: 'ink',
    made: 'From handwriting',
    front: { says: 'What gives the Moon its light?' },
    back: { clipping: 'ink', says: 'A clipping of handwriting from the page: “Light = sunlight”.' },
  },
  {
    id: 'own',
    made: 'Your own',
    front: { says: 'How long does one orbit take?' },
    back: { says: 'About 27 days.' },
  },
]

const grades: { grade: Grade; name: string; days: number; wait: string; said: string }[] = [
  { grade: 'again', name: 'Again', days: 0, wait: 'Today', said: 'It comes round again in this sitting.' },
  { grade: 'good', name: 'Good', days: 1, wait: 'Tomorrow', said: 'It comes back tomorrow.' },
  { grade: 'easy', name: 'Easy', days: 4, wait: 'In 4 days', said: 'It comes back in 4 days.' },
]

const order = deck.map((_, index) => index)
const kept = { x: '64%', rotate: 8, opacity: 0 }
const leaving = { again: { x: '-64%', rotate: -9, opacity: 0 }, good: kept, easy: kept }

/** A sitting with three flashcards: turn the top card over, say how well you knew it, and see when it comes back. */
export function CardPile() {
  const reduced = useReducedMotion()
  const swing = useAnimationControls()
  const turning = useRef(false)
  const sitting = useRef(0)
  const focus = useRef<'good' | 'show' | 'deal' | null>(null)
  const keys = useRef<HTMLDivElement>(null)
  const [queue, setQueue] = useState(order)
  const [turn, setTurn] = useState(0)
  const [revealed, setRevealed] = useState(false)
  const [last, setLast] = useState<Grade>('good')
  const [soonest, setSoonest] = useState(4)
  const [said, setSaid] = useState('')

  const card = queue.length > 0 ? deck[queue[0]] : null
  const position = deck.length - queue.length + 1

  useEffect(() => {
    const target = focus.current
    focus.current = null
    if (target) keys.current?.querySelectorAll('button')[target === 'good' ? 1 : 0]?.focus()
  }, [revealed, turn, queue.length])

  const turnOver = async (from?: 'show') => {
    if (!card || turning.current) return
    const next = !revealed
    if (from === 'show') focus.current = 'good'
    if (reduced) {
      setRevealed(next)
      setSaid((next ? card.back : card.front).says)
      return
    }
    const started = sitting.current
    turning.current = true
    await swing.start({ rotateY: next ? 90 : -90, transition: { duration: 0.14, ease: 'easeIn' } })
    turning.current = false
    if (started !== sitting.current) return
    setRevealed(next)
    setSaid((next ? card.back : card.front).says)
    swing.set({ rotateY: next ? -90 : 90 })
    swing.start({ rotateY: 0, transition: { type: 'spring', duration: 0.5, bounce: 0.36 } })
  }

  const answer = (choice: (typeof grades)[number]) => {
    if (!card) return
    sitting.current += 1
    const rest = queue.slice(1)
    const next = choice.grade === 'again' ? [...rest, queue[0]] : rest
    if (choice.grade !== 'again') setSoonest((current) => Math.min(current, choice.days))
    focus.current = next.length > 0 ? 'show' : 'deal'
    setLast(choice.grade)
    setSaid(next.length > 0 ? `${choice.said} Next card.` : `${choice.said} All caught up.`)
    setQueue(next)
    setTurn((current) => current + 1)
    setRevealed(false)
    swing.set({ rotateY: 0 })
  }

  const dealAgain = () => {
    sitting.current += 1
    focus.current = 'show'
    setQueue(order)
    setTurn((current) => current + 1)
    setRevealed(false)
    setSoonest(4)
    setSaid('Three cards to study.')
  }

  const side = card ? (revealed ? card.back : card.front) : null
  const under = Math.min(queue.length - 1, 2)

  return (
    <figure className={`print ${styles.desk}`}>
      <div className={styles.head}>
        <span>{card ? `Card ${position} of ${deck.length}` : 'Flashcards'}</span>
        <span>{card ? card.made : 'Done for today'}</span>
      </div>

      <div className={styles.pile}>
        {under >= 2 ? <Leaf turn={2.6} drop={12} /> : null}
        {under >= 1 ? <Leaf turn={-1.8} drop={6} /> : null}
        <AnimatePresence initial={false} custom={last}>
          {card && side ? (
            <motion.div
              key={`${card.id}-${turn}`}
              className={styles.slot}
              custom={last}
              variants={{ enter: { opacity: 0, scale: 0.96 }, rest: { opacity: 1, scale: 1, x: '0%', rotate: 0 }, exit: (grade: Grade) => leaving[grade] }}
              initial="enter"
              animate="rest"
              exit="exit"
              transition={{ type: 'spring', duration: 0.5, bounce: 0.2, opacity: { duration: 0.22 } }}
            >
              <motion.button
                type="button"
                className={styles.card}
                aria-pressed={revealed}
                onClick={() => turnOver()}
                animate={swing}
                whileHover={{ y: -3 }}
                whileTap={{ scale: 0.985 }}
                transition={quick}
                style={{ transformPerspective: 900 }}
              >
                <IndexCard side={revealed ? 'Answer' : 'Question'} source="Astronomy" className={styles.face}>
                  <span key={revealed ? 'back' : 'front'} className={styles.words}>
                    <Face side={side} />
                  </span>
                </IndexCard>
                <span className="visually-hidden">Turn the card over.</span>
              </motion.button>
            </motion.div>
          ) : (
            <motion.div key="done" className={styles.slot} initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} transition={{ duration: 0.24, delay: 0.12 }}>
              <div className={styles.done}>
                <span className={styles.fan} aria-hidden="true">
                  <IndexCard className={`${styles.fanLeaf} ${styles.fanLeft}`}>{null}</IndexCard>
                  <IndexCard className={`${styles.fanLeaf} ${styles.fanRight}`}>{null}</IndexCard>
                  <IndexCard className={styles.fanLeaf}>
                    <svg className={styles.check} viewBox="0 0 32 32">
                      <path d="M6 17.5 13 25 26.5 8" fill="none" stroke="currentColor" strokeWidth="4.2" strokeLinecap="round" strokeLinejoin="round" />
                    </svg>
                  </IndexCard>
                </span>
                <p className={`app-display ${styles.caught}`}>All caught up.</p>
                <p className={styles.back}>{soonest === 1 ? 'The next card comes back tomorrow.' : 'The next card comes back in 4 days.'}</p>
              </div>
            </motion.div>
          )}
        </AnimatePresence>
      </div>

      <div ref={keys} className={styles.answers}>
        {!card ? (
          <Button className={`${styles.key} ${styles.wide}`} onClick={dealAgain}>
            Go through them again
          </Button>
        ) : revealed ? (
          grades.map((choice) => (
            <Button key={choice.grade} variant={choice.grade === 'good' ? 'cloth' : 'plate'} className={styles.key} onClick={() => answer(choice)}>
              <span>{choice.name}</span>
              <span className={styles.wait}>{choice.wait}</span>
            </Button>
          ))
        ) : (
          <Button variant="cloth" className={`${styles.key} ${styles.wide}`} onClick={() => turnOver('show')}>
            Show Answer
          </Button>
        )}
      </div>
      <p className="visually-hidden" role="status">
        {said}
      </p>
    </figure>
  )
}

function Leaf({ turn, drop }: { turn: number; drop: number }) {
  return (
    <motion.span
      className={styles.leaf}
      aria-hidden="true"
      initial={{ rotate: 0, y: 0 }}
      whileInView={{ rotate: turn, y: drop }}
      viewport={{ once: true, amount: 0.6 }}
      transition={{ ...lively, delay: 0.2 }}
    >
      <IndexCard className={styles.leafCard}>{null}</IndexCard>
    </motion.span>
  )
}

function Face({ side }: { side: Side }) {
  if (!side.clipping) return <>{side.says}</>
  const taped = side.clipping !== 'ink'
  return (
    <span className={styles.clipping} role="img" aria-label={side.says}>
      <Tape color={side.clipping === 'taped' ? 'mustard' : 'sage'} className={styles.holder} />
      <span className={styles.scrap}>
        {taped ? (
          <>
            <Written line={pulls} />
            <span className={styles.cover}>
              <Written line={tides} />
              <Tape color="rose" lifted={side.clipping === 'lifted'} className={styles.over} />
            </span>
          </>
        ) : (
          <Written line={light} />
        )}
      </span>
    </span>
  )
}
