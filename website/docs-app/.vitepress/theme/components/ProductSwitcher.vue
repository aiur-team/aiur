<script setup lang="ts">
// Replaces the default theme's VPNavBarTitle (see the alias in config.ts).
// The logo and wordmark become a menu button that switches between the Aiur,
// Archon and Khala docs. It follows the WAI-ARIA menu button pattern: Enter,
// Space and the arrow keys open it, arrows/Home/End move between products,
// Escape closes it and returns focus to the button, and Tab closes it.
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { useData, useRoute, useRouter, withBase } from 'vitepress'
import { useSidebar } from 'vitepress/theme'
import { productForPath, products, type Product } from '../../products'

const { page } = useData()
const { hasSidebar } = useSidebar()
const route = useRoute()
const router = useRouter()

const current = computed(() => productForPath(page.value.relativePath))

const open = ref(false)
const root = ref<HTMLElement | null>(null)
const button = ref<HTMLButtonElement | null>(null)
const items = ref<HTMLAnchorElement[]>([])

const menuId = 'product-switcher-menu'
const buttonId = 'product-switcher-button'

function focusItem(index: number) {
  const list = items.value
  if (!list.length) return
  const i = (index + list.length) % list.length
  list[i]?.focus()
}

function currentIndex() {
  return Math.max(0, products.findIndex((p) => p.id === current.value.id))
}

async function openMenu(focus: 'current' | 'first' | 'last' = 'current') {
  open.value = true
  await nextTick()
  if (focus === 'first') focusItem(0)
  else if (focus === 'last') focusItem(products.length - 1)
  else focusItem(currentIndex())
}

function closeMenu(returnFocus = true) {
  if (!open.value) return
  open.value = false
  if (returnFocus) button.value?.focus()
}

function onButtonClick() {
  if (open.value) closeMenu()
  else openMenu()
}

function onButtonKeydown(event: KeyboardEvent) {
  switch (event.key) {
    case 'ArrowDown':
    case 'Enter':
    case ' ':
      event.preventDefault()
      openMenu(event.key === 'ArrowDown' ? 'first' : 'current')
      break
    case 'ArrowUp':
      event.preventDefault()
      openMenu('last')
      break
  }
}

function onMenuKeydown(event: KeyboardEvent) {
  const index = items.value.indexOf(document.activeElement as HTMLAnchorElement)
  switch (event.key) {
    case 'ArrowDown':
      event.preventDefault()
      focusItem(index + 1)
      break
    case 'ArrowUp':
      event.preventDefault()
      focusItem(index - 1)
      break
    case 'Home':
      event.preventDefault()
      focusItem(0)
      break
    case 'End':
      event.preventDefault()
      focusItem(products.length - 1)
      break
    case 'Escape':
      event.preventDefault()
      closeMenu()
      break
    case 'Tab':
      closeMenu(false)
      break
    case ' ':
      event.preventDefault()
      if (index >= 0) choose(products[index], event)
      break
    default:
      // Type-ahead: jump to the product whose name starts with the key.
      if (event.key.length === 1 && /\S/.test(event.key)) {
        const key = event.key.toLowerCase()
        const start = index + 1
        for (let n = 0; n < products.length; n++) {
          const i = (start + n) % products.length
          if (products[i].name.toLowerCase().startsWith(key)) {
            focusItem(i)
            break
          }
        }
      }
  }
}

function href(product: Product) {
  return withBase(product.root)
}

function choose(product: Product, event: Event) {
  // Let modified clicks (new tab, new window) through to the browser.
  if (event instanceof MouseEvent && (event.metaKey || event.ctrlKey || event.shiftKey || event.button !== 0)) {
    return
  }
  event.preventDefault()
  closeMenu()
  router.go(href(product))
}

function onDocumentPointerDown(event: PointerEvent) {
  if (open.value && root.value && !root.value.contains(event.target as Node)) closeMenu(false)
}

function onFocusOut(event: FocusEvent) {
  const next = event.relatedTarget as Node | null
  if (open.value && next && root.value && !root.value.contains(next)) closeMenu(false)
}

// Close on any route change, e.g. after the browser's back button.
watch(() => route.path, () => closeMenu(false))

onMounted(() => document.addEventListener('pointerdown', onDocumentPointerDown))
onBeforeUnmount(() => document.removeEventListener('pointerdown', onDocumentPointerDown))
</script>

