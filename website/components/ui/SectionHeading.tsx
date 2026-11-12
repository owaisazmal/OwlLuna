import type { ReactNode } from 'react'
import styles from './SectionHeading.module.css'

type Props = {
  /** The label over the heading. */
  eyebrow: string
  title: ReactNode
  children?: ReactNode
  id?: string
  as?: 'h1' | 'h2'
}

/** A section's heading: a heavy rule, a label, a bold line and a lede. */
export function SectionHeading({ eyebrow, title, children, id, as: Tag = 'h2' }: Props) {
  return (
    <header className={styles.heading}>
      <p className={`meta ${styles.eyebrow}`}>{eyebrow}</p>
      <Tag id={id} className={`display ${styles.title}`}>
        {title}
      </Tag>
      {children ? <div className={`lede ${styles.lede}`}>{children}</div> : null}
    </header>
  )
}
