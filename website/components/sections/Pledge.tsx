import type { ReactNode } from 'react'
import { site } from '@/lib/site'
import { Reveal } from '../ui/Reveal'
import { TickBox } from './story/TickBox'
import styles from './Pledge.module.css'

const terms: { field: string; answer: string; detail: ReactNode }[] = [
  { field: 'Price', answer: 'Free', detail: 'No subscription, no one-time fee, nothing to unlock.' },
  {
    field: 'Code',
    answer: 'Open source',
    detail: (
      <>
        Released under the MIT License. The code is on <a href={site.repo}>GitHub</a>.
      </>
    ),
  },
  {
    field: 'Your notes',
    answer: 'Private',
    detail: 'No accounts, no analytics, no ads. Handwriting and speech are read on your device.',
  },
  {
    field: 'Made with',
    answer: 'Apple frameworks only',
    detail: 'SwiftUI, PencilKit, PDFKit, Vision and SwiftData. No third-party code.',
  },
]

/** The four terms the app is offered on, as one ruled board ticked by hand. */
export function Pledge() {
  return (
    <section className="section-tight" aria-labelledby="pledge-title">
      <div className="wrap">
        <h2 id="pledge-title" className="visually-hidden">
          OwlLuna in four lines
        </h2>
        <Reveal>
          <ul className={`plate ${styles.board}`}>
            {terms.map((term, index) => (
              <li key={term.field} className={styles.term}>
                <div className={styles.field}>
                  <span className="meta">{term.field}</span>
                  <TickBox className={styles.tick} delay={0.25 + index * 0.14} />
                </div>
                <h3 className={`display ${styles.answer}`}>{term.answer}</h3>
                <p className={styles.detail}>{term.detail}</p>
              </li>
            ))}
          </ul>
        </Reveal>
      </div>
    </section>
  )
}
