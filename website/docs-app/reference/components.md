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

<ComponentList :data="data" />
