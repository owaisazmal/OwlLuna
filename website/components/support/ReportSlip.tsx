'use client'

import { motion, useInView } from 'motion/react'
import { useId, useRef } from 'react'
import { ease, landing } from '@/lib/motion'
import { useStill } from '@/components/ui/useStill'
import { Tape } from '../ui/Tape'
import styles from './ReportSlip.module.css'

const lines = [
  { label: 'The device model' },
  { label: 'The iPadOS, iOS or macOS version' },
  { label: 'The app’s version', where: 'Settings › About in the app' },
  { label: 'What you did' },
  { label: 'What happened' },
]

const box = 'M4,13.5 L19.5,13 L20,29 L4.5,29.5 Z'
const tick = 'M6.5,20 L12,27 L24.5,7.5'
const firstTick = 0.5
const tickGap = 0.16
const stampLands = firstTick + tickGap * lines.length + 0.12

/** A ruled slip taped to the page: what a report should say, ticked off by hand and stamped. */
export function ReportSlip() {
  const stage = useRef<HTMLDivElement>(null)
  const inView = useInView(stage, { once: true, amount: 0.35 })
  const heading = useId()
  const still = useStill()

  return (
    <div ref={stage} className={styles.stage}>
      <noscript>
        <style>{`[data-slip-ink]{opacity:1!important;transform:none!important;stroke-dasharray:none!important}`}</style>
      </noscript>
      <motion.div className={`print ${styles.slip}`} initial={{ rotate: 0 }} animate={{ rotate: inView ? -1.2 : 0 }} transition={landing}>
        <motion.span
          data-slip-ink
          className={styles.tape}
          initial={{ opacity: 0, y: -18, rotate: -16 }}
          animate={inView ? { opacity: 1, y: 0, rotate: -4 } : { opacity: 0, y: -18, rotate: -16 }}
          transition={{ ...landing, delay: 0.12, opacity: { duration: 0.12, delay: 0.12 } }}
        >
          <Tape className={styles.strip} />
        </motion.span>
        <span className={styles.margin} aria-hidden="true" />
        {[0, 1, 2].map((index) => (
          <span key={index} className={`${styles.hole} ${styles[`hole${index}`]}`} aria-hidden="true" />
        ))}

        <p id={heading} className={styles.head}>
          What to put in a report
        </p>
        <ul className={styles.lines} aria-labelledby={heading}>
          {lines.map((line, index) => (
            <li key={line.label} className={styles.line}>
              <svg className={styles.check} viewBox="0 4 28 28" width="26" height="26" aria-hidden="true">
                <path d={box} className={styles.box} />
                <motion.path
                  data-slip-ink
                  d={tick}
                  className={styles.tick}
                  initial={{ pathLength: 0, opacity: 0 }}
                  animate={inView ? { pathLength: 1, opacity: 1 } : { pathLength: 0, opacity: 0 }}
                  transition={
                    still
                      ? { duration: 0 }
                      : {
                          duration: 0.2,
                          ease: ease.standard,
                          delay: firstTick + tickGap * index,
                          opacity: { duration: 0.01, delay: firstTick + tickGap * index },
                        }
                  }
                />
              </svg>
              <span className={styles.label}>
                {line.label}
                {line.where ? <span className={styles.where}>{line.where}</span> : null}
              </span>
            </li>
          ))}
        </ul>
        <p className={styles.foot}>For a drawing problem, say what you drew with: an Apple Pencil, a finger, a trackpad or a mouse.</p>

        <motion.span
          data-slip-ink
          className={styles.seat}
          aria-hidden="true"
          initial={{ scale: 2, opacity: 0 }}
          animate={inView ? { scale: [2, 0.92, 1], opacity: [0, 1, 1] } : { scale: 2, opacity: 0 }}
          transition={{ duration: 0.3, times: [0, 0.55, 1], ease: ['easeIn', 'easeOut'], delay: stampLands }}
        >
          <span className={styles.stamp}>Public</span>
        </motion.span>
      </motion.div>
    </div>
  )
}
