import {test} from "node:test"
import assert from "node:assert/strict"
import {coveredUnits, unitAt} from "./rack_drag.js"

test("maps the pointer to a unit for racks numbered from the bottom or the top", () => {
  const face = {top: 100, height: 420, rows: 42, bottomUp: true}

  assert.equal(unitAt(face, 101), 42)
  assert.equal(unitAt(face, 519), 1)
  assert.equal(unitAt(face, 100 + 10 * 12 + 5), 30)
  assert.equal(unitAt({...face, bottomUp: false}, 101), 1)
  // Pointers just outside the face clamp to its first and last units.
  assert.equal(unitAt(face, 50), 42)
  assert.equal(unitAt(face, 900), 1)
})

test("a device hangs down from the unit under the pointer", () => {
  assert.deepEqual(coveredUnits(30, 2, true), [29, 30])
  assert.deepEqual(coveredUnits(30, 1, true), [30])
  assert.deepEqual(coveredUnits(3, 2, false), [3, 4])
  // A device taller than the room below the pointer runs off the rack.
  assert.deepEqual(coveredUnits(1, 2, true), [0, 1])
})
