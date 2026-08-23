// course-height-field edge function
//
// Serves one course's solved height map to the app as a single bounded,
// compact payload.
//
// WHY THIS EXISTS
//
// The client used to read `hole_height_cells` directly:
//
//     .from("hole_height_cells").select(...).eq("course_id", id).execute()
//
// with no range. PostgREST caps an unbounded select at 1000 rows, so once a
// course's map passed 1000 cells the watch silently received a fifth of it and
// treated every unreturned cell as ground nobody had ever walked. On 2026-08-19
// the field solver rewrote Hyde Park as 5107 cells in one shot; the next round
// played there had NO elevation readout on any hole, because both the user
// lookup and the green lookup fell outside the truncated slice. The failure is
// silent by construction — a short read looks exactly like a sparse map.
//
// Paging the client query would fix the truncation and leave the real problem:
// the map is not a thing a watch should be reassembling out of raw rows. 5816
// rows is 483 KB of JSON to convey what is a fixed-grid field of altitudes.
//
// So the client asks for the FIELD, once, and gets it in one response:
//
//   * Complete by construction. Paged server-side (see READ_PAGE), so there is
//     no row cap for the caller to know about or forget.
//   * ~10 bytes per cell instead of ~85. Hyde Park: 483 KB -> 57 KB raw,
//     76 KB base64, before transport gzip.
//   * Revalidatable. The map only changes when a round folds in, which stamps
//     `hole_height_solves`. A client that passes its cached `haveSolvedAt` gets
//     `{unchanged:true}` and reuses what it already has, so the common case is
//     a few hundred bytes.
//
// The lookup itself stays on the device. The readout recomputes on every path
// sample — roughly every 5 s for the length of a round, ~1400 times — and a
// golf course is exactly where the watch has no signal. A per-tick round trip
// would be slower, drain the battery, and go blank whenever coverage does.
// Fetch once, evaluate locally.
//
// REQUEST (POST)
//   { courseId: uuid,
//     haveSolvedAt?: string }  // client's cached solve stamp; echo back
//                              // {unchanged:true} when it is still current
//
// RESPONSE
//   { courseId, solvedAt, unchanged: true }
// or
//   { courseId, solvedAt, encoding: "sparse-v1", step, originI, originJ,
//     cellCount, cellsSkipped, cells: base64 }
//
// ENCODING "sparse-v1" — little-endian, 10 bytes per cell, no padding:
//   off 0  int16    di      cell i index minus originI
//   off 2  int16    dj      cell j index minus originJ
//   off 4  float32  altM    mean_alt_m
//   off 8  uint16   n       n_samples, saturating at 65535
//
// Sparse rather than a dense raster on purpose: Hyde Park's cells occupy 5816
// of the 302x360 grid's ~109k slots (5.3%). Densifying would inflate the
// payload roughly sevenfold to carry mostly holes.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0"

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? ""
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""

// Service role: the height map is shared course data assembled from every
// user's rounds, and it is read-only here.
const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)

const READ_PAGE = 1000

// Must match `ElevationFoldIn.cellStepDeg` on the client. Sent in the response
// so a client can refuse a payload it would quantize differently rather than
// silently place every cell in the wrong bucket.
const CELL_STEP_DEG = 3e-5

const BYTES_PER_CELL = 10
const I16_MIN = -32768
const I16_MAX = 32767

interface CellRow {
  cell_lat: number
  cell_lon: number
  mean_alt_m: number
  n_samples: number
}

