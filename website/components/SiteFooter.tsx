import Link from 'next/link'
import { asset, iconSet, site } from '@/lib/site'
import styles from './SiteFooter.module.css'

export function SiteFooter() {
  return (
    <footer className={styles.footer}>
      <div className={`wrap ${styles.inner}`}>
        <div className={styles.colophon}>
          <div className={styles.brand}>
            <img
              src={asset('/owlluna-icon-64.webp')}
              srcSet={iconSet}
              sizes="44px"
              alt=""
              width={44}
              height={44}
              loading="lazy"
              className={styles.icon}
            />
            <span className={styles.name}>OwlLuna</span>
          </div>
          <p className={styles.line}>Free and open source. No ads, no subscriptions, no tracking.</p>
          <p className={styles.line}>
            Built by <a href={site.author.url}>{site.author.name}</a>.
          </p>
          <p className={styles.line}>
            Owl logo designed by <a href={site.logoDesigner.url}>{site.logoDesigner.name}</a>.
          </p>
        </div>

        <nav className={styles.column} aria-label="The site">
          <p className="meta">The site</p>
          <ul>
            <li><Link href="/#features">Features</Link></li>
            <li><Link href="/#story">A note from the developer</Link></li>
            <li><Link href="/prototypes/">Prototypes</Link></li>
            <li><Link href="/privacy/">Privacy Policy</Link></li>
            <li><Link href="/support/">Support</Link></li>
          </ul>
        </nav>

        <nav className={styles.column} aria-label="The project">
          <p className="meta">The project</p>
          <ul>
            <li><a href={site.repo}>Source code on GitHub</a></li>
            <li><a href={site.issues}>Report a problem</a></li>
            <li><a href={site.license}>MIT License</a></li>
          </ul>
        </nav>
      </div>

      <div className={`wrap ${styles.small}`}>
        <p>
          © {site.since} {site.author.name}. OwlLuna is released under the MIT License. Set in Libre
          Franklin, Fraunces, Archivo and Bricolage Grotesque, used under the <a href={site.fontLicenses}>SIL Open Font License</a>.
        </p>
        <p>
          Apple, iPad, iPadOS, Apple Pencil, Mac, iCloud, Face ID, Touch ID, Spotlight, Siri, SwiftUI, SwiftData,
          PencilKit and App Store are trademarks of Apple Inc., registered in the U.S. and other countries and regions.
          Apple Intelligence is a trademark of Apple Inc.
        </p>
      </div>
    </footer>
  )
}
