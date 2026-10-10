async function layout(request) {
  const engine = await loadEngine()
  const graph = toElkGraph(request)
  const result = engine.layout(graph)

  return normalizeLayout(request, result)
}

async function loadEngine() {
  if (!enginePromise) {
    const pendingEngine = Promise.resolve().then(() => {
      const resolved = engineAssetUrl()

      importScripts(resolved.href)

      if (typeof self.onmessage !== "function") throw protocolError("engine_unavailable")

      const dispatch = self.onmessage
      self.onmessage = null
      return inlineEngine(dispatch)
    })

    enginePromise = pendingEngine
    pendingEngine.catch(() => {
      if (enginePromise === pendingEngine) enginePromise = undefined
    })
  }

  return enginePromise
}

function engineAssetUrl() {
  try {
    const worker = new URL(self.location.href)
    const parameters = Array.from(worker.searchParams.entries())

    if (!validWorkerUrl(worker) || parameters.length !== 1 || parameters[0][0] !== "engine") {
      throw protocolError("engine_unavailable")
    }

    const engine = new URL(parameters[0][1], worker.href)
    if (!validEngineUrl(engine)) throw protocolError("engine_unavailable")

    return engine
  } catch (error) {
    if (error?.code === "engine_unavailable") throw error
    throw protocolError("engine_unavailable")
  }
}

function validWorkerUrl(url) {
  return url.origin === self.location.origin &&
    url.username === "" &&
    url.password === "" &&
    url.hash === "" &&
    workerPath.test(url.pathname)
}

function validEngineUrl(url) {
  return url.origin === self.location.origin &&
    url.username === "" &&
    url.password === "" &&
    url.search === "" &&
    url.hash === "" &&
    enginePath.test(url.pathname)
}

function inlineEngine(dispatch) {
  let registered = false
  let nextId = 1

  function invoke(message) {
    let response
    const postMessage = self.postMessage

    self.postMessage = (value) => {
      response = value
    }

    try {
      dispatch({ data: { ...message, id: nextId++ } })
    } finally {
      self.postMessage = postMessage
    }

    if (!isPlainRecord(response)) throw protocolError("engine_failed")
    if (response.error) throw protocolError("engine_failed")
    return response.data
  }

  return {
    layout(graph) {
      if (!registered) {
        invoke({ cmd: "register", algorithms: ["layered"] })
        registered = true
      }

      return invoke({ cmd: "layout", graph, layoutOptions: {}, options: {} })
    }
  }
}

