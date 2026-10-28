window.AiurConversationScrollHook = {
  mounted () {
    this.bottom = true
    this.filterKey = 'aiur-conversation-event-kinds'
    try {
      const kinds = JSON.parse(localStorage.getItem(this.filterKey))
      if (Array.isArray(kinds)) this.pushEvent('event_filters', { kinds })
    } catch (_) {}
    this.handleEvent('conversation-filters', ({ kinds }) => {
      try { localStorage.setItem(this.filterKey, JSON.stringify(kinds)) } catch (_) {}
    })
    this.events = document.getElementById('conversation-events')
    this.onEventScroll = () => {
      const older = this.events.querySelector('#events-older')
      if (this.events.scrollTop < 16 && older && !this.loadingEvents) {
        this.loadingEvents = true
        this.pushEvent('older_events', {}, () => { this.loadingEvents = false })
      }
    }
    this.events?.addEventListener('scroll', this.onEventScroll)
    this.onScroll = () => {
      const bottom = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 32
      if (bottom !== this.bottom) {
        this.bottom = bottom
        this.pushEvent('at_bottom', { value: bottom })
      }
    }
    this.el.addEventListener('scroll', this.onScroll)
    this.handleEvent('conversation-jump', () => requestAnimationFrame(() => this.toHighlight()))
    this.handleEvent('conversation-start', () => requestAnimationFrame(() => { this.el.scrollTop = 0; this.onScroll() }))
    this.handleEvent('conversation-bottom', () => requestAnimationFrame(() => this.toBottom()))
    requestAnimationFrame(() => { if (!this.toHighlight()) this.toBottom() })
  },
  beforeUpdate () {
    if (this.frame != null) return
    this.wasBottom = this.bottom
    this.head = this.el.dataset.head
    this.anchor = [...this.el.querySelectorAll('[data-pos]')].find(el => el.getBoundingClientRect().bottom >= this.el.getBoundingClientRect().top)
    this.anchorTop = this.anchor?.getBoundingClientRect().top
    this.firstPos = this.el.querySelector('[data-pos]')?.dataset.pos
  },
  updated () {
    if (this.frame != null) return
    this.frame = requestAnimationFrame(() => {
      this.frame = null
      const mode = this.el.dataset.mode
      const firstChanged = this.firstPos !== this.el.querySelector('[data-pos]')?.dataset.pos
      if (mode === 'start' && firstChanged) this.el.scrollTop = 0
      else if (Number(this.el.querySelector('[data-pos]')?.dataset.pos) < Number(this.firstPos) && this.anchor?.isConnected) this.el.scrollTop += this.anchor.getBoundingClientRect().top - this.anchorTop
      else if (this.wasBottom && (mode === 'tail' || this.head !== this.el.dataset.head)) this.toBottom()
      this.onScroll()
    })
  },
  toHighlight () {
    if (!this.el.dataset.highlight) return false
    const target = this.el.querySelector('[data-jump-target="true"]')
    if (!target) return false
    const top = target.getBoundingClientRect().top - this.el.getBoundingClientRect().top
    this.el.scrollTop += top - this.el.clientHeight / 2 + target.clientHeight / 2
    this.onScroll()
    return true
  },
  toBottom () {
    this.el.scrollTop = this.el.scrollHeight
    this.onScroll()
  },
  destroyed () {
    cancelAnimationFrame(this.frame)
    this.el.removeEventListener('scroll', this.onScroll)
    this.events?.removeEventListener('scroll', this.onEventScroll)
  }
}
