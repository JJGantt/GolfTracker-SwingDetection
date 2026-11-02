// register-osm-course: the only way a shared (OSM) course row is created or
// filled in. The client names the OpenStreetMap element(s) it picked; this
// function fetches them from Overpass itself, refuses anything that is not a
// named golf course, builds the course's OSM data, and stores it through
// `register_osm_course` (service role only, migration 00056). Nothing about a
// shared course's name, outline, holes or greens comes from the client.
//
// POST { courseId, osm: {type, id}, siblings?: [{type, id}], externalCourseId? }
//   courseId          the id to give the course if it is new
//   osm               the picked element (way or relation); `type` may be left
//                     out for a course already registered with this osm_id
//   siblings          other elements the client grouped as the same course;
//                     kept only if each is itself a golf course within 500 m
//   externalCourseId  a GolfCourseAPI course id; kept only if the
//                     golfcourse-search function has cached it (course_tees)
//
// 200 { courseId, name, centerLat, centerLon, osmId, externalCourseId, osmData }
// The returned courseId is the course for that osm_id, which is not the
// requested one when it was already registered. A row that already has OSM
// data is returned without asking Overpass again.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0"
import {
  courseCenter,
  distanceMeters,
  elementsQuery,
  type ElementRef,
  geometryQuery,
  parseCourseGeometry,
  parseGolfCourses,
  SIBLING_MAX_METERS,
} from "./osm.ts"

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? ""
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
const OVERPASS = "https://overpass-api.de/api/interpreter"
const MAX_SIBLINGS = 8
const USER_AGENT = "StrokeSaver/1.0 (+https://jjgantt.github.io/golftracker-site)"
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/

const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } })
}

function asRef(v: unknown): ElementRef | null {
  // deno-lint-ignore no-explicit-any
  const r = v as any
  if (!r || (r.type !== "way" && r.type !== "relation")) return null
  if (!Number.isSafeInteger(r.id) || r.id <= 0) return null
  return { type: r.type, id: r.id }
}

async function overpass(query: string) {
  const res = await fetch(OVERPASS, {
    method: "POST",
    // Overpass refuses requests without an identifying User-Agent (406).
    headers: { "Content-Type": "application/x-www-form-urlencoded", "User-Agent": USER_AGENT },
    body: "data=" + encodeURIComponent(query),
  })
  if (!res.ok) throw new Error(`overpass ${res.status}`)
  return await res.json()
}

async function courseRow(osmId: number) {
  const { data, error } = await admin
    .from("courses")
    .select("id,name,center_lat,center_lon,osm_id,external_course_id,osm_polygons")
    .eq("osm_id", osmId)
    .limit(1)
  if (error) throw new Error(`courses: ${error.message}`)
  return data?.[0] ?? null
}

// deno-lint-ignore no-explicit-any
function reply(row: any): Response {
  return json({
    courseId: row.id,
    name: row.name,
    centerLat: row.center_lat,
    centerLon: row.center_lon,
    osmId: row.osm_id,
    externalCourseId: row.external_course_id,
    osmData: row.osm_polygons,
  })
}

serve(async (req) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405)

  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "")
  const { data: user, error: authErr } = await admin.auth.getUser(token)
  if (authErr || !user?.user) return json({ error: "not signed in" }, 401)

  // deno-lint-ignore no-explicit-any
  let body: any
  try {
    body = await req.json()
  } catch {
    return json({ error: "invalid JSON body" }, 400)
  }
  const courseId = typeof body?.courseId === "string" ? body.courseId.toLowerCase() : ""
  const pickedId = body?.osm?.id
  if (!UUID_RE.test(courseId) || !Number.isSafeInteger(pickedId) || pickedId <= 0) {
    return json({ error: "courseId and osm {type, id} required" }, 400)
  }
  const picked = asRef(body.osm)
  const siblings = (Array.isArray(body?.siblings) ? body.siblings : [])
    .map(asRef)
    .filter((r: ElementRef | null): r is ElementRef => r !== null)
    .slice(0, MAX_SIBLINGS)

  let externalCourseId: string | null = null
  if (typeof body?.externalCourseId === "string" && body.externalCourseId) {
    const { data } = await admin.from("course_tees").select("id")
      .eq("external_course_id", body.externalCourseId).limit(1)
    if (data?.length) externalCourseId = body.externalCourseId
  }

  try {
    const existing = await courseRow(pickedId)
    if (existing?.osm_polygons) {
      // Already built from OSM. Only a scorecard id it lacks can be added.
      if (externalCourseId && !existing.external_course_id) {
        const { error } = await admin.rpc("register_osm_course", {
          p_id: existing.id, p_name: existing.name,
          p_center_lat: existing.center_lat, p_center_lon: existing.center_lon,
          p_osm_id: pickedId, p_external_course_id: externalCourseId, p_osm_polygons: null,
        })
        if (error) return json({ error: `register: ${error.message}` }, 500)
        return reply(await courseRow(pickedId))
      }
      return reply(existing)
    }
    if (!picked) return json({ error: "osm.type required to register a new course" }, 400)

    const courses = parseGolfCourses(await overpass(elementsQuery([picked, ...siblings])))
    const course = courses.get(`${picked.type}/${picked.id}`)
    if (!course) return json({ error: "not a named golf course in OpenStreetMap" }, 422)
    const outlines = [course.polygon]
    for (const s of siblings) {
      const sib = courses.get(`${s.type}/${s.id}`)
      if (sib && distanceMeters(sib.centroid, course.centroid) <= SIBLING_MAX_METERS) outlines.push(sib.polygon)
    }

    const osmData = parseCourseGeometry(
      await overpass(geometryQuery(outlines)),
      course.centroid,
      outlines,
      new Date(),
      () => crypto.randomUUID().toUpperCase(),
    )
    const center = courseCenter(osmData, course.centroid)
    const { error } = await admin.rpc("register_osm_course", {
      p_id: courseId, p_name: course.name,
      p_center_lat: center.latitude, p_center_lon: center.longitude,
      p_osm_id: picked.id, p_external_course_id: externalCourseId, p_osm_polygons: osmData,
    })
    if (error) return json({ error: `register: ${error.message}` }, 500)
    return reply(await courseRow(picked.id))
  } catch (e) {
    console.error("register-osm-course", e)
    return json({ error: String(e) }, 502)
  }
})
