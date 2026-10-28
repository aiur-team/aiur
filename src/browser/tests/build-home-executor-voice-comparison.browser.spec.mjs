import {expect, test} from '@playwright/test'
import {openWritableUnits} from './support/units-helpers.mjs'

for (const width of [1280, 390]) {
  test(`Executor comparison controls remain usable at ${width}px`, async ({page}) => {
    await page.setViewportSize({width, height: 900})
    await openWritableUnits(page)
    await page.getByRole('button', {name: 'Open chat for its-everdred/aiur #1110'}).click()
    const drawer = page.getByRole('dialog', {name: 'Responsive Units interface'})
    const provider = drawer.getByLabel('Conversation provider')
    await expect(provider).toBeVisible()
    await provider.selectOption('openai_realtime')
    await expect(provider).toHaveValue('openai_realtime')
    const model = drawer.getByLabel('Model for this session')
    await model.fill('chosen-model')
    await expect(model).toHaveValue('chosen-model')
    await provider.selectOption('elevenlabs_agents')
    await expect(provider).toHaveValue('elevenlabs_agents')
    await drawer.getByText('Compare providers and record Kevin’s rating', {exact: true}).click()
    await expect(drawer.getByRole('columnheader', {name: 'ElevenLabs', exact: true})).toBeVisible()
    await expect(drawer.getByRole('columnheader', {name: 'OpenAI', exact: true})).toBeVisible()
    await expect(drawer.getByText('Comparison usage unavailable.', {exact: true})).toBeVisible()
    const box = await provider.boundingBox()
    expect(box.x).toBeGreaterThanOrEqual(0)
    expect(box.x + box.width).toBeLessThanOrEqual(width)
  })
}
