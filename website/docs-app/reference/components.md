---
title: Component directory
---

<script setup>
import { data } from './components.data'
import ComponentDirectory from '../.vitepress/theme/components/ComponentDirectory.vue'
</script>

# Component directory

Explore what Aiur includes, what you can add, and what each component needs. Choose an operator goal or show only optional components.

<ComponentDirectory :data="data" />
