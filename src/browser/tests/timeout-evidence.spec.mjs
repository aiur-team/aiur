import { test } from '@playwright/test'

test('intentional timeout produces browser evidence', async () => {
  test.setTimeout(500)
  await new Promise((resolve) => setTimeout(resolve, 1_000))
})
