import { site } from '@/lib/site'

export function AppStructuredData() {
  const downloadUrl = site.appStoreUrl.trim()
  const data = {
    '@context': 'https://schema.org',
    '@type': 'SoftwareApplication',
    name: site.name,
    applicationCategory: 'ProductivityApplication',
    operatingSystem: 'iPadOS 18 or later, iOS 18 or later, macOS 26 or later',
    description: site.description,
    url: `${site.url}/`,
    image: `${site.url}/owlluna-icon.png`,
    license: site.license,
    offers: { '@type': 'Offer', price: 0, priceCurrency: 'USD' },
    ...(downloadUrl ? { downloadUrl } : {}),
  }

  return (
    <script
      type="application/ld+json"
      dangerouslySetInnerHTML={{ __html: JSON.stringify(data).replace(/</g, '\\u003c') }}
    />
  )
}
