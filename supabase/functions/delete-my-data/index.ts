// delete-my-data: removes everything stored for the signed-in user — every
// row keyed to them (`delete_user_data`, migration 00057) and every storage
// object under their folder in each bucket, motion recordings included.
//
// POST (no body). 200 { objectsRemoved } on success; the rows go only after
// the objects are gone, so a failure leaves the account whole enough to retry.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0"

const admin = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "")
// Folders are named by user id, and exist in both upper and lower case; both
// belong to the user.
const BUCKETS = ["swing-motion", "playgroup-audio"]
const PAGE = 1000

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } })
}

async function listAll(bucket: string, folder: string): Promise<string[]> {
  const out: string[] = []
  for (let offset = 0; ; offset += PAGE) {
    const { data, error } = await admin.storage.from(bucket).list(folder, { limit: PAGE, offset })
    if (error) throw new Error(`list ${bucket}/${folder}: ${error.message}`)
    for (const item of data ?? []) {
      const path = `${folder}/${item.name}`
      // A folder comes back with no id.
      if (item.id) out.push(path)
      else out.push(...await listAll(bucket, path))
    }
    if (!data || data.length < PAGE) return out
  }
}

serve(async (req) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405)
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "")
  const { data: auth, error: authErr } = await admin.auth.getUser(token)
  const userId = auth?.user?.id
  if (authErr || !userId) return json({ error: "not signed in" }, 401)

  try {
    let removed = 0
    for (const bucket of BUCKETS) {
      for (const folder of new Set([userId.toLowerCase(), userId.toUpperCase()])) {
        const paths = await listAll(bucket, folder)
        for (let i = 0; i < paths.length; i += PAGE) {
          const { error } = await admin.storage.from(bucket).remove(paths.slice(i, i + PAGE))
          if (error) throw new Error(`remove ${bucket}: ${error.message}`)
        }
        removed += paths.length
      }
    }
    const { error } = await admin.rpc("delete_user_data", { p_user_id: userId })
    if (error) throw new Error(`delete_user_data: ${error.message}`)
    return json({ objectsRemoved: removed })
  } catch (e) {
    console.error("delete-my-data", e)
    return json({ error: String(e) }, 500)
  }
})
