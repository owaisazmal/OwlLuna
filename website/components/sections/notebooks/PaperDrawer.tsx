'use client'

import { motion } from 'motion/react'
import { useId, useRef, useState, type CSSProperties } from 'react'
import { ease, quick } from '@/lib/motion'
import { Panel } from '../../ui/Panel'
import { colours, families, sheet } from './papers'
import { useArrival } from '@/components/ui/useArrival'
import { useStill } from '@/components/ui/useStill'
import styles from './PaperDrawer.module.css'

const order = new Map(families.flatMap((family) => family.templates).map((template, index) => [template.name, index]))
const lean = (index: number) => (index % 2 === 0 ? -3 : 3)

/** The paper drawer: every template as a miniature sheet, repapered by the colour swatches above it. */
export function PaperDrawer() {
  const root = useRef<HTMLDivElement>(null)
  const { arrived: play } = useArrival(root, { amount: 0.2 })
  const still = useStill()
  const label = useId()
  const [colour, setColour] = useState(colours[0])
  const [deal, setDeal] = useState(0)

  const choose = (next: (typeof colours)[number]) => {
    if (next.id === colour.id) return
    setColour(next)
    setDeal((count) => count + 1)
  }

  return (
    <Panel title="Paper drawer" note={colour.name}>
      <div ref={root} className={styles.drawer} data-ink={colour.ink} style={{ '--p-fill': colour.fill } as CSSProperties}>
        <div className={styles.colours}>
          <p className={`caps ${styles.label}`} id={label}>
            Colour
          </p>
          <div className={styles.swatches} role="group" aria-labelledby={label}>
            {colours.map((option) => {
              const chosen = option.id === colour.id
              return (
                <button key={option.id} type="button" className={styles.swatch} aria-pressed={chosen} onClick={() => choose(option)}>
                  <span className={styles.chip} data-ink={option.ink} style={{ backgroundColor: option.fill }}>
                    <svg className={styles.check} viewBox="0 0 16 16" aria-hidden="true">
                      <motion.path
                        d="M3 8.5 6.5 12 13 4.5"
                        initial={false}
                        animate={{ pathLength: chosen ? 1 : 0, opacity: chosen ? 1 : 0 }}
                        transition={still ? { duration: 0 } : { pathLength: { duration: chosen ? 0.24 : 0, ease: ease.glide }, opacity: { duration: 0.01 } }}
                      />
                    </svg>
                  </span>
                  <span className={styles.swatchName} data-name={option.name}>
                    {option.name}
                  </span>
                </button>
              )
            })}
          </div>
          <p className="visually-hidden" role="status">
            {`Paper colour: ${colour.name}`}
          </p>
        </div>
        <div className={styles.tray}>
          {families.map((family) => (
            <div key={family.name} className={styles.bay} style={{ '--n': family.templates.length } as CSSProperties}>
              <h4 className={`caps ${styles.label}`}>{family.name}</h4>
              <ul className={styles.sheets}>
                {family.templates.map((template) => {
                  const index = order.get(template.name) ?? 0
                  return (
                    <li key={template.name} className={styles.paper}>
                      <motion.span
                        key={deal}
                        className={`print ${styles.sheet}`}
                        initial={deal === 0 ? false : { y: -12, rotate: lean(index) }}
                        animate={play ? { y: 0, rotate: 0, opacity: 1 } : { y: -18, rotate: lean(index), opacity: 0 }}
                        transition={play ? { ...quick, delay: index * 0.022, opacity: { duration: 0.16, delay: index * 0.022 } } : { duration: 0 }}
                      >
                        <svg className={styles.sheetArt} viewBox={`0 0 ${sheet.width} ${sheet.height}`} aria-hidden="true">
                          {template.art}
                        </svg>
                      </motion.span>
                      <span className={styles.paperName}>{template.name}</span>
                    </li>
                  )
                })}
              </ul>
            </div>
          ))}
        </div>
      </div>
    </Panel>
  )
}
