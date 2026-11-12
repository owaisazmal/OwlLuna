'use client'

import { motion, useReducedMotion } from 'motion/react'
import { useId, useRef, useState, type CSSProperties } from 'react'
import { ease } from '@/lib/motion'
import { clothColors, type ClothColor } from '../../ui/ClothCover'
import styles from './Sidebar.module.css'

const inside: { name: string; cloth: ClothColor; count: number }[] = [
  { name: 'Chemistry', cloth: 'moss', count: 5 },
  { name: 'Statistics', cloth: 'mustard', count: 4 },
]

const tags = ['exam', 'revision', 'lab', 'ideas', 'to scan']

const stroke = { fill: 'none', stroke: 'currentColor', strokeWidth: 1.7, strokeLinecap: 'round', strokeLinejoin: 'round' } as const

function Spine({ cloth }: { cloth: ClothColor }) {
  return <span className={styles.spine} style={{ '--cloth': clothColors[cloth] } as CSSProperties} aria-hidden="true" />
}

/** The library's sidebar, drawn: shelves, a folder that folds away, a smart shelf and tags. */
export function Sidebar() {
  const frame = useRef<HTMLElement>(null)
  const [open, setOpen] = useState(true)
  const [floor, setFloor] = useState<number>()
  const reduced = useReducedMotion()
  const list = useId()
  const fold = reduced ? { duration: 0 } : { duration: 0.28, ease: ease.glide }

  const toggle = () => {
    if (open) setFloor(frame.current?.offsetHeight)
    setOpen(!open)
  }

  return (
    <figure ref={frame} className={styles.sidebar} style={{ minHeight: floor }} aria-label="The library's sidebar">
      <p className={`app-display ${styles.title}`}>OwlLuna</p>

      <ul className={styles.rows}>
        <li className={`cloth ${styles.row} ${styles.chosen}`}>
          <svg className={styles.icon} viewBox="0 0 20 20" aria-hidden="true">
            <path {...stroke} d="M4 3.5h3v13H4zM8.5 3.5h3v13h-3zM13.2 5.2l2.8-.8 2.4 11.4-2.8.8z" />
          </svg>
          <span className={styles.name}>All notebooks</span>
          <span className={styles.count}>27</span>
        </li>
        <li className={styles.row}>
          <svg className={styles.icon} viewBox="0 0 20 20" aria-hidden="true">
            <path {...stroke} d="M10 2.8l2.2 4.6 5 .7-3.6 3.5.9 5-4.5-2.4-4.5 2.4.9-5L2.8 8.1l5-.7z" />
          </svg>
          <span className={styles.name}>Favourites</span>
          <span className={styles.count}>4</span>
        </li>
      </ul>

      <p className={`caps ${styles.head}`}>Shelves</p>
      <ul className={styles.rows}>
        <li>
          <button type="button" className={`${styles.row} ${styles.folder}`} aria-expanded={open} aria-controls={list} aria-label="University, 12 notebooks, folder" onClick={toggle}>
            <Spine cloth="navy" />
            <span className={styles.name}>University</span>{' '}
            <span className={styles.count}>12</span>
            <motion.svg className={styles.chevron} viewBox="0 0 14 14" aria-hidden="true" initial={false} animate={{ rotate: open ? 0 : -90 }} transition={fold}>
              <path {...stroke} strokeWidth="2" d="M3 5l4 4 4-4" />
            </motion.svg>
          </button>
          <motion.ul
            id={list}
            className={styles.inside}
            aria-hidden={!open}
            initial={false}
            animate={{ height: open ? 'auto' : 0, opacity: open ? 1 : 0 }}
            transition={fold}
            onAnimationComplete={() => {
              if (open) setFloor(undefined)
            }}
          >
            {inside.map((folder) => (
              <li key={folder.name} className={`${styles.row} ${styles.nested}`}>
                <Spine cloth={folder.cloth} />
                <span className={styles.name}>{folder.name}</span>
                <span className={styles.count}>{folder.count}</span>
              </li>
            ))}
          </motion.ul>
        </li>
        <li className={styles.row}>
          <Spine cloth="tomato" />
          <span className={styles.name}>Sketches</span>
          <span className={styles.count}>6</span>
        </li>
        <li className={styles.row}>
          <Spine cloth="oat" />
          <span className={styles.name}>House</span>
          <span className={styles.count}>3</span>
        </li>
      </ul>

      <p className={`caps ${styles.head}`}>Smart shelves</p>
      <ul className={styles.rows}>
        <li className={styles.row}>
          <svg className={styles.icon} viewBox="0 0 20 20" aria-hidden="true">
            <path {...stroke} d="M3.5 6h13M6 10h8M8.5 14h3" />
          </svg>
          <span className={styles.name}>Exam week</span>
          <span className={styles.rule}>exam or revision</span>
        </li>
      </ul>

      <p className={`caps ${styles.head}`}>Tags</p>
      <ul className={styles.tags}>
        {tags.map((tag) => (
          <li key={tag} className={`print ${styles.tag}`}>
            <span className={styles.hole} aria-hidden="true" />
            {tag}
          </li>
        ))}
      </ul>
    </figure>
  )
}