serve(async (req) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405)

  let body: { courseId?: string; haveSolvedAt?: string }
  try {
    body = await req.json()
  } catch {
    return json({ error: "invalid JSON body" }, 400)
  }

  const courseId = body.courseId?.toLowerCase()
  if (!courseId) return json({ error: "courseId required" }, 400)

  // The stamp of the most recent rebuild. Doubles as the cache validator and
  // as the version the client stores alongside the decoded field.
  const { data: solveRows, error: solveErr } = await admin
    .from("hole_height_solves")
    .select("solved_at")
    .eq("course_id", courseId)
    .order("solved_at", { ascending: false })
    .limit(1)
  if (solveErr) return json({ error: `solves: ${solveErr.message}` }, 500)
  const solvedAt: string | null = solveRows?.[0]?.solved_at ?? null

  // Revalidation. A course with no solve row yet has no stamp to compare, so
  // it always falls through to a full read.
  if (solvedAt && body.haveSolvedAt && body.haveSolvedAt === solvedAt) {
    return json({ courseId, solvedAt, unchanged: true })
  }

  // Paged, for the reason this function exists. `cell_lat` is not unique, so
  // order on the full key or a page boundary can drop and repeat rows.
  const cells: CellRow[] = []
  for (let from = 0; ; from += READ_PAGE) {
    const { data, error } = await admin
      .from("hole_height_cells")
      .select("cell_lat,cell_lon,mean_alt_m,n_samples")
      .eq("course_id", courseId)
      .order("cell_lat", { ascending: true })
      .order("cell_lon", { ascending: true })
      .range(from, from + READ_PAGE - 1)
    if (error) return json({ error: `cells: ${error.message}` }, 500)
    if (!data?.length) break
    cells.push(...(data as CellRow[]))
    if (data.length < READ_PAGE) break
  }

  if (!cells.length) {
    // Distinct from a truncated read: this course genuinely has no map. The
    // client renders no elevation, which is correct and not a failure.
    return json({
      courseId,
      solvedAt,
      encoding: "sparse-v1",
      step: CELL_STEP_DEG,
      originI: 0,
      originJ: 0,
      cellCount: 0,
      cellsSkipped: 0,
      cells: "",
    })
  }

  const idx = (v: number) => Math.round(v / CELL_STEP_DEG)

  // Origin at the minimum corner so every offset is non-negative and the int16
  // budget covers a span of 32767 cells (~109 km) rather than half that.
  let originI = Infinity
  let originJ = Infinity
  for (const c of cells) {
    const i = idx(c.cell_lat)
    const j = idx(c.cell_lon)
    if (i < originI) originI = i
    if (j < originJ) originJ = j
  }

  const buf = new Uint8Array(cells.length * BYTES_PER_CELL)
  const view = new DataView(buf.buffer)
  let count = 0
  let skipped = 0

  for (const c of cells) {
    const di = idx(c.cell_lat) - originI
    const dj = idx(c.cell_lon) - originJ
    // A cell whose offset will not fit is one corrupt coordinate, not a reason
    // to fail the whole course. Drop it and report the count, so it shows up as
    // a number rather than as terrain that quietly went missing.
    if (di < I16_MIN || di > I16_MAX || dj < I16_MIN || dj > I16_MAX ||
        !Number.isFinite(c.mean_alt_m)) {
      skipped++
      continue
    }
    const off = count * BYTES_PER_CELL
    view.setInt16(off, di, true)
    view.setInt16(off + 2, dj, true)
    view.setFloat32(off + 4, c.mean_alt_m, true)
    view.setUint16(off + 8, Math.min(65535, Math.max(0, c.n_samples | 0)), true)
    count++
  }

  return json({
    courseId,
    solvedAt,
    encoding: "sparse-v1",
    step: CELL_STEP_DEG,
    originI,
    originJ,
    cellCount: count,
    cellsSkipped: skipped,
    cells: base64(buf.subarray(0, count * BYTES_PER_CELL)),
  })
})

// Chunked so a large map does not blow the argument limit on String.fromCharCode.
function base64(bytes: Uint8Array): string {
  const CHUNK = 0x8000
  let binary = ""
  for (let i = 0; i < bytes.length; i += CHUNK) {
    binary += String.fromCharCode(...bytes.subarray(i, i + CHUNK))
  }
  return btoa(binary)
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  })
}
