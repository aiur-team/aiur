import assert from 'node:assert/strict'
import { test } from 'node:test'
import { voiceDiagram } from '../.vitepress/theme/components/directory-diagram.mjs'

test('minimum_voice_combination_follows_requires_and_handles_cycles', () => {
  const entries = [
    { id: 'voice-stt', name: 'Voice', requires: ['kernel'] },
    { id: 'kernel', name: 'Kernel', requires: ['voice-stt'] },
    { id: 'unrelated', name: 'Unrelated', requires: [] }
  ]
  assert.equal(voiceDiagram(entries), 'flowchart TB\nc_kernel["Kernel"]\nc_kernel --> c_voice_stt\nc_voice_stt["Voice"]\nc_voice_stt --> c_kernel')
})

test('minimum_combination_absent_or_incomplete', () => {
  assert.equal(voiceDiagram([]), '')
  assert.throws(() => voiceDiagram([{ id: 'voice-stt', name: 'Voice', requires: ['missing'] }]), /Missing required component: missing/)
})
