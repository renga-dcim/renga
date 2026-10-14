import {test} from "node:test"
import assert from "node:assert/strict"
import {clipped, place} from "./floating.js"

const viewport = {width: 400, height: 300}
const box = {width: 120, height: 40}

test("floating boxes open below their anchor", () => {
  const anchor = {top: 20, bottom: 40, left: 50}
  assert.deepEqual(place(anchor, box, viewport), {top: 44, left: 50})
})

test("they flip above when there is no room below", () => {
  const anchor = {top: 250, bottom: 270, left: 50}
  assert.deepEqual(place(anchor, box, viewport), {top: 206, left: 50})
})

test("they stay below when there is no room above either", () => {
  const anchor = {top: 30, bottom: 270, left: 50}
  assert.equal(place(anchor, box, {width: 400, height: 280}).top, 274)
})

test("they stay inside the viewport horizontally", () => {
  assert.equal(place({top: 0, bottom: 20, left: 350}, box, viewport).left, 272)
  assert.equal(place({top: 0, bottom: 20, left: -30}, box, viewport).left, 8)
})

test("only cut-off text counts as clipped", () => {
  assert.equal(clipped({scrollWidth: 200, clientWidth: 120}), true)
  assert.equal(clipped({scrollWidth: 120, clientWidth: 120}), false)
})
