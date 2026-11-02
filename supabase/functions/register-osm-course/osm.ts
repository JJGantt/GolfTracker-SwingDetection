// OpenStreetMap golf-course geometry, fetched and shaped on the server.
//
// Read from the OSM editing API (api.openstreetmap.org/api/0.6): an element's
// `full` call gives the course feature with its tags and outline, and a `map`
// call over the outline's bounding box gives every hole, green, tee, fairway
// and bunker. (Overpass, which the app queries, refuses requests from the
// Supabase edge with 406.)
//
// The output is `OSMCourseData` exactly as the app's Codable model reads it
// (GolfTracker/Services/OSMCourseService.swift), because it is stored on
// `courses.osm_polygons` and decoded by every client. The shaping mirrors
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

/** OSM API JSON (`elements` of nodes, ways and relations), indexed. */
export function indexOsm(response: Json) {
  const nodes = new Map<number, MapPoint>()
  // deno-lint-ignore no-explicit-any
  const ways = new Map<number, any>()
  // deno-lint-ignore no-explicit-any
  const relations = new Map<number, any>()
  for (const el of Array.isArray(response?.elements) ? response.elements : []) {
    if (el.type === "node" && typeof el.lat === "number" && typeof el.lon === "number") {
      nodes.set(el.id, { latitude: el.lat, longitude: el.lon })
    } else if (el.type === "way") ways.set(el.id, el)
    else if (el.type === "relation") relations.set(el.id, el)
  }
  const wayPoints = (w: Json): MapPoint[] =>
    (Array.isArray(w?.nodes) ? w.nodes : []).map((id: number) => nodes.get(id)).filter(Boolean) as MapPoint[]
  return { nodes, ways, relations, wayPoints }
}

/** The element `ref` from an OSM API `full` response, if it is a named
 *  `leisure=golf_course`. A relation's outline is its outer (or role-less)
 *  member ways joined. */
export function golfCourseFrom(response: Json, ref: ElementRef): GolfCourse | null {
  const osm = indexOsm(response)
  const el = ref.type === "way" ? osm.ways.get(ref.id) : osm.relations.get(ref.id)
  const tags = el?.tags ?? {}
  if (!el || tags.leisure !== "golf_course" || !tags.name) return null
  let polygon: MapPoint[] = []
  if (ref.type === "way") {
    polygon = osm.wayPoints(el)
  } else {
    for (const m of el.members ?? []) {
      const role = m.role ?? ""
      if ((role === "outer" || role === "") && m.type === "way" && osm.ways.has(m.ref)) {
        polygon.push(...osm.wayPoints(osm.ways.get(m.ref)))
      }
    }
  }
  if (polygon.length < 3) return null
  return { ref, name: tags.name, polygon, centroid: mean(polygon) }
}

/** The bounding box of the outlines, as the OSM API `map` call takes it. */
export function bbox(polygons: MapPoint[][]): { minLon: number; minLat: number; maxLon: number; maxLat: number } {
  const pts = polygons.flat()
  return {
    minLon: Math.min(...pts.map((p) => p.longitude)),
    minLat: Math.min(...pts.map((p) => p.latitude)),
    maxLon: Math.max(...pts.map((p) => p.longitude)),
    maxLat: Math.max(...pts.map((p) => p.latitude)),
  }
}

function inside(p: MapPoint, poly: MapPoint[]): boolean {
  let hit = false
  for (let i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    const a = poly[i], b = poly[j]
    if ((a.latitude > p.latitude) !== (b.latitude > p.latitude) &&
      p.longitude < (b.longitude - a.longitude) * (p.latitude - a.latitude) / (b.latitude - a.latitude) + a.longitude) {
      hit = !hit
    }
  }
  return hit
}

const FEATURES = new Set(["hole", "green", "tee", "fairway", "bunker"])

/** The golf features in an OSM API `map` response that have a node inside one
 *  of the outlines (what Overpass's `poly` filter selects), as ways with
 *  inline geometry for `parseCourseGeometry`. */
export function courseFeatures(response: Json, outlines: MapPoint[][]): Json {
  const osm = indexOsm(response)
  const elements: Json[] = []
  for (const w of osm.ways.values()) {
    if (!FEATURES.has(w?.tags?.golf)) continue
    const pts = osm.wayPoints(w)
    if (!pts.some((p) => outlines.some((o) => inside(p, o)))) continue
    elements.push({ type: "way", id: w.id, tags: w.tags, geometry: pts.map((p) => ({ lat: p.latitude, lon: p.longitude })) })
  }
  return { elements }
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
