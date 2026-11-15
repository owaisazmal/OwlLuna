import { site } from '@/lib/site'
import { Away } from '../ui/Button'
import { Panel, PanelRow } from '../ui/Panel'
import { Reveal } from '../ui/Reveal'
import { SectionHeading } from '../ui/SectionHeading'
import { LaserPage } from './more/LaserPage'
import { SearchDemo } from './more/SearchDemo'
import { WeekStrip } from './more/WeekStrip'
import { WidgetPlates } from './more/WidgetPlates'
import styles from './More.module.css'

const papers = [
  { name: 'Import', text: 'Open a PDF as a notebook of its own, or insert it into one you have, and write on it.' },
  { name: 'Select text', text: 'Drag across a PDF’s own text to copy it, or highlight it in yellow, green, pink or blue.' },
  { name: 'Scan', text: 'The camera finds the paper, straightens and crops it, and each sheet becomes a page you can write on.' },
  { name: 'Export', text: 'A notebook as a PDF, pages as PNG images, or one page as a time-lapse video of it being written.' },
]

const outside = [
  { name: 'Widgets', text: 'Continue Writing, This Week, Today’s Page and Quick Note on the Home Screen, with Lock Screen versions.' },
  { name: 'Control Center', text: 'Buttons for Quick Note and Today’s Page.' },
  { name: 'Shortcuts and Siri', text: 'Open today’s journal page, start a quick note, continue writing, or open a notebook by name.' },
]

const languages = [
  { code: 'en', name: 'English' },
  { code: 'es', name: 'Español' },
  { code: 'fr', name: 'Français' },
  { code: 'de', name: 'Deutsch' },
]

const still = '[data-more-art] [data-drawn]{transform:none!important;opacity:1!important;stroke-dasharray:none!important}'

