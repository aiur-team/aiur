// Range sequence owns toolbar state; board cards and scrolling have separate owners.
export async function spanState(page) {
  return page.evaluate(() => ({
    span: new URLSearchParams(location.search).get('span') ?? '1',
    ranges: [...document.querySelectorAll('[data-span]')].map(el => [el.dataset.span, el.classList.contains('on')]),
    zoom: [...document.querySelectorAll('[data-z]')].map(el => [el.dataset.z, el.disabled]),
    label: document.querySelector('.bd-zv').textContent,
    dot: document.querySelector('#bd-vp').style.getPropertyValue('--dot'),
  }))
}
