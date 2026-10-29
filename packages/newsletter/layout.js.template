document.fonts.ready.then(() => {
  let removed = INITIAL_OMITTED;
  const candidates = [...document.querySelectorAll('[data-trim]')]
    .map((element, index) => ({element, index}))
    .sort((a, b) => Number(a.element.dataset.trim) - Number(b.element.dataset.trim) || b.index - a.index);
  const columns = [...document.querySelectorAll('[data-column]')];
  const boards = [...document.querySelectorAll('[data-lane-board]')];
  const lanes = [...document.querySelectorAll('[data-lane]')];
  const balance = () => {
    if (!lanes.length) return;
    let best = 0, height = Infinity;
    for (let split = 0; split <= lanes.length; split++) {
      boards[0].replaceChildren(...lanes.slice(0, split));
      boards[1].replaceChildren(...lanes.slice(split));
      const trial = Math.max(...columns.map(column => column.scrollHeight));
      if (trial < height) { height = trial; best = split; }
    }
    boards[0].replaceChildren(...lanes.slice(0, best));
    boards[1].replaceChildren(...lanes.slice(best));
  };
  balance();
  const notice = document.querySelector('.omitted');
  const update = () => {
    for (const group of document.querySelectorAll('[data-editorial-list]')) {
      const total = Number(group.dataset.total), kind = group.dataset.editorialList;
      if (!Number.isFinite(total)) continue;
      const visible = group.querySelectorAll(`[data-kind="${kind}"]`).length;
      const more = Math.max(0, total - visible);
      let marker = group.querySelector('[data-more]');
      if (!marker && more) {
        marker = document.createElement(group.tagName === 'UL' ? 'li' : 'div');
        marker.className = 'more editorial-more'; marker.dataset.more = 'true'; group.append(marker);
      }
      if (marker) {
        marker.textContent = `${kind === 'bottlenecks' && !visible ? 'Bottlenecks ' : ''}+${more} more`;
        marker.hidden = !more;
      }
    }
    notice.textContent = removed ? `${removed} lower priority items omitted; full details in report.json.` : '';
  };
  update();
  for (const {element} of candidates) {
    if (document.body.scrollHeight <= 1056 && document.body.scrollWidth <= 816) break;
    element.remove(); removed++; update(); balance();
  }
  document.body.dataset.pagesFit = String(document.body.scrollHeight <= 1056 && document.body.scrollWidth <= 816);
});
