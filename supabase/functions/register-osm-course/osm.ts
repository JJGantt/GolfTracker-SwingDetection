// OpenStreetMap golf-course geometry, fetched and shaped on the server.
//
// The output is `OSMCourseData` exactly as the app's Codable model reads it
// (GolfTracker/Services/OSMCourseService.swift), because it is stored on
// `courses.osm_polygons` and decoded by every client. The parsing mirrors
// `OSMCourseService.parseCandidates` / `parseCourseGeometry`; the client keeps
// its own copy only for a round started while this function is unreachable.

export interface MapPoint { latitude: number; longitude: number }

export interface OSMHole {
  id: string
  osmId: number
  ref?: string
  par?: number
  handicap?: number
  teePoint: MapPoint
  greenPoint: MapPoint
  centerline: MapPoint[]
}

export interface OSMPolygon { id: string; osmId: number; points: MapPoint[] }

export interface OSMCourseData {
  fetchedAt: string
  center: MapPoint
  radiusMeters: number
  holes: OSMHole[]
  greens: OSMPolygon[]
  tees: OSMPolygon[]
  fairways: OSMPolygon[]
  bunkers: OSMPolygon[]
  attribution: string
  boundingPolygons: MapPoint[][]
}

export interface ElementRef { type: "way" | "relation"; id: number }

export interface GolfCourse {
  ref: ElementRef
  name: string
  polygon: MapPoint[]
  centroid: MapPoint
}

// deno-lint-ignore no-explicit-any
type Json = any

/** Same as `OSMCourseService.clusterDistanceMeters`: a sibling feature further
 *  than this from the course is not the same course. */
export const SIBLING_MAX_METERS = 500
const DEDUP_METERS = 3
const RADIUS_METERS = 1500
const ATTRIBUTION = "Map data © OpenStreetMap contributors (ODbL)"

export function distanceMeters(a: MapPoint, b: MapPoint): number {
  const r = 6_371_000
  const toRad = (d: number) => d * Math.PI / 180
  const dLat = toRad(b.latitude - a.latitude)
  const dLon = toRad(b.longitude - a.longitude)
  const h = Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(a.latitude)) * Math.cos(toRad(b.latitude)) * Math.sin(dLon / 2) ** 2
  return 2 * r * Math.asin(Math.sqrt(h))
}

function mean(points: MapPoint[]): MapPoint {
  const n = Math.max(points.length, 1)
  return {
    latitude: points.reduce((s, p) => s + p.latitude, 0) / n,
    longitude: points.reduce((s, p) => s + p.longitude, 0) / n,
  }
}

function points(geometry: Json): MapPoint[] {
  if (!Array.isArray(geometry)) return []
  return geometry
    .filter((p: Json) => typeof p?.lat === "number" && typeof p?.lon === "number")
    .map((p: Json) => ({ latitude: p.lat, longitude: p.lon }))
}

/** Overpass for the elements themselves: tags, plus member geometry so a
 *  relation's outline can be assembled. */
export function elementsQuery(refs: ElementRef[]): string {
  const ways = refs.filter((r) => r.type === "way").map((r) => r.id)
  const rels = refs.filter((r) => r.type === "relation").map((r) => r.id)
  const parts = [
    ways.length ? `way(id:${ways.join(",")});` : "",
    rels.length ? `relation(id:${rels.join(",")});` : "",
  ].join("")
  return `[out:json][timeout:25];(${parts})->.cs;.cs out tags;(.cs;>;);out body geom;`
}

/** The named `leisure=golf_course` features in an Overpass response, by ref.
 *  Anything else (not a golf course, unnamed, no outline) is absent. */
