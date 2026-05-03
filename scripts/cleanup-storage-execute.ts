import { createClient } from '@supabase/supabase-js'

const url = process.env.SUPABASE_URL!
const serviceRole = process.env.SUPABASE_SERVICE_ROLE_KEY!
const confirm = process.env.CONFIRM_STORAGE_DELETE === 'YES'

if (!url || !serviceRole) throw new Error('Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY')
if (!confirm) throw new Error('Set CONFIRM_STORAGE_DELETE=YES to execute deletions')

const supabase = createClient(url, serviceRole)

async function main() {
  const planRaw = process.env.STORAGE_DELETE_PLAN_JSON
  if (!planRaw) throw new Error('Missing STORAGE_DELETE_PLAN_JSON (output from dry-run, filtered manually)')

  const plan: Array<{ bucket: string; name: string }> = JSON.parse(planRaw)

  const grouped = new Map<string, string[]>()
  for (const item of plan) {
    if (!grouped.has(item.bucket)) grouped.set(item.bucket, [])
    grouped.get(item.bucket)!.push(item.name)
  }

  const logs: any[] = []
  for (const [bucket, paths] of grouped.entries()) {
    for (let i = 0; i < paths.length; i += 100) {
      const batch = paths.slice(i, i + 100)
      const { data, error } = await supabase.storage.from(bucket).remove(batch)
      logs.push({ bucket, batchSize: batch.length, deleted: data, error: error?.message ?? null })
    }
  }

  console.log(JSON.stringify({ executed: true, totalCandidates: plan.length, logs }, null, 2))
}

main().catch(err => {
  console.error(err)
  process.exit(1)
})
