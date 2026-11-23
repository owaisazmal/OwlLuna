import type { Metadata } from 'next'
import type { ReactNode } from 'react'
import { Away, Button } from '@/components/ui/Button'
import { Ledger, LedgerRow } from '@/components/ui/Ledger'
import { Panel } from '@/components/ui/Panel'
import { SectionHeading } from '@/components/ui/SectionHeading'
import { Stamp } from '@/components/ui/Stamp'
import { formatDate, site } from '@/lib/site'
import styles from './privacy.module.css'

export const metadata: Metadata = {
  title: 'Privacy Policy',
  description:
    'OwlLuna collects nothing. What the app keeps on your device, what iCloud sync copies to your own iCloud storage, what each permission is for, and how to remove it all.',
}

const apple = {
  privacy: 'https://www.apple.com/legal/privacy/',
  icloud: 'https://support.apple.com/102651',
  features: 'https://www.apple.com/privacy/',
  testflight: 'https://www.apple.com/legal/privacy/data/en/test-flight/',
  data: 'https://privacy.apple.com/',
}
const github = 'https://docs.github.com/site-policy/privacy-policies/github-general-privacy-statement'
const history = `${site.repo}/commits/main/website/app/privacy/page.tsx`

const contents = [
  ['who', 'Who this is from'],
  ['collected', 'What I collect'],
  ['on-your-ipad', 'What the app keeps on your device'],
  ['icloud', 'iCloud sync'],
  ['permissions', 'Permissions'],
  ['on-device', 'What Apple’s frameworks do'],
  ['sending', 'What leaves when you send it'],
  ['locks', 'Locked notebooks'],
  ['deleting', 'Keeping and deleting'],
  ['children', 'Children'],
  ['apple-reports', 'What Apple tells me'],
  ['testflight', 'The TestFlight beta'],
  ['website', 'This website'],
  ['contact', 'Questions and requests'],
  ['changes', 'Changes to this policy'],
] as const

type SectionId = (typeof contents)[number][0]

function Part({ id, children }: { id: SectionId; children: ReactNode }) {
  const index = contents.findIndex(([key]) => key === id)
  return (
    <section id={id} className={styles.part} aria-labelledby={`${id}-title`}>
      <p className={`meta tabular ${styles.number}`}>{String(index + 1).padStart(2, '0')}</p>
      <h2 id={`${id}-title`} className={`display ${styles.partTitle}`}>
        {contents[index][1]}
      </h2>
      {children}
    </section>
  )
}

function Out({ href, children }: { href: string; children: ReactNode }) {
  return (
    <a href={href} target="_blank" rel="noopener noreferrer">
      {children}
      <span className="visually-hidden"> (opens in a new tab)</span>
    </a>
  )
}