/** Everything the other feature sections leave out, as a grid of small cards. */
export function More() {
  return (
    <section className="section" id="more" aria-labelledby="more-heading">
      <noscript>
        <style>{still}</style>
      </noscript>
      <div className="wrap">
        <Reveal>
          <SectionHeading eyebrow="Everything else" title="And the rest" id="more-heading">
            <p>PDFs and scans, search, presenting, a writing history, widgets, backup and languages. A few lines on each.</p>
          </SectionHeading>
        </Reveal>

        <div className={styles.grid}>
          <Reveal className={`${styles.cell} ${styles.wide}`} tilt={-0.8}>
            <article className={`plate ${styles.card} ${styles.search}`}>
              <div className={styles.words}>
                <h3 className={`display ${styles.title}`}>Search</h3>
                <p className={styles.text}>
                  Search looks through titles, handwriting, typed text, PDF text, the print on scans and what was said
                  in transcribed recordings. Handwriting is read on your device, and each result opens at the matching
                  page.
                </p>
                <p className={styles.text}>
                  Find in a notebook marks every place the words appear and steps from one to the next. Spotlight finds
                  notebooks from the Home Screen by their title or the words in them, unless you turn it off in{' '}
                  <span className={styles.path}>Settings › Search</span>.
                </p>
                <dl className={styles.keys}>
                  <div>
                    <dt>⌘F</dt>
                    <dd>Find in a notebook</dd>
                  </div>
                  <div>
                    <dt>⌘G</dt>
                    <dd>The next match</dd>
                  </div>
                </dl>
              </div>
              <div className={styles.stage}>
                <SearchDemo />
              </div>
            </article>
          </Reveal>

          <Reveal className={styles.cell} delay={0.06} tilt={0.8}>
            <Panel title="PDFs and scans" className={styles.panel}>
              {papers.map((row, index) => (
                <PanelRow key={row.name} className={styles.row}>
                  {index === 0 ? <h3 className="visually-hidden">PDFs and scans</h3> : null}
                  <p className={styles.rowName}>{row.name}</p>
                  <p className={styles.rowText}>{row.text}</p>
                  {row.name === 'Export' ? (
                    <ul className={styles.formats} aria-label="Export formats">
                      <li>PDF</li>
                      <li>PNG</li>
                      <li>Video</li>
                    </ul>
                  ) : null}
                </PanelRow>
              ))}
            </Panel>
          </Reveal>

          <Reveal className={styles.cell} tilt={-0.8}>
            <article className={`plate ${styles.card}`}>
              <div className={`print ${styles.art} ${styles.artInk}`} data-more-art>
                <LaserPage />
              </div>
              <div className={styles.words}>
                <h3 className={`display ${styles.title}`}>Presenting</h3>
                <p className={styles.text}>
                  Present shows one whole page at a time. The Pencil becomes a laser pointer with a fading tail, in red
                  or green, and nothing it draws is saved.
                </p>
                <p className={styles.text}>
                  Attach a second screen and the page and the laser go there, while the controls and your presenter
                  notes stay on the iPad.
                </p>
                <p className={styles.plain}>The audience only ever sees the page.</p>
              </div>
            </article>
          </Reveal>

          <Reveal className={styles.cell} delay={0.06}>
            <article className={`plate ${styles.card}`}>
              <div className={`print ${styles.art} ${styles.artMoon}`} data-more-art>
                <WeekStrip />
              </div>
              <div className={styles.words}>
                <h3 className={`display ${styles.title}`}>Writing history</h3>
                <p className={styles.text}>
                  A This-week strip in the library: seven small sheets, inked on the days you wrote. A writing
                  calendar, laid out like a printed diary, opens the exact pages you wrote on any day.
                </p>
                <p className={styles.text}>
                  The history is a small file on your device that is never synced, and{' '}
                  <span className={styles.path}>Settings › Writing History</span> turns it off or clears it.
                </p>
                <p className={styles.plain}>No streaks, badges or reminders.</p>
              </div>
            </article>
          </Reveal>

          <Reveal className={styles.cell} delay={0.12} tilt={0.8}>
            <article className={`plate ${styles.card}`}>
              <div className={`print ${styles.art} ${styles.artTomato}`} data-more-art>
                <WidgetPlates />
              </div>
              <div className={styles.words}>
                <h3 className={`display ${styles.title}`}>Widgets and shortcuts</h3>
                <dl className={styles.list}>
                  {outside.map((row) => (
                    <div key={row.name}>
                      <dt className={styles.rowName}>{row.name}</dt>
                      <dd className={styles.rowText}>{row.text}</dd>
                    </div>
                  ))}
                </dl>
              </div>
            </article>
          </Reveal>

          <Reveal className={`${styles.cell} ${styles.wide}`} tilt={-0.8}>
            <Panel title="Backup and sync" className={styles.panel}>
              <div className={styles.pair}>
                <div className={styles.half}>
                  <h3 className="visually-hidden">Backup and iCloud sync</h3>
                  <p className={styles.rowName}>Backup</p>
                  <p className={styles.rowText}>
                    <span className={styles.path}>Settings › Backup</span> puts the whole library into one file, to
                    restore on this or another device. Restoring adds what is missing and never replaces a notebook: one
                    that differs from the backup comes back beside yours as a copy.
                  </p>
                  <p className={styles.rowText}>It carries your flashcards, smart shelves and writing history with it.</p>
                </div>
                <div className={styles.half}>
                  <p className={styles.rowName}>iCloud sync</p>
                  <p className={styles.rowText}>
                    Sync between your devices asks before it starts, and{' '}
                    <span className={styles.path}>Settings › iCloud</span> has the switch. Each notebook is copied whole,
                    and one changed on two devices keeps both versions.
                  </p>
                  <p className={styles.rowText}>
                    It has been tested on real iCloud, between iPads on one Apple Account. As with any sync, a backup
                    first is a good habit.
                  </p>
                </div>
              </div>
            </Panel>
          </Reveal>

          <Reveal className={styles.cell} delay={0.06} tilt={0.8}>
            <article className={`plate ${styles.card}`}>
              <div className={styles.words}>
                <h3 className={`display ${styles.title}`}>Languages</h3>
                <ul className={styles.tags}>
                  {languages.map((language) => (
                    <li key={language.code} className={`print ${styles.tag}`} lang={language.code}>
                      {language.name}
                    </li>
                  ))}
                </ul>
                <p className={styles.text}>
                  English, Spanish, French and German, including the widgets, the Siri phrases and the permission
                  prompts. The translations have not been reviewed by native speakers yet, and{' '}
                  <a href={site.issues} target="_blank" rel="noopener noreferrer" className={styles.link}>
                    corrections are welcome
                    <Away />
                  </a>
                  .
                </p>
              </div>
            </article>
          </Reveal>

          <Reveal className={`${styles.cell} ${styles.last}`}>
            <article className={`plate ${styles.needs}`}>
              <h3 className={styles.needsName}>Requirements</h3>
              <dl className={styles.needsRows}>
                <div className={styles.need}>
                  <dt className={styles.needName}>iPad</dt>
                  <dd className={`display-text ${styles.needValue}`}>iPadOS 18 or later</dd>
                </div>
                <div className={styles.need}>
                  <dt className={styles.needName}>iPhone</dt>
                  <dd className={`display-text ${styles.needValue}`}>iOS 18 or later</dd>
                </div>
                <div className={styles.need}>
                  <dt className={styles.needName}>Mac</dt>
                  <dd className={`display-text ${styles.needValue}`}>macOS 26 or later</dd>
                </div>
              </dl>
            </article>
          </Reveal>
        </div>
      </div>
    </section>
  )
}
