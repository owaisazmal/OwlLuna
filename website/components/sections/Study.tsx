import { IndexCard } from '../ui/IndexCard'
import { Ledger, LedgerRow } from '../ui/Ledger'
import { Reveal } from '../ui/Reveal'
import { SectionHeading } from '../ui/SectionHeading'
import { Tape } from '../ui/Tape'
import { CardPile } from './study/CardPile'
import { Drop } from './study/Drop'
import { Replay } from './study/Replay'
import { TapeSheet } from './study/TapeSheet'
import styles from './Study.module.css'

const tapes = ['mustard', 'rose', 'sage', 'sky'] as const

const keyPoints = [
  'The main points of a page, a whole notebook or a recording’s transcript.',
  'Practice questions with their answers, which you can save as flashcards.',
  'A summary you can add to the page as a text box.',
]

/** Studying and audio: study tape, flashcards and the study guide, then a recording replayed with its ink. */
export function Study() {
  return (
    <>
      <noscript>
        <style>{`[data-study-art]{opacity:1!important;transform:none!important;stroke-dasharray:none!important}`}</style>
      </noscript>

      <section className="section" id="studying" aria-labelledby="studying-title">
        <div className="wrap">
          <Reveal>
            <SectionHeading eyebrow="Studying" id="studying-title" title="Cover the answer, then see if you knew it.">
              <p>Hide part of a page under study tape, make flashcards from it, and each card comes back later the better you knew it.</p>
            </SectionHeading>
          </Reveal>

          <div className={styles.blocks}>
            <div className={styles.block}>
              <Reveal className={styles.art} tilt={-1.5}>
                <TapeSheet />
              </Reveal>
              <Reveal className={styles.copy} delay={0.08}>
                <p className="meta">Study tape</p>
                <h3 className={`display ${styles.title}`}>Tape over the answer</h3>
                <p>
                  Study tape is a strip of washi tape in four colours. It covers what is under it, ink included. Tap it to lift it and tap again to put
                  it back, with a finger or Apple Pencil.
                </p>
                <p>Lifting is for looking and is never saved, so every strip is back in place the next time you open the notebook.</p>
                <ul className={styles.tapes} aria-label="The four colours of study tape">
                  {tapes.map((color) => (
                    <li key={color} className={styles.swatch}>
                      <Tape color={color} className={styles.tape} />
                      <span className="meta">{color}</span>
                    </li>
                  ))}
                </ul>
              </Reveal>
            </div>

            <div className={`${styles.block} ${styles.turned}`}>
              <Reveal className={styles.art} tilt={1.5}>
                <CardPile />
              </Reveal>
              <Reveal className={styles.copy} delay={0.08}>
                <p className="meta">Flashcards</p>
                <h3 className={`display ${styles.title}`}>Every notebook can hold a deck</h3>
                <Ledger title="Making a card">
                  <LedgerRow label="Study tape">
                    The question is that part of the page with the tape on. The answer is the same part with the tape lifted.
                  </LedgerRow>
                  <LedgerRow label="Handwriting">Select it and it is clipped onto a card as it looks on its paper.</LedgerRow>
                  <LedgerRow label="Your own">Or write a card yourself.</LedgerRow>
                </Ledger>
                <p>
                  After turning a card over you say Again, Good or Easy, and it comes back later the better you knew it: tomorrow, then in three days,
                  then in about a week, and so on up to a year. A card you forgot comes round again in the same sitting.
                </p>
              </Reveal>
            </div>

            <div className={styles.block}>
              <Reveal className={styles.art} tilt={-1.5}>
                <div className={styles.guide}>
                  <div className={styles.leaf}>
                    <p className="caps">What a study guide gives you</p>
                    <p className={`app-display ${styles.leafTitle}`}>Key Points</p>
                    <ol className={styles.keys} role="list">
                      {keyPoints.map((point, index) => (
                        <li key={point} className={styles.key}>
                          <span className={`app-display ${styles.numeral}`} aria-hidden="true">
                            {index + 1}
                          </span>
                          <span>{point}</span>
                        </li>
                      ))}
                    </ol>
                    <p className={styles.footnote}>
                      <svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true">
                        <path d="M5 7V5a3 3 0 0 1 6 0v2" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" />
                        <rect x="3" y="7" width="10" height="7.5" rx="1.5" fill="currentColor" />
                      </svg>
                      Written on the iPad itself, by Apple Intelligence.
                    </p>
                  </div>
                  <Drop className={styles.question}>
                    <IndexCard side="Practice question" className={styles.card}>
                      <span className={styles.asked}>And on an iPad without Apple Intelligence?</span>
                      <span className={styles.answered}>The sheet says so and nothing else happens.</span>
                    </IndexCard>
                  </Drop>
                </div>
              </Reveal>
              <Reveal className={styles.copy} delay={0.08}>
                <p className="meta">Study guide</p>
                <h3 className={`display ${styles.title}`}>The main points, written on the iPad</h3>
                <p>
                  A study guide is the main points of what you wrote, and practice questions to go with them. Apple Intelligence writes it on the iPad
                  itself, so it needs iPadOS 26 or later and an iPad with Apple Intelligence turned on.
                </p>
              </Reveal>
            </div>
          </div>
        </div>
      </section>

      <section className="section" id="audio" aria-labelledby="audio-title">
        <div className="wrap">
          <Reveal>
            <SectionHeading eyebrow="Audio" id="audio-title" title="Play the lecture back and watch your notes arrive.">
              <p>Record lectures or meetings alongside a notebook, and play them back later.</p>
            </SectionHeading>
          </Reveal>

          <Reveal className={styles.stage}>
            <Replay />
          </Reveal>

          <div className={styles.points}>
            <Reveal className={styles.point}>
              <h3 className="meta">Replay with your ink</h3>
              <p>What you wrote during a recording is faint until the sound reaches the moment you wrote it, and the page turns to follow the writing.</p>
            </Reveal>
            <Reveal className={styles.point} delay={0.07}>
              <h3 className="meta">Tap ink to jump</h3>
              <p>Tapping ink jumps the sound to when it was written. In a transcript, tap a line to hear it with the ink you wrote as it was said.</p>
            </Reveal>
            <Reveal className={styles.point} delay={0.14}>
              <h3 className="meta">Transcribed on the device</h3>
              <p>
                Ask for a transcript and the recording is written down on the iPad, never on a server. If the iPad can’t transcribe a language on the
                device, the app says so and sends nothing.
              </p>
            </Reveal>
          </div>
        </div>
      </section>
    </>
  )
}
