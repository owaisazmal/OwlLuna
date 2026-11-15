import type { Metadata } from 'next'
import Link from 'next/link'
import { OpenFromLink } from '@/components/support/OpenFromLink'
import { QuestionGroup } from '@/components/support/QuestionGroup'
import { ReportSlip } from '@/components/support/ReportSlip'
import { groups } from '@/components/support/questions'
import { Away, Button } from '@/components/ui/Button'
import { Reveal } from '@/components/ui/Reveal'
import { SectionHeading } from '@/components/ui/SectionHeading'
import { Stamp } from '@/components/ui/Stamp'
import { site } from '@/lib/site'
import styles from './support.module.css'

export const metadata: Metadata = {
  title: 'Support',
  description:
    'How to get help with OwlLuna: where to reach the developer, what to put in a report, and answers about getting started, your notes and iCloud, privacy and troubleshooting.',
}

export default function Support() {
  const email = site.contactEmail.trim()

  return (
    <>
      <section className="section-tight">
        <div className={`wrap ${styles.intro}`}>
          <div className={styles.lead}>
            <SectionHeading as="h1" eyebrow="Support" title="Help with OwlLuna">
              <p>How to reach the developer, and short answers for when something is unclear or goes wrong.</p>
            </SectionHeading>
            <Stamp
              title="How to get help"
              tone="mustard"
              actions={
                <>
                  <Button href={site.issues} className={styles.action}>
                    Read existing issues
                    <Away />
                  </Button>
                  <Button href={site.newIssue} variant="cloth" className={styles.action}>
                    Report a problem
                    <Away />
                  </Button>
                </>
              }
            >
              <div className={styles.help}>
                <p>
                  The way to reach the developer is GitHub Issues
                  {email ? (
                    <>
                      , or by email at <a href={`mailto:${email}`}>{email}</a>
                    </>
                  ) : null}
                  . Look through the existing issues first, in case yours is already known, then report a new one.
                  Posting needs a free GitHub account; reading does not.
                </p>
                <p>
                  <strong>Issues are public.</strong> Anyone can read what you post there, so leave out anything
                  private, such as a page from your notebook.
                  {email ? ' If a report needs something private, send it by email.' : null}
                </p>
                <p>
                  A security problem, or a privacy question about your own notes, goes in a private report on GitHub
                  instead, which only the developer can read. <a href={site.security}>SECURITY.md</a> says how to send
                  one.
                </p>
              </div>
            </Stamp>
          </div>
          <div className={styles.slip}>
            <ReportSlip />
          </div>
        </div>
      </section>

      <section className={`section-tight ${styles.answers}`} aria-label="Questions and answers">
        <OpenFromLink />
        <div className={`wrap ${styles.groups}`}>
          {groups.map((group, index) => (
            <Reveal key={group.id}>
              <QuestionGroup group={group} number={index + 1} open={index === 0 ? group.questions[0].id : undefined} />
            </Reveal>
          ))}
          <div className={styles.closing}>
            <p>
              For what OwlLuna keeps on your device and what it copies to your own iCloud, read the{' '}
              <Link href="/privacy/">Privacy Policy</Link>.
            </p>
          </div>
        </div>
      </section>
    </>
  )
}
