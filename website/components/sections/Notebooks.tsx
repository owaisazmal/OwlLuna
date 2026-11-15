import { Ledger, LedgerRow } from '../ui/Ledger'
import { Reveal } from '../ui/Reveal'
import { SectionHeading } from '../ui/SectionHeading'
import { LockedBoard } from './notebooks/covers'
import { JournalPage } from './notebooks/JournalPage'
import { PaperDrawer } from './notebooks/PaperDrawer'
import { Shelf } from './notebooks/Shelf'
import { Sidebar } from './notebooks/Sidebar'
import styles from './Notebooks.module.css'

const notes = [
  {
    title: 'Three kinds of cover',
    text: 'Cloth, Print with the look of riso, or the notebook’s own first page. A cover can be changed at any time.',
  },
  {
    title: 'Starters for a new notebook',
    text: 'New Notebook offers Journal, Whiteboard, Lecture, Sketchbook, Planner, Music and Plain, and Shuffle deals a fresh cover.',
  },
  {
    title: 'Favourites and sorting',
    text: 'Touch and hold a notebook and choose Favourite to keep it close to hand, and sort the shelf by last opened, modified, created or title.',
  },
]

/** Notebooks and paper: covers on a shelf, the paper drawer, and how the library is kept in order. */
export function Notebooks() {
  return (
    <section id="notebooks" className="section" aria-labelledby="notebooks-title">
      <div className="wrap">
        <SectionHeading eyebrow="Notebooks and paper" title="Fourteen kinds of paper, bound in cloth." id="notebooks-title">
          <p>Choose the paper a page needs, give the notebook a cover, and shelve it where you will find it again.</p>
        </SectionHeading>

        <div className={styles.covers}>
          <Shelf />
          <ul className={styles.notes}>
            {notes.map((note, index) => (
              <li key={note.title}>
                <Reveal delay={index * 0.06} className={styles.note}>
                  <h3 className={`display ${styles.noteTitle}`}>{note.title}</h3>
                  <p className={styles.text}>{note.text}</p>
                </Reveal>
              </li>
            ))}
          </ul>
        </div>

        <div className={`${styles.block} ${styles.paper}`}>
          <Reveal className={styles.words}>
            <h3 className={`display ${styles.heading}`}>A drawer of paper</h3>
            <p className={styles.text}>
              The paper drawer shows real miniatures. Add a page with any paper, or change the paper and colour of a page in place and undo it if you
              think better of it.
            </p>
            <Ledger className={styles.spec}>
              <LedgerRow label="Templates">Fourteen, in four families: writing, grids, planning and creative.</LedgerRow>
              <LedgerRow label="Colours">Nine, from white to chalkboard, where the ink writes chalk-white.</LedgerRow>
              <LedgerRow label="Page sizes">US Letter, A4, A5 and widescreen.</LedgerRow>
            </Ledger>
          </Reveal>
          <Reveal delay={0.08} className={styles.art}>
            <PaperDrawer />
          </Reveal>
        </div>

        <div className={`${styles.block} ${styles.order}`}>
          <Reveal className={styles.words}>
            <h3 className={`display ${styles.heading}`}>Folders, tags and smart shelves</h3>
            <Ledger className={styles.spec}>
              <LedgerRow label="Folders">
                Each has a spine colour, and folders go inside folders. Drag notebooks onto them in the sidebar, reorder them, and fold a folder’s own
                folders away.
              </LedgerRow>
              <LedgerRow label="Tags">
                Tag a notebook or a single page and the tag gets a shelf in the sidebar, with the notebooks that carry it and the tagged pages under
                them.
              </LedgerRow>
              <LedgerRow label="Smart shelves">A saved filter: everything tagged with any, or all, of the tags you choose.</LedgerRow>
            </Ledger>
          </Reveal>
          <Reveal delay={0.08} className={styles.art}>
            <Sidebar />
          </Reveal>
        </div>

        <div className={`${styles.block} ${styles.pair}`}>
          <Reveal className={styles.cell}>
            <article className={styles.tile}>
              <div className={styles.plate}>
                <JournalPage />
              </div>
              <div className={styles.caption}>
                <h3 className={`display ${styles.tileTitle}`}>A daily journal</h3>
                <p className={styles.text}>
                  Today’s page is printed with the date, and On this day brings back the page from a month or a year ago.
                </p>
              </div>
            </article>
          </Reveal>
          <Reveal delay={0.08} className={styles.cell}>
            <article className={styles.tile}>
              <div className={styles.plate}>
                <LockedBoard color="oxblood" />
              </div>
              <div className={styles.caption}>
                <h3 className={`display ${styles.tileTitle}`}>Locked notebooks</h3>
                <p className={styles.text}>
                  A locked notebook asks for Face ID, Touch ID or your passcode (your password on a Mac) every time it is opened, and what is written
                  in it is left out of search.
                </p>
                <p className={styles.caveat}>
                  <span className="meta">Worth knowing</span>A lock keeps a notebook closed in the app. It does not encrypt its files.
                </p>
              </div>
            </article>
          </Reveal>
        </div>
      </div>
    </section>
  )
}
