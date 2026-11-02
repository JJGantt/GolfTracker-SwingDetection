// What the server makes of OSM API responses: which elements count as a golf
// course, how a relation's outline is assembled, which features belong to the
// course, and the OSMCourseData shape the app decodes.
//
//   deno test supabase/functions/register-osm-course/osm_test.ts

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts"
import { courseCenter, courseFeatures, golfCourseFrom, parseCourseGeometry } from "./osm.ts"

let nextNode = 1
/** Nodes for a closed square, and the way's node list. */
function square(lat: number, lon: number, d = 0.001) {
  const corners = [[lat, lon], [lat, lon + d], [lat + d, lon + d], [lat + d, lon]]
  const nodes = corners.map(([la, lo]) => ({ type: "node", id: nextNode++, lat: la, lon: lo }))
  return { nodes, refs: [...nodes.map((n) => n.id), nodes[0].id] }
}
function way(id: number, tags: Record<string, string>, sq: ReturnType<typeof square>) {
  return [...sq.nodes, { type: "way", id, tags, nodes: sq.refs }]
}

Deno.test("only a named golf course counts, and a relation's outline comes from its outer ways", () => {
  const outer = square(30, -81), inner = square(30.0002, -81.0002, 0.0001)
  const relation = {
    elements: [
      ...outer.nodes, ...inner.nodes,
      { type: "way", id: 1, nodes: outer.refs },
      { type: "way", id: 2, nodes: inner.refs },
      { type: "relation", id: 10, tags: { leisure: "golf_course", name: "Rel Course" },
        members: [{ type: "way", ref: 1, role: "outer" }, { type: "way", ref: 2, role: "inner" }] },
    ],
  }
  const course = golfCourseFrom(relation, { type: "relation", id: 10 })
  assertEquals(course?.name, "Rel Course")
  assertEquals(course?.polygon.length, 5)                            // the outer way only
  assertEquals(golfCourseFrom({ elements: way(20, { leisure: "park", name: "A Park" }, square(31, -82)) },
    { type: "way", id: 20 }), null)
  assertEquals(golfCourseFrom({ elements: way(21, { leisure: "golf_course" }, square(32, -82)) },
    { type: "way", id: 21 }), null)                                  // unnamed
  assertEquals(golfCourseFrom({ elements: [] }, { type: "way", id: 22 }), null)
})

Deno.test("course features are the golf ways with a node inside the outline", () => {
  const outline = [{ latitude: 30, longitude: -81 }, { latitude: 30, longitude: -80.99 },
    { latitude: 30.01, longitude: -80.99 }, { latitude: 30.01, longitude: -81 }]
  const map = {
    elements: [
      ...way(100, { golf: "green" }, square(30.005, -80.995, 0.0002)),
      ...way(101, { golf: "green" }, square(30.02, -80.995, 0.0002)),   // next course over
      ...way(102, { leisure: "pitch" }, square(30.006, -80.995, 0.0002)),
      ...way(103, { golf: "driving_range" }, square(30.007, -80.995, 0.0002)),
      ...way(104, { golf: "bunker" }, square(30.0099, -80.9901, 0.001)),  // straddles the edge
    ],
  }
  const features = courseFeatures(map, [outline])
  assertEquals(features.elements.map((e: { id: number }) => e.id).sort(), [100, 104])
  assertEquals(features.elements[0].geometry.length, 5)
})

Deno.test("course geometry is shaped as the app's OSMCourseData, with mapper duplicates removed", () => {
  const response = {
    elements: [
      { type: "way", id: 100, tags: { golf: "hole", ref: "1", par: "4", handicap: "x" },
        geometry: [{ lat: 30, lon: -81 }, { lat: 30.003, lon: -81 }] },
      { type: "way", id: 101, tags: { golf: "hole", ref: "2", par: "3" },
        geometry: [{ lat: 30.004, lon: -81 }, { lat: 30.006, lon: -81 }] },
      { type: "way", id: 200, tags: { golf: "green" }, geometry: [{ lat: 30.003, lon: -81 }, { lat: 30.0032, lon: -81 }] },
      // The same green mapped twice, a few centimetres apart.
      { type: "way", id: 201, tags: { golf: "green" }, geometry: [{ lat: 30.003000001, lon: -81 }, { lat: 30.0032, lon: -81 }] },
      { type: "way", id: 300, tags: { golf: "bunker" }, geometry: [{ lat: 30.002, lon: -81 }, { lat: 30.0021, lon: -81 }] },
    ],
  }
  let n = 0
  const data = parseCourseGeometry(response, { latitude: 30, longitude: -81 }, [],
    new Date(Date.UTC(2026, 10, 1, 12, 0, 0, 5)), () => `ID-${n++}`)
  assertEquals(data.fetchedAt, "2026-11-01T12:00:00.005")
  assertEquals(data.holes.map((h) => [h.ref, h.par, h.handicap]), [["1", 4, undefined], ["2", 3, undefined]])
  assertEquals(data.holes[0].teePoint, { latitude: 30, longitude: -81 })
  assertEquals(data.holes[0].greenPoint, { latitude: 30.003, longitude: -81 })
  assertEquals(data.greens.map((g) => g.osmId), [200])
  assertEquals(data.bunkers.length, 1)
  assertEquals(data.radiusMeters, 1500)
  // Centre: the mean of the green points when OSM has holes.
  assertEquals(courseCenter(data, { latitude: 0, longitude: 0 }), { latitude: 30.0045, longitude: -81 })
})
