window.AiurConversationScrollHook = {
  mounted () {
    this.bottom = true
    this.onScroll = () => {
      const bottom = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 32
      if (bottom !== this.bottom) {
        this.bottom = bottom
        this.pushEvent('at_bottom', { value: bottom })
      }
    }
    this.el.addEventListener('scroll', this.onScroll)
    this.handleEvent('conversation-start', () => requestAnimationFrame(() => { this.el.scrollTop = 0; this.onScroll() }))
    this.handleEvent('conversation-bottom', () => requestAnimationFrame(() => this.toBottom()))
    this.handleEvent('conversation-command', ({ pos }) => requestAnimationFrame(() => {
      this.el.querySelector(`#entry-${pos}`)?.scrollIntoView({ block: 'start' })
      this.onScroll()
    }))
    requestAnimationFrame(() => this.toBottom())
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
  toBottom () {
    this.el.scrollTop = this.el.scrollHeight
    this.onScroll()
  },
  destroyed () {
    cancelAnimationFrame(this.frame)
    this.el.removeEventListener('scroll', this.onScroll)
  }
}
