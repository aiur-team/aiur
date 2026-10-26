---
title: Components
search: false
head:
  - - meta
    - name: robots
      content: noindex
---

<script setup>
import { data } from './components.data'
import ComponentList from '../.vitepress/theme/components/ComponentList.vue'
</script>

# Components

Config sections have one owner. An explicit dotted `owns.config` field overrides that section owner; for example, `github` owns `events.codeowners_refresh_seconds` while `event-bus` owns the rest of `events`.

<ComponentList :data="data" />
