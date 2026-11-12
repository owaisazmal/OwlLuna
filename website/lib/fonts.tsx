'use client'

import archivo from '@fontsource-variable/archivo/files/archivo-latin-wdth-normal.woff2' with { turbopackModuleType: 'asset' }
import franklin from '@fontsource-variable/libre-franklin/files/libre-franklin-latin-wght-normal.woff2' with { turbopackModuleType: 'asset' }

const files = { franklin, archivo }

/** Fetches a file of `app/fonts.css` with the page. A client component, so prefetching a page does not fetch its fonts. */
export function FontPreload({ font }: { font: keyof typeof files }) {
  return <link rel="preload" href={files[font]} as="font" type="font/woff2" crossOrigin="anonymous" />
}
