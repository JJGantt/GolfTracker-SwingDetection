// What the server makes of Overpass responses: which elements count as a golf
// course, how a relation's outline is assembled, and the OSMCourseData shape
// the app decodes.
//
//   deno test supabase/functions/register-osm-course/osm_test.ts

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts"
import { courseCenter, parseCourseGeometry, parseGolfCourses } from "./osm.ts"

const square = (lat: number, lon: number, d = 0.001) => [
  { lat, lon }, { lat, lon: lon + d }, { lat: lat + d, lon: lon + d }, { lat: lat + d, lon }, { lat, lon },
]

Deno.test("only named golf courses count, and a relation's outline comes from its outer ways", () => {
  const response = {
    elements: [
      // As Overpass returns them: tags first, then bodies with geometry.
      { type: "relation", id: 10, tags: { leisure: "golf_course", name: "Rel Course" } },
      { type: "way", id: 1, geometry: square(30, -81) },
      { type: "way", id: 2, geometry: square(30.01, -81) },
      {
        type: "relation", id: 10, tags: { leisure: "golf_course", name: "Rel Course" },
        members: [
          { type: "way", ref: 1, role: "outer" },
          { type: "way", ref: 2, role: "inner" },
        ],
      },
      { type: "way", id: 20, tags: { leisure: "golf_course", name: "Way Course" }, geometry: square(31, -82) },
      { type: "way", id: 21, tags: { leisure: "park", name: "A Park" }, geometry: square(32, -82) },
      { type: "way", id: 22, tags: { leisure: "golf_course" }, geometry: square(33, -82) },
    ],
  }
  const courses = parseGolfCourses(response)
  assertEquals([...courses.keys()].sort(), ["relation/10", "way/20"])
  assertEquals(courses.get("relation/10")!.polygon.length, 5)        // the outer way only
  assertEquals(courses.get("way/20")!.name, "Way Course")
})

Deno.test("course geometry is shaped as the app's OSMCourseData, with mapper duplicates removed", () => {
  const response = {
    elements: [
      { type: "way", id: 100, tags: { golf: "hole", ref: "1", par: "4", handicap: "x" },
        geometry: [{ lat: 30, lon: -81 }, { lat: 30.003, lon: -81 }] },
      { type: "way", id: 101, tags: { golf: "hole", ref: "2", par: "3" },
        geometry: [{ lat: 30.004, lon: -81 }, { lat: 30.006, lon: -81 }] },
      { type: "way", id: 200, tags: { golf: "green" }, geometry: square(30.003, -81, 0.0002) },
      // The same green mapped twice, a few centimetres apart.
      { type: "way", id: 201, tags: { golf: "green" }, geometry: square(30.003000001, -81, 0.0002) },
      { type: "way", id: 300, tags: { golf: "bunker" }, geometry: square(30.002, -81, 0.0001) },
      { type: "way", id: 400, tags: { golf: "driving_range" }, geometry: square(30.1, -81) },
    ],
  }
  let n = 0
  const data = parseCourseGeometry(response, { latitude: 30, longitude: -81 }, [], new Date(Date.UTC(2026, 10, 1, 12, 0, 0, 5)),
    () => `ID-${n++}`)
  assertEquals(data.fetchedAt, "2026-11-01T12:00:00.005")
  assertEquals(data.holes.map((h) => [h.ref, h.par, h.handicap]), [["1", 4, undefined], ["2", 3, undefined]])
  assertEquals(data.holes[0].teePoint, { latitude: 30, longitude: -81 })
  assertEquals(data.holes[0].greenPoint, { latitude: 30.003, longitude: -81 })
  assertEquals(data.greens.map((g) => g.osmId), [200])
  assertEquals(data.bunkers.length, 1)
  assertEquals(data.tees.length + data.fairways.length, 0)
  assertEquals(data.radiusMeters, 1500)
  // Centre: the mean of the green points when OSM has holes.
  assertEquals(courseCenter(data, { latitude: 0, longitude: 0 }), { latitude: 30.0045, longitude: -81 })
})
