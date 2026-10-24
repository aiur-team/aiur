import { test } from '@playwright/test'
import { assertStaticGrainCapture } from './support/build-home-grain-capture-test.mjs'

test('static grain capture pauses ambient infinite animations and resumes them', async ({ browser }) => {
  await assertStaticGrainCapture(browser)
})
