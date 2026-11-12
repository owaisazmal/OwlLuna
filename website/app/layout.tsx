import type { Metadata, Viewport } from 'next'
import type { ReactNode } from 'react'
import './fonts.css'
import './globals.css'
import { Providers } from '@/components/Providers'
import { SiteFooter } from '@/components/SiteFooter'
import { SiteNav } from '@/components/SiteNav'
import { FontPreload } from '@/lib/fonts'
import { openGraph, site } from '@/lib/site'

export const metadata: Metadata = {
  metadataBase: new URL(`${site.url}/`),
  title: { default: 'OwlLuna: handwritten notes for iPad, free and open source', template: '%s · OwlLuna' },
  description: site.description,
  applicationName: site.name,
  authors: [{ name: site.author.name, url: site.author.url }],
  alternates: { canonical: './' },
  verification: { google: site.googleSiteVerification.trim() || undefined },
  openGraph,
  twitter: { card: 'summary_large_image' },
}

export const viewport: Viewport = {
  themeColor: [
    { media: '(prefers-color-scheme: light)', color: '#f1ede4' },
    { media: '(prefers-color-scheme: dark)', color: '#181613' },
  ],
}

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en" data-scroll-behavior="smooth">
      <body>
        <FontPreload font="franklin" />
        <a href="#main" className="skip-link">
          Skip to content
        </a>
        <Providers>
          <SiteNav />
          <main id="main">{children}</main>
          <SiteFooter />
        </Providers>
      </body>
    </html>
  )
}
