import { Button } from '../ui/Button'
import { Ledger, LedgerRow } from '../ui/Ledger'
import { Reveal } from '../ui/Reveal'
import { SectionHeading } from '../ui/SectionHeading'
import styles from './PrivacySummary.module.css'

/** What the app collects (nothing) and where the reading happens, with the way to the full policy. */
export function PrivacySummary() {
  return (
    <section id="privacy" className="section" aria-labelledby="privacy-summary-title">
      <div className={`wrap ${styles.grid}`}>
        <div className={styles.words}>
          <SectionHeading eyebrow="Privacy" title="What OwlLuna knows about you: nothing." id="privacy-summary-title">
            <p>
              There is no account to make and no server of mine behind the app. Your notebooks are files on your device,
              and iCloud sync, which asks before it starts, keeps a copy in your own iCloud.
            </p>
          </SectionHeading>
          <Button href="/privacy/" variant="cloth">
            Read the Privacy Policy
          </Button>
        </div>

        <div className={styles.ledgers}>
          <Reveal>
            <Ledger title="What is collected">
              <LedgerRow label="Accounts" mark="cross">None. There is nothing to sign in to.</LedgerRow>
              <LedgerRow label="Analytics" mark="cross">None, and no crash reporter either.</LedgerRow>
              <LedgerRow label="Ads and trackers" mark="cross">None.</LedgerRow>
              <LedgerRow label="Third-party code" mark="cross">None. Apple&rsquo;s frameworks only.</LedgerRow>
            </Ledger>
          </Reveal>
          <Reveal delay={0.08}>
            <Ledger title="Where the reading happens">
              <LedgerRow label="Handwriting and scans" mark="check">Read on your device.</LedgerRow>
              <LedgerRow label="Recordings" mark="check">Transcribed on your device, or not at all.</LedgerRow>
              <LedgerRow label="Study guides" mark="check">Written by Apple Intelligence on your device.</LedgerRow>
              <LedgerRow label="Your notebooks" mark="check">On your device, and in your own iCloud if sync is on.</LedgerRow>
            </Ledger>
          </Reveal>
        </div>
      </div>
    </section>
  )
}
