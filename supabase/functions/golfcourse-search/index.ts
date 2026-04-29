// golfcourse-search edge function
//
// Proxies GolfCourseAPI search/lookup requests so the API key never ships in
// the client app binary. Also caches every returned course's tee data into
// `course_tees` + `course_tee_holes` so subsequent rounds (any user, any
// device) get the data from our DB instead of hitting GolfCourseAPI again.
//
// Endpoints (all POST):
//   { query: "hyde park" }       → search by name; returns full course list
//   { courseId: 29970 }          → fetch single course by GolfCourseAPI id
//
// Always returns: { courses: [GolfCourseAPICourse, ...] }
//
// Cache write happens in the background — request returns as soon as we have
// the API response; cache writes don't block the user.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0"

const GOLF_COURSE_API_BASE = "https://api.golfcourseapi.com/v1"

// Pulled from Supabase function secrets (`supabase secrets set ...`).
const GOLF_COURSE_API_KEY = Deno.env.get("GOLF_COURSE_API_KEY") ?? ""
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? ""
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""

// Service-role client bypasses RLS for cache writes — the Edge Function is
// trusted to write course_tees / course_tee_holes since it controls what
// gets cached.
const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)

interface RequestBody {
  query?: string
  courseId?: number
}

interface APITeeBox {
  tee_name: string
  course_rating?: number
  slope_rating?: number
  bogey_rating?: number
  total_yards?: number
  total_meters?: number
  number_of_holes?: number
  par_total?: number
  front_course_rating?: number
  front_slope_rating?: number
  front_bogey_rating?: number
  back_course_rating?: number
  back_slope_rating?: number
  back_bogey_rating?: number
  holes?: Array<{ par?: number; yardage?: number; handicap?: number }>
}

interface APICourse {
  id: number
  club_name?: string
  course_name?: string
  location?: {
    address?: string
    city?: string
    state?: string
    country?: string
    latitude?: number
    longitude?: number
  }
  tees?: { female?: APITeeBox[]; male?: APITeeBox[] }
}

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
}

serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders })
  }

  let body: RequestBody
  try {
    body = await req.json()
  } catch {
    return jsonResponse({ error: "invalid JSON body" }, 400)
  }

  if (!GOLF_COURSE_API_KEY) {
    return jsonResponse({ error: "server not configured" }, 500)
  }

  try {
    let courses: APICourse[]
    if (body.courseId !== undefined) {
      const single = await fetchCourse(body.courseId)
      courses = single ? [single] : []
    } else if (body.query) {
      courses = await searchCourses(body.query)
    } else {
      return jsonResponse({ error: "must include `query` or `courseId`" }, 400)
    }

    // Cache writes must complete before the function returns — Deno serverless
    // terminates background promises when the response sends. Cost is ~50-100ms
    // for the upserts, acceptable for the cache hit benefit on subsequent calls.
    try {
      await cacheCourses(courses)
    } catch (err) {
      console.error("cache write failed:", err)
    }

    return jsonResponse({ courses })
  } catch (err) {
    return jsonResponse({ error: String(err) }, 502)
  }
})

async function searchCourses(query: string): Promise<APICourse[]> {
  const url = `${GOLF_COURSE_API_BASE}/search?search_query=${encodeURIComponent(query)}`
  const res = await fetch(url, {
    headers: { Authorization: `Key ${GOLF_COURSE_API_KEY}` },
  })
  if (!res.ok) {
    throw new Error(`GolfCourseAPI search ${res.status}: ${await res.text()}`)
  }
  const data = await res.json()
  return data.courses ?? []
}

async function fetchCourse(courseId: number): Promise<APICourse | null> {
  const url = `${GOLF_COURSE_API_BASE}/courses/${courseId}`
  const res = await fetch(url, {
    headers: { Authorization: `Key ${GOLF_COURSE_API_KEY}` },
  })
  if (res.status === 404) return null
  if (!res.ok) {
    throw new Error(`GolfCourseAPI lookup ${res.status}: ${await res.text()}`)
  }
  const data = await res.json()
  return data.course ?? null
}

async function cacheCourses(courses: APICourse[]): Promise<void> {
  for (const course of courses) {
    await cacheCourse(course)
  }
}

async function cacheCourse(course: APICourse): Promise<void> {
  const externalId = String(course.id)
  const allTees: Array<{ box: APITeeBox; gender: string }> = [
    ...(course.tees?.female ?? []).map((box) => ({ box, gender: "female" })),
    ...(course.tees?.male ?? []).map((box) => ({ box, gender: "male" })),
  ]
  for (const { box, gender } of allTees) {
    // Upsert the tee row; on conflict (external_course_id, tee_name, gender)
    // do nothing — cache rows are immutable per (course, tee, gender).
    const { data: existing, error: fetchErr } = await admin
      .from("course_tees")
      .select("id")
      .eq("external_course_id", externalId)
      .eq("tee_name", box.tee_name)
      .eq("gender", gender)
      .maybeSingle()
    if (fetchErr) {
      console.error("cache lookup failed:", fetchErr)
      continue
    }

    let teeId: string
    if (existing) {
      teeId = existing.id
    } else {
      const insertRow = {
        external_course_id: externalId,
        tee_name: box.tee_name,
        gender,
        course_rating: box.course_rating,
        slope_rating: box.slope_rating,
        bogey_rating: box.bogey_rating,
        par_total: box.par_total,
        total_yards: box.total_yards,
        total_meters: box.total_meters,
        front_course_rating: box.front_course_rating,
        front_slope_rating: box.front_slope_rating,
        front_bogey_rating: box.front_bogey_rating,
        back_course_rating: box.back_course_rating,
        back_slope_rating: box.back_slope_rating,
        back_bogey_rating: box.back_bogey_rating,
      }
      const { data: inserted, error: insertErr } = await admin
        .from("course_tees")
        .insert(insertRow)
        .select("id")
        .single()
      if (insertErr || !inserted) {
        console.error("cache insert failed:", insertErr)
        continue
      }
      teeId = inserted.id
    }

    // Per-hole rows. Do a clean replace: delete existing for this tee, insert
    // fresh. Cheap (max 18 rows) and avoids partial-update edge cases.
    if (box.holes && box.holes.length > 0) {
      await admin.from("course_tee_holes").delete().eq("tee_id", teeId)
      const holeRows = box.holes.map((h, idx) => ({
        tee_id: teeId,
        hole_number: idx + 1,
        par: h.par,
        yardage: h.yardage,
        handicap: h.handicap,
      }))
      const { error: holeErr } = await admin.from("course_tee_holes").insert(holeRows)
      if (holeErr) {
        console.error("cache holes insert failed:", holeErr)
      }
    }
  }
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  })
}