export default function PrivacyPolicy() {
  return (
    <div className={`wrap ${styles.page}`}>
      <SectionHeading as="h1" eyebrow={`Privacy Policy · Last updated ${formatDate(site.policyUpdated)}`} title="OwlLuna collects nothing.">
        <p>
          OwlLuna is a notebook. It has no accounts, no analytics, no ads and no server of mine behind it, so it never
          sends me your notes or anything about you. This page says exactly what the app keeps, where it keeps it, and
          how to remove it.
        </p>
      </SectionHeading>

      <div className={styles.layout}>
        <aside className={styles.aside}>
          <Panel title="On this page" className={styles.contents}>
            <nav aria-label="On this page">
              <ol className={styles.contentsList}>
                {contents.map(([id, title], index) => (
                  <li key={id}>
                    <a href={`#${id}`}>
                      <span className="tabular">{String(index + 1).padStart(2, '0')}</span>
                      {title}
                    </a>
                  </li>
                ))}
              </ol>
            </nav>
          </Panel>
        </aside>

        <article className={styles.article}>
          <Ledger title="The short version" className={styles.short}>
            <LedgerRow label="Collected by the developer" mark="check">
              Nothing, apart from what <a href="#testflight">TestFlight</a> sends me while you test the beta: crash
              reports and details of your device, not your name or email address.
            </LedgerRow>
            <LedgerRow label="Accounts, analytics, ads, trackers" mark="check">
              None. The app contains no third-party code at all.
            </LedgerRow>
            <LedgerRow label="Where your notebooks are" mark="check">
              On your device. With iCloud on, a copy is kept in your own iCloud storage so your other devices have them.
              You can turn that off.
            </LedgerRow>
            <LedgerRow label="Handwriting, scans and speech" mark="check">
              Read on your device, by Apple&rsquo;s frameworks.
            </LedgerRow>
            <LedgerRow label="Removing everything" mark="check">
              Delete your notebooks or the app, and clear the app&rsquo;s data from your iCloud storage.
            </LedgerRow>
          </Ledger>

          <Part id="who">
            <p>
              OwlLuna is made by <Out href={site.author.url}>{site.author.name}</Out>, an independent developer. On this
              page &ldquo;I&rdquo; means me, and &ldquo;the app&rdquo; means OwlLuna for iPad and iPhone. The app also
              runs on a Mac, and it keeps and syncs your data the same way there. The Settings paths on this page, and
              what happens when the app is deleted, describe iPadOS and iOS.
            </p>
            <p>
              The app is open source under the MIT License, so everything said here can be checked against{' '}
              <Out href={site.repo}>the code</Out>.
            </p>
          </Part>

          <Part id="collected">
            <p className={styles.plain}>Nothing.</p>
            <ul className={styles.list} role="list">
              <li>The app has no account, sign-in or registration.</li>
              <li>
                It contains no analytics, no crash reporter, no advertising and no tracking. There is no third-party
                code in it of any kind, only Apple&rsquo;s own frameworks.
              </li>
              <li>
                It has no networking code of its own and no server to talk to. It has no way to send your notes to me
                or to anyone else.
              </li>
              <li>
                It does not read or create any identifier for you or for your device, with one exception that stays on
                the device. So that <a href="#icloud">iCloud sync</a> can notice a different Apple Account signing in, it
                keeps a scrambled marker made from the token the system gives the app for the signed-in iCloud account. The
                marker cannot be turned back into the account, tells one account from another and nothing more, and is
                never sent anywhere.
              </li>
              <li>It has nothing to buy, so it handles no payment details.</li>
            </ul>
            <p>
              That is why the app&rsquo;s privacy label on the App Store {site.appStoreUrl ? 'reads' : 'will read'}{' '}
              &ldquo;Data Not Collected&rdquo;.
            </p>
            <p>
              Testing the beta is the exception, because Apple&rsquo;s TestFlight passes some details to me: see{' '}
              <a href="#testflight">The TestFlight beta</a>.
            </p>
          </Part>

          <Part id="on-your-ipad">
            <p>Everything you make in OwlLuna is saved as files in the app&rsquo;s own storage on your device:</p>
            <ul className={styles.list} role="list">
              <li>
                <strong>Your notebooks.</strong> Handwriting (with the moment each stroke was made, which replay and
                the time-lapse use), typed text, pictures, scans, imported PDFs, audio recordings and their transcripts,
                flashcards and when you last reviewed them, tags, bookmarks, links, the page you left off on, and when
                you last locked, favourited, filed, tagged or deleted the notebook.
              </li>
              <li>
                <strong>The words read from your pages</strong> (handwriting, scans, PDFs, typed text and transcripts),
                so that search can find them.
              </li>
              <li>
                <strong>Your settings</strong>, pens, folders, smart shelves and the stickers you made.
              </li>
              <li>
                <strong>Your writing history.</strong> For each day, which pages you wrote on and how many flashcards
                you answered. It holds no text and no times of day. Settings › Writing History in the app turns it off
                or clears it.
              </li>
            </ul>
            <p>Some of this is handed to the system, on the same device, so that system features work:</p>
            <ul className={styles.list} role="list">
              <li>
                <strong>Spotlight.</strong> Each notebook&rsquo;s title, cover and the words in it, so it can be found
                from the Home Screen. Settings › Search in the app turns this off and removes what was indexed. Locked
                notebooks are left out.
              </li>
              <li>
                <strong>Widgets.</strong> The title, page number and cover of the notebook you last opened, and how
                many pages you wrote on recent days. When it writes this, the app does not name a locked notebook or
                show its cover; the page counts do include pages written in locked notebooks. A notebook made from a PDF
                or a scan has its first page as its cover.
              </li>
              <li>
                <strong>Siri and Shortcuts.</strong> The names and page counts of your notebooks, so you can ask for
                one by name. Locked notebooks are not offered; a shortcut you made before locking a notebook keeps its
                name and still opens it, once you unlock it. When you ask Siri for a notebook aloud,{' '}
                <Out href={apple.features}>Apple handles that request</Out>, the name included, as it does any Siri
                request, which may not stay on your device.
              </li>
            </ul>
            <p>
              When something goes wrong, such as a file that cannot be read or a sync that fails, the app writes a line
              to the device&rsquo;s own system log. Those lines hold no note content and no notebook titles, and the app
              does not send them anywhere.
            </p>
            <p>
              The app adds no encryption of its own. Your files are protected the way iPadOS and iOS protect every
              app&rsquo;s files, which depends on your passcode. If you back up your iPad or iPhone to iCloud or to a
              computer, the backup may include the app&rsquo;s files, as it does for any app.
            </p>
          </Part>

          <Part id="icloud">
            <p>
              iCloud sync is the one way OwlLuna itself copies your notebooks off your device without you sending them
              somewhere yourself.
            </p>
            <Stamp title="It asks first" className={styles.note}>
              <p>
                On a device that has never synced, OwlLuna copies nothing until you say yes. If the device is signed in
                to iCloud with iCloud Drive on, it asks once when it opens. Settings › iCloud in the app has the switch,
                and you can set it at any time, also before you sign in to iCloud. A device that was already syncing
                with an earlier version of OwlLuna carries on without being asked.
              </p>
            </Stamp>
            <h3 className={`display ${styles.sub}`}>What is copied</h3>
            <ul className={styles.list} role="list">
              <li>
                Every notebook, whole: everything listed under &ldquo;Your notebooks&rdquo; above, the words read from
                its pages, and its flashcards. Locked notebooks are copied like any other.
              </li>
              <li>Your folders and smart shelves, the pens in your tray, and the stickers you made.</li>
              <li>
                A small file holding a random ID that names this copy of your library. It lets a device tell when the
                copy was erased, or is another account&rsquo;s.
              </li>
            </ul>
            <p>Your writing history, your other settings and the search index are not copied.</p>
            <p>
              To tell what has changed since last time, each device also keeps a small record of what it last synced:
              the random IDs of its notebooks, with when each was last written in and last moved into or out of
              Recently Deleted, the IDs of its folders and smart shelves, the file names of its stickers, the ID of the iCloud copy, and
              the account marker described under <a href="#collected">What I collect</a>. That record stays on the
              device.
            </p>
            <h3 className={`display ${styles.sub}`}>Where it goes</h3>
            <p>
              Into the app&rsquo;s private container in your own iCloud storage, under your Apple Account. It is
              Apple&rsquo;s service: Apple moves the files between your devices, and I have no access to them. OwlLuna
              does not encrypt the copy itself; it is protected as the rest of your iCloud Drive is. Apple&rsquo;s
              handling of it is covered by <Out href={apple.privacy}>Apple&rsquo;s Privacy Policy</Out> and described in
              its <Out href={apple.icloud}>iCloud data security overview</Out>.
            </p>
            <p>
              Sync runs only while OwlLuna is running. It works the same way on an iPad, an iPhone and a Mac signed in
              to the same Apple Account.
            </p>
            <p>
              OwlLuna syncs with the Apple Account the device is signed in to. If a different account signs in while
              sync is on, sync stops and asks before it copies your notebooks to that account&rsquo;s iCloud storage or
              brings anything in from it. A sync already under way at that moment stops after the notebook it is
              copying. If you say yes, the notebooks on the device are copied there and the notebooks that account
              holds are added; nothing is deleted. If you say no, sync is turned off on that device and stays off until
              you turn it on again in Settings › iCloud in the app, which asks again. Before you pass an iPad or iPhone
              on to someone else, delete the app.
            </p>
            <h3 className={`display ${styles.sub}`}>Turning it off, and removing the copy</h3>
            <p>
              Settings › iCloud in the app has the switch, and each device has its own. Turning it off stops that
              device syncing. It does not remove what is already in iCloud.
            </p>
            <p>
              To remove the iCloud copy, first turn sync off on every device, because a device that still has it on will
              put the notebooks back. Then delete OwlLuna&rsquo;s data from your iCloud storage: in iPadOS and iOS,
              Settings › your name › iCloud lists the apps that keep data there (Apple renames those screens from time
              to time). If you turn sync on again afterwards, the device sees that the copy is gone and uploads its
              notebooks, folders and stickers again. Nothing is removed from the device.
            </p>
            <h3 className={`display ${styles.sub}`}>When you delete a notebook</h3>
            <p>
              A notebook you delete for good is removed from iCloud the next time that device syncs, and from your other
              devices after that. A delete only applies to the version of the notebook that device had. If another
              device has written in the notebook since, or has taken it back out of Recently Deleted, the notebook is
              kept and comes back to the device that deleted it. That holds whether or not the other device&rsquo;s
              change had reached the deleting device: a device that finds it holds a newer version than the one that
              was deleted keeps it and sends it to iCloud again. The same check is made for Recently Deleted: a
              notebook put there on one device and written in on another that had not heard of it comes back out. For a
              notebook that is removed, a small marker named with its random ID stays in the container so the other
              devices know which version was deleted. It holds two dates and nothing else: when that notebook was last
              written in, and when it was last moved into or out of Recently Deleted.
            </p>
          </Part>

          <Part id="permissions">
            <p>
              The system asks before the app may use any of these. Each is asked for only when you use the feature that
              needs it.
            </p>
            <Ledger className={styles.table}>
              <LedgerRow label="Camera">
                Only when you choose Scan Documents. Apple&rsquo;s scanner takes the pictures; the app receives the pages
                you keep and saves them in the notebook.
              </LedgerRow>
              <LedgerRow label="Microphone">
                Only while you are recording: from when you start a recording until you stop it or close the notebook.
                A recording carries on when you switch to another app or lock your iPad or iPhone, and the system shows
                its own recording indicator meanwhile. In a notebook with a lock it stops, and is saved, when the notebook
                locks. The recording is saved in the notebook it was made in.
              </LedgerRow>
              <LedgerRow label="Photos">
                You choose pictures in Apple&rsquo;s photo picker, and the app receives only those. It never looks
                through your library. A picture is saved as a new image, without the original file&rsquo;s details,
                such as where it was taken. If you save an exported picture or video to Photos from the share sheet,
                the system may ask to let the app add it.
              </LedgerRow>
              <LedgerRow label="Speech Recognition">
                Only when you ask for a transcript of a recording. It is done on your device: the app requires
                on-device recognition, and if the device cannot do that for the language, nothing is transcribed.
              </LedgerRow>
              <LedgerRow label="Calendar">
                Only if you add Today&rsquo;s Events to a page, or turn on Print Today&rsquo;s Events, which is off
                until you do. The app reads the titles and times of that day&rsquo;s events and prints them on the page.
                From then on they are part of the notebook, like anything else written in it, and are synced and backed
                up with it.
              </LedgerRow>
              <LedgerRow label="Face ID, Touch ID or passcode">
                To open notebooks you have locked, to lock or unlock one, and before a backup when any notebook is
                locked. The system does the checking and tells the app only yes or no.
              </LedgerRow>
            </Ledger>
            <p>
              You can withdraw them in Settings on your iPad or iPhone, on OwlLuna&rsquo;s own page under Apps or under
              Privacy &amp; Security (Face ID is under Face ID &amp; Passcode). The rest of the app keeps working, and recording,
              transcripts and Today&rsquo;s Events tell you when their permission is off.
            </p>
          </Part>

          <Part id="on-device">
            <p>
              Reading your notes is done by frameworks that are part of the operating system. The app passes them the
              text or the picture and makes no network request of its own.
            </p>
            <ul className={styles.list} role="list">
              <li>
                <strong>Search, handwriting to text and stickers.</strong> Handwriting, scans and photo pages are read,
                and the subject of a photo is cut out for a sticker, by Apple&rsquo;s Vision framework on your device.
              </li>
              <li>
                <strong>Transcripts.</strong> Apple&rsquo;s speech recogniser, on your device only, as described under
                Permissions.
              </li>
              <li>
                <strong>Translation.</strong> Only when you choose Translate for handwriting you have turned into text.
                The app hands those lines to the translator built into the operating system. Apple describes it as
                working on the device, once the system has downloaded the language from Apple.
              </li>
              <li>
                <strong>Study guides.</strong> Only when you open Study Guide. The words already read from your pages,
                or a recording&rsquo;s transcript, are given to Apple&rsquo;s on-device language model, the one behind
                Apple Intelligence, through Apple&rsquo;s framework. OwlLuna has no other model and no server of its own,
                so on a device without Apple Intelligence there is no study guide.
              </li>
              <li>
                <strong>Typing.</strong> Typed text goes through the system&rsquo;s ordinary keyboard and text tools,
                such as dictation, autocorrection, or another keyboard you have installed. Those belong to the system or
                to the keyboard&rsquo;s maker and work as they do in any app.
              </li>
            </ul>
            <p>
              How Apple&rsquo;s features treat what they are given is described on{' '}
              <Out href={apple.features}>Apple&rsquo;s privacy pages</Out>.
            </p>
          </Part>

          <Part id="sending">
            <p>
              Apart from <a href="#icloud">iCloud sync</a>, nothing leaves the app unless you do one of these:
            </p>
            <ul className={styles.list} role="list">
              <li>
                <strong>Export or print.</strong> A notebook as a PDF, pages as images, or a page as a time-lapse video
                is handed to the system&rsquo;s share sheet or print panel. The file is named after the notebook, and a PDF
                carries its title, bookmarks and links. Covering something with ink or study tape does not take it out
                of an exported PDF: what lies underneath is still in the file.
              </li>
              <li>
                <strong>Back up.</strong> Settings › Backup makes one file of your whole library and hands it to the
                share sheet. The file is not encrypted, and it contains every notebook, including locked ones and any
                still in Recently Deleted, along with your writing history. If any notebook is locked, making a backup,
                or sharing the last one again, asks for Face ID, Touch ID or the passcode first. Keep the file somewhere
                you trust.
              </li>
              <li>
                <strong>Copy or drag.</strong> Text you copy goes to the system clipboard, and a picture you drop on a
                page comes in from another app.
              </li>
              <li>
                <strong>Present.</strong> While you present, the page is shown on the second screen you connected.
              </li>
              <li>
                <strong>Open a link.</strong> A web link you placed on a page opens in your browser, and Settings ›
                About links to this website and to GitHub. What a visit here records is under{' '}
                <a href="#website">This website</a>; other sites have privacy policies of their own.
              </li>
            </ul>
            <p>Where a file goes after the share sheet is up to the app or service you chose there.</p>
          </Part>

          <Part id="locks">
            <p>
              A lock keeps a notebook closed in the app. It asks for Face ID, Touch ID or the passcode each time the
              notebook is opened, blurs its cover, and leaves what is written in it out of search, Spotlight, the widgets
              and On This Day.
            </p>
            <p>
              It is not encryption. A locked notebook&rsquo;s files are stored like any other notebook&rsquo;s, and its
              iCloud copy and any backup file hold it in full. Its title is still shown in the library. It is not
              offered to Siri and Shortcuts, and making a backup asks you to unlock first.
            </p>
            <p>
              With iCloud sync on, a lock reaches each of your other devices the next time that device syncs, whether
              or not the notebook has been written in since, and it is then taken out of that device&rsquo;s Spotlight
              and widgets. Until a device has synced, it still opens the notebook without asking. Newer pages arriving
              from a device that had not yet received the lock do not remove it, and if a notebook changed on two
              devices is kept as a conflicted copy, the copy is locked as well.
            </p>
          </Part>

          <Part id="deleting">
            <p>
              Your data stays until you remove it. Outside the <a href="#testflight">TestFlight beta</a>, there is no
              copy with me to keep, and none for me to delete.
            </p>
            <Ledger className={styles.table}>
              <LedgerRow label="A notebook">
                Deleting it moves it to Recently Deleted. It is removed for good after 30 days, the next time the app
                opens, or sooner if you delete it from there yourself. With iCloud sync on, the app syncs first when it
                can, so a notebook you restored on another device is not removed. If that restore has not reached this
                device by then, the notebook is removed here, stays on the device that restored it, and comes back here
                at a later sync.
              </LedgerRow>
              <LedgerRow label="A recording or a transcript">Each can be removed on its own from Recordings.</LedgerRow>
              <LedgerRow label="A page of an imported PDF">
                An imported PDF is kept whole inside its notebook, so a page you remove from the notebook stays in that
                file until the notebook itself is deleted.
              </LedgerRow>
              <LedgerRow label="Writing history">Settings › Writing History › Clear Writing History.</LedgerRow>
              <LedgerRow label="What Spotlight holds">
                Settings › Search › Find Notebooks in Spotlight, switched off, removes it.
              </LedgerRow>
              <LedgerRow label="Everything on an iPad or iPhone">
                Delete the app. That removes its notebooks, settings, history and widget data from the device.
              </LedgerRow>
              <LedgerRow label="The iCloud copy">
                Deleting the app does not remove it. See <a href="#icloud">iCloud sync</a> above for how to.
              </LedgerRow>
              <LedgerRow label="Exports and backup files">
                Wherever you saved or sent them, they are yours to delete. A finished export or backup also stays in the
                app&rsquo;s temporary storage until the system clears it or the app is deleted.
              </LedgerRow>
            </Ledger>
          </Part>

          <Part id="children">
            <p>
              OwlLuna has no accounts, no ads, nothing to buy and no data collection, for children or for anyone else. I
              do not knowingly collect personal information from children, because I do not collect it from anybody.
            </p>
          </Part>

          <Part id="apple-reports">
            <p>
              If you have agreed to share analytics with app developers (in iPadOS and iOS, Settings › Privacy &amp;
              Security › Analytics &amp; Improvements), Apple may send me crash reports and usage figures for the app,
              and the App Store shows me totals such as how many times it was downloaded. Apple says these do not
              identify you. They come from the operating system and the App Store, not from any code in OwlLuna, and
              you can switch the sharing off in the same place.
            </p>
          </Part>

          <Part id="testflight">
            <p>
              The beta comes through TestFlight, which is Apple&rsquo;s service, not code in OwlLuna. While you test,
              Apple collects the following and passes it to me. You cannot opt out of it.
            </p>
            <ul className={styles.list} role="list">
              <li>
                <strong>Crash reports.</strong> When the app crashes, the crash log, which shows where in OwlLuna&rsquo;s
                code it happened and how long the app had been running.
              </li>
              <li>
                <strong>Usage and your device.</strong> How many times you installed and used each build, how many
                times it crashed, which version you have, your device&rsquo;s model and an identifier for it, and its
                system version and language.
              </li>
            </ul>
            <p>
              Feedback is up to you. If you send it from the TestFlight app, by taking a screenshot in OwlLuna, or when
              TestFlight asks after a crash, I also get your comments and any screenshot. With them come the
              device&rsquo;s battery level, free storage, screen resolution, time zone, processor type, connection type
              and mobile carrier, and how long the app had been open. A screenshot shows whatever is on the screen, your
              notes included, and you can send feedback without one.
            </p>
            <p>
              If you joined through the public link on this site, Apple does not show me your name or email address,
              and you appear to me as Anonymous. I see your email address only if you add it to a piece of feedback, or
              send feedback by email.
            </p>
            <p>
              Apple lets me use all of this only to improve the app, and not share it with anyone else. Apple keeps
              feedback for a year, and may keep crash logs and usage until the bugs are fixed, as its{' '}
              <Out href={apple.testflight}>TestFlight &amp; Privacy notice</Out> describes. To leave the beta, open
              OwlLuna in the TestFlight app and tap Stop Testing. Apple asks you to bring requests to see or delete your
              TestFlight data to the developer, so ask me as under <a href="#contact">Questions and requests</a>. To see
              what Apple itself holds, go to <Out href={apple.data}>privacy.apple.com</Out>.
            </p>
          </Part>

          <Part id="website">
            <p>
              This site is a set of static pages hosted on GitHub Pages. It sets no cookies, runs no analytics and loads
              no trackers, and its fonts are served from the site itself. GitHub, as the host, logs technical details
              of visits such as IP addresses, as its <Out href={github}>Privacy Statement</Out> describes. The links to
              the source code and to the issue tracker go to GitHub.
            </p>
          </Part>

          <Part id="contact">
            <p>
              Outside the <a href="#testflight">TestFlight beta</a>, I hold no data about you, so there is nothing I can
              look up, correct, export or delete on your behalf. Your data is on your own devices and in your own
              iCloud, where the steps above remove it.
            </p>
            <p>
              For any question about this policy
              {site.contactEmail ? (
                <>
                  , write to <a href={`mailto:${site.contactEmail}`}>{site.contactEmail}</a> or open an issue on GitHub.
                </>
              ) : (
                <>, open an issue on GitHub.</>
              )}{' '}
              Issues are public, so please leave anything private out of them. Posting needs a free GitHub account, and
              GitHub handles what you post under its own <Out href={github}>Privacy Statement</Out>.
            </p>
            <div className={styles.actions}>
              <Button href={site.newIssue} variant="cloth">
                Ask a question on GitHub
                <Away />
              </Button>
              <Button href="/support/">Support</Button>
            </div>
          </Part>

          <Part id="changes">
            <p>
              If the app changes in a way that affects anything here, I will update this page and the date at its top.
              Earlier versions are in <Out href={history}>the project&rsquo;s public history</Out>.
            </p>
          </Part>
        </article>
      </div>
    </div>
  )
}
