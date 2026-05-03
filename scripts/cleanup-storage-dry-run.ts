import { createClient } from '@supabase/supabase-js'

const url = process.env.SUPABASE_URL!
const serviceRole = process.env.SUPABASE_SERVICE_ROLE_KEY!
const olderThanDays = Number(process.env.STORAGE_OLDER_THAN_DAYS ?? '180')
const minBytes = Number(process.env.STORAGE_MIN_BYTES ?? '10485760') // 10MB
const keepBuckets = (process.env.STORAGE_KEEP_BUCKETS ?? 'avatars,profiles,private-user-data')
  .split(',')
  .map(s => s.trim())
  .filter(Boolean)

if (!url || !serviceRole) throw new Error('Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY')
if (!Number.isFinite(olderThanDays) || olderThanDays < 0) {
  throw new Error('STORAGE_OLDER_THAN_DAYS must be a non-negative number')
}
if (!Number.isFinite(minBytes) || minBytes < 0) {
  throw new Error('STORAGE_MIN_BYTES must be a non-negative number')
}

const supabase = createClient(url, serviceRole)

async function main() {
  const { data: buckets, error: bErr } = await supabase.storage.listBuckets()
  if (bErr) throw bErr

  const cutoff = new Date(Date.now() - olderThanDays * 24 * 60 * 60 * 1000)
  const report: Array<{bucket: string; name: string; created_at?: string; size?: number}> = []

  for (const bucket of buckets ?? []) {
    if (keepBuckets.includes(bucket.name)) continue

    const prefixes = ['']
    while (prefixes.length > 0) {
      const prefix = prefixes.shift() ?? ''
      let offset = 0
      const limit = 100

      while (true) {
        const { data: files, error } = await supabase.storage.from(bucket.name).list(prefix, {
          limit,
          offset,
          sortBy: { column: 'created_at', order: 'asc' },
        })
        if (error) throw error
        if (!files || files.length === 0) break

        for (const f of files) {
          const entryPath = prefix ? `${prefix}/${f.name}` : f.name

          // Supabase list() returns directories with null metadata.
          if (!f.metadata) {
            prefixes.push(entryPath)
            continue
          }

          const createdAt = f.created_at ? new Date(f.created_at) : undefined
          const size = Number((f.metadata as any).size ?? 0)
          if (createdAt && createdAt < cutoff && size >= minBytes) {
            report.push({ bucket: bucket.name, name: entryPath, created_at: f.created_at, size })
          }
        }

        if (files.length < limit) break
        offset += limit
      }
    }
  }

  console.log(JSON.stringify({ dryRun: true, olderThanDays, minBytes, keepBuckets, count: report.length, files: report }, null, 2))
}

main().catch(err => {
  console.error(err)
  process.exit(1)
})
