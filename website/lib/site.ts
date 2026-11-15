import type { Metadata } from 'next'

const repo = 'https://github.com/owaisazmal/OwlLuna'

export const site = {
  name: 'OwlLuna',
  description:
    'A free, open-source alternative to Goodnotes and Notability for iPad. Handwritten notes with no subscriptions, no ads, no accounts and no tracking.',
  url: process.env.NEXT_PUBLIC_SITE_URL ?? 'https://owaisazmal.github.io/OwlLuna',
  repo,
  issues: `${repo}/issues`,
  newIssue: `${repo}/issues/new`,
  license: `${repo}/blob/main/LICENSE`,
  fontLicenses: `${repo}/tree/main/OwlLuna/Resources/Fonts`,
  contributing: `${repo}/blob/main/CONTRIBUTING.md`,
  security: `${repo}/blob/main/SECURITY.md`,
  author: { name: 'Owais Khan', url: 'https://github.com/owaisazmal' },
  /** Who designed the owl of the app's icon. */
  logoDesigner: { name: 'Safiya Sulaiman', url: 'https://www.linkedin.com/in/safiya-sulaiman-53920932a/' },
  /** The years in the footer's copyright line, as in LICENSE. */
  since: '2024–2026',
  /** The App Store page, once the app is published. Empty until then. */
  appStoreUrl: '',
  /** The public TestFlight beta, offered while `appStoreUrl` is empty. */
  testFlightUrl: 'https://testflight.apple.com/join/68jmH6R7',
  /** The code from Google Search Console's HTML-tag verification. Empty adds no tag. */
  googleSiteVerification: '',
  /** An address for privacy and support questions. Empty shows GitHub Issues alone. */
  contactEmail: '',
  /** The day the privacy policy last changed, as YYYY-MM-DD. */
  policyUpdated: '2026-11-15',
}

/** The share card every page carries, linked to the page it is on. */
export const openGraph = {
  type: 'website',
  siteName: site.name,
  url: './',
  images: [
    {
      url: '/opengraph-image.png',
      width: 1200,
      height: 630,
      type: 'image/png',
      alt: 'OwlLuna: an owl writing on a notepad beside the words Handwritten notes for iPad. Free, for good.',
    },
  ],
} satisfies Metadata['openGraph']

const basePath = process.env.NEXT_PUBLIC_BASE_PATH ?? ''

/** A file in `public/`, under the site's base path. */
export function asset(path: string): string {
  return `${basePath}${path.startsWith('/') ? path : `/${path}`}`
}

/** The owl icon in `public/`, sized for the nav's and footer's slots at up to 3×. */
export const iconSet = [32, 64, 96, 132].map((width) => `${asset(`/owlluna-icon-${width}.webp`)} ${width}w`).join(', ')

export function formatDate(iso: string): string {
  const [year, month, day] = iso.split('-').map(Number)
  return new Date(Date.UTC(year, month - 1, day)).toLocaleDateString('en-GB', {
    day: 'numeric',
    month: 'long',
    year: 'numeric',
    timeZone: 'UTC',
  })
}