<template>
  <div class="VPNavBarTitle product-switcher" :class="{ 'has-sidebar': hasSidebar, open }" ref="root" @focusout="onFocusOut">
    <button
      :id="buttonId"
      ref="button"
      class="title switcher-button"
      type="button"
      aria-haspopup="menu"
      :aria-expanded="open ? 'true' : 'false'"
      :aria-controls="menuId"
      :aria-label="`${current.name} docs. Switch product`"
      @click="onButtonClick"
      @keydown="onButtonKeydown"
    >
      <img v-if="current.logo" class="logo" :src="withBase(current.logo)" alt="" />
      <span v-else class="logo monogram" aria-hidden="true">{{ current.name.charAt(0) }}</span>
      <span class="wordmark">{{ current.wordmark }}</span>
      <svg class="chevron" viewBox="0 0 24 24" width="14" height="14" aria-hidden="true">
        <path d="M6 9l6 6 6-6" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" />
      </svg>
    </button>

    <ul
      v-show="open"
      :id="menuId"
      class="switcher-menu"
      role="menu"
      :aria-labelledby="buttonId"
      @keydown="onMenuKeydown"
    >
      <li v-for="product in products" :key="product.id" role="none">
        <a
          ref="items"
          class="switcher-item"
          :class="{ active: product.id === current.id }"
          role="menuitemradio"
          :aria-checked="product.id === current.id ? 'true' : 'false'"
          :href="href(product)"
          tabindex="-1"
          @click="choose(product, $event)"
        >
          <img v-if="product.logo" class="item-logo" :src="withBase(product.logo)" alt="" />
          <span v-else class="item-logo monogram" aria-hidden="true">{{ product.name.charAt(0) }}</span>
          <span class="item-text">
            <span class="item-name">{{ product.name }}</span>
            <span class="item-blurb">{{ product.blurb }}</span>
          </span>
          <svg v-if="product.id === current.id" class="item-check" viewBox="0 0 24 24" width="16" height="16" aria-hidden="true">
            <path d="M5 12.5l4.5 4.5L19 7.5" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" />
          </svg>
        </a>
      </li>
    </ul>
  </div>
</template>

<style scoped>
.product-switcher {
  position: relative;
  height: 100%;
}

.title {
  display: flex;
  align-items: center;
  border: 0;
  border-bottom: 1px solid transparent;
  height: var(--vp-nav-height);
  padding: 0;
  background: transparent;
  color: var(--vp-c-text-1);
  cursor: pointer;
}

@media (min-width: 960px) {
  .title {
    flex-shrink: 0;
  }

  .VPNavBarTitle.has-sidebar .title {
    width: 100%;
    border-bottom-color: var(--vp-c-divider);
  }
}

.chevron {
  flex-shrink: 0;
  color: var(--aiur-muted);
  transition: transform 0.2s ease, color 0.2s ease;
}

.title:hover .chevron,
.open .chevron {
  color: var(--aiur-fg);
}

.open .chevron {
  transform: rotate(180deg);
}

.monogram {
  display: inline-grid;
  place-items: center;
  aspect-ratio: 1;
  border: 1.5px solid var(--aiur-accent);
  border-radius: 8px;
  background: color-mix(in srgb, var(--aiur-accent) 12%, transparent);
  color: var(--aiur-accent);
  font-family: "Bungee", sans-serif;
  font-weight: 400;
  line-height: 1;
}

.title .monogram {
  width: 28px;
  font-size: 16px;
}

.switcher-menu {
  position: absolute;
  top: calc(var(--vp-nav-height) - 6px);
  left: 0;
  z-index: 60;
  min-width: 264px;
  margin: 0;
  padding: 6px;
  list-style: none;
  border: 1px solid var(--aiur-line);
  border-radius: 12px;
  background: var(--vp-c-bg-elv);
  box-shadow: 0 18px 44px -18px rgba(0, 0, 0, 0.45);
}

@media (min-width: 960px) {
  .VPNavBarTitle.has-sidebar .switcher-menu {
    left: 0;
  }
}

.switcher-item {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 9px 10px;
  border-radius: 8px;
  color: var(--aiur-fg);
  text-decoration: none;
  outline: none;
}

.switcher-item:hover,
.switcher-item:focus-visible,
.switcher-item:focus {
  background: color-mix(in srgb, var(--aiur-accent) 11%, transparent);
}

.switcher-item:focus-visible {
  outline: 2px solid var(--aiur-accent) !important;
  outline-offset: -2px;
}

.item-logo {
  flex-shrink: 0;
  width: 30px;
  height: 30px;
  object-fit: contain;
}

.item-logo.monogram {
  width: 28px;
  height: 28px;
  font-size: 15px;
}

.item-text {
  display: flex;
  flex: 1;
  flex-direction: column;
  gap: 2px;
  min-width: 0;
}

.item-name {
  font-family: "Bungee", sans-serif;
  font-size: 14px;
  letter-spacing: 0.02em;
  line-height: 1.2;
}

.item-blurb {
  font-family: var(--vp-font-family-mono);
  font-size: 11.5px;
  line-height: 1.35;
  color: var(--aiur-muted);
}

.switcher-item.active .item-name {
  color: var(--aiur-accent);
}

.item-check {
  flex-shrink: 0;
  color: var(--aiur-accent);
}

@media (prefers-reduced-motion: reduce) {
  .chevron {
    transition: none;
  }
}
</style>