export function parseGolfCourses(response: Json): Map<string, GolfCourse> {
  const elements: Json[] = Array.isArray(response?.elements) ? response.elements : []
  const wayPolygon = new Map<number, MapPoint[]>()
  for (const el of elements) {
    if (el.type !== "way") continue
    const pts = points(el.geometry)
    if (pts.length) wayPolygon.set(el.id, pts)
  }
  const out = new Map<string, GolfCourse>()
  for (const el of elements) {
    const tags = el.tags ?? {}
    if ((el.type !== "way" && el.type !== "relation") || tags.leisure !== "golf_course" || !tags.name) continue
    let polygon: MapPoint[] = []
    if (el.type === "way") {
      polygon = points(el.geometry)
    } else {
      for (const m of el.members ?? []) {
        const role = m.role ?? ""
        if ((role === "outer" || role === "") && m.type === "way" && wayPolygon.has(m.ref)) {
          polygon.push(...wayPolygon.get(m.ref)!)
        }
      }
      const b = el.bounds
      if (!polygon.length && b) {
        polygon = [
          { latitude: b.minlat, longitude: b.minlon },
          { latitude: b.minlat, longitude: b.maxlon },
          { latitude: b.maxlat, longitude: b.maxlon },
          { latitude: b.maxlat, longitude: b.minlon },
        ]
      }
    }
    if (polygon.length < 3) continue
    const ref: ElementRef = { type: el.type, id: el.id }
    out.set(`${ref.type}/${ref.id}`, { ref, name: tags.name, polygon, centroid: mean(polygon) })
  }
  return out
}

/** Overpass for every hole, green, tee, fairway and bunker inside any of the
 *  course's outlines. */
export function geometryQuery(polygons: MapPoint[][]): string {
  const clauses: string[] = []
  for (const poly of polygons) {
    const s = poly.map((p) => `${p.latitude} ${p.longitude}`).join(" ")
    for (const tag of ["hole", "green", "tee", "fairway", "bunker"]) {
      clauses.push(`way["golf"="${tag}"](poly:"${s}");`)
    }
  }
  return `[out:json][timeout:25];(${clauses.join("")});out tags geom;`
}

function dedup<T>(items: T[], pointsOf: (t: T) => MapPoint[]): T[] {
  const kept: MapPoint[] = []
  const out: T[] = []
  for (const item of items) {
    const pts = pointsOf(item)
    if (!pts.length) continue
    const c = mean(pts)
    if (kept.some((k) => distanceMeters(k, c) <= DEDUP_METERS)) continue
    kept.push(c)
    out.push(item)
  }
  return out
}

function intTag(v: unknown): number | undefined {
  if (typeof v !== "string" || !/^-?\d+$/.test(v.trim())) return undefined
  return parseInt(v, 10)
}

/** The course's features as `OSMCourseData`. `center` is the course outline's
 *  centroid, as the client's candidate centroid is. */
export function parseCourseGeometry(
  response: Json,
  center: MapPoint,
  boundingPolygons: MapPoint[][],
  now: Date,
  newId: () => string,
): OSMCourseData {
  const holes: OSMHole[] = []
  const buckets: Record<string, OSMPolygon[]> = { green: [], tee: [], fairway: [], bunker: [] }
  for (const el of Array.isArray(response?.elements) ? response.elements : []) {
    const tag = el?.tags?.golf
    if (el.type !== "way" || typeof tag !== "string") continue
    const pts = points(el.geometry)
    if (!pts.length) continue
    if (tag === "hole") {
      const hole: OSMHole = {
        id: newId(), osmId: el.id,
        teePoint: pts[0], greenPoint: pts[pts.length - 1], centerline: pts,
      }
      if (typeof el.tags.ref === "string") hole.ref = el.tags.ref
      const par = intTag(el.tags.par), handicap = intTag(el.tags.handicap)
      if (par !== undefined) hole.par = par
      if (handicap !== undefined) hole.handicap = handicap
      holes.push(hole)
    } else if (tag in buckets) {
      buckets[tag].push({ id: newId(), osmId: el.id, points: pts })
    }
  }
  return {
    // The app's Supabase decoder reads ISO 8601 with fractional seconds and
    // no zone (UTC), the form its encoder writes.
    fetchedAt: now.toISOString().replace("Z", ""),
    center,
    radiusMeters: RADIUS_METERS,
    holes: dedup(holes, (h) => h.centerline),
    greens: dedup(buckets.green, (p) => p.points),
    tees: dedup(buckets.tee, (p) => p.points),
    fairways: dedup(buckets.fairway, (p) => p.points),
    bunkers: dedup(buckets.bunker, (p) => p.points),
    attribution: ATTRIBUTION,
    boundingPolygons,
  }
}

/** Where the course is: the mean of its green points when OSM has holes (as
 *  the client computes it), else its outline's centroid. */
export function courseCenter(data: OSMCourseData, outlineCentroid: MapPoint): MapPoint {
  return data.holes.length ? mean(data.holes.map((h) => h.greenPoint)) : outlineCentroid
}
