import type { ReactNode } from 'react'
import styles from './Ledger.module.css'

/** A run of rows ruled in ink, under a heavy rule and the run's name. */
export function Ledger({ title, children, className }: { title?: string; children: ReactNode; className?: string }) {
  return (
    <div className={[styles.ledger, className].filter(Boolean).join(' ')}>
      {title ? <div className={styles.band}>{title}</div> : null}
      <dl className={styles.rows}>{children}</dl>
    </div>
  )
}

type RowProps = {
  label: ReactNode
  children: ReactNode
  /** A mark at the row's leading end. */
  mark?: 'none' | 'check' | 'cross'
}

export function LedgerRow({ label, children, mark = 'none' }: RowProps) {
  return (
    <div className={styles.row}>
      <dt className={styles.label}>
        {mark !== 'none' ? <Mark kind={mark} /> : null}
        <span>{label}</span>
      </dt>
      <dd className={styles.value}>{children}</dd>
    </div>
  )
}

function Mark({ kind }: { kind: 'check' | 'cross' }) {
  return (
    <svg className={[styles.mark, styles[kind]].join(' ')} viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">
      {kind === 'check' ? <path d="M3 8.5 6.5 12 13 4.5" /> : null}
      {kind === 'cross' ? <path d="M4 4l8 8M12 4l-8 8" /> : null}
    </svg>
  )
}
