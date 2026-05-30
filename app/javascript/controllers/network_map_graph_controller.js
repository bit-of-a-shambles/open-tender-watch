import { Controller } from "@hotwired/stimulus"

const EDGE_COLORS = {
  award_link: "#c8a84e",
  entity_role_link: "#a6b0bf",
  shared_individual_link: "#d8c27a"
}

export default class extends Controller {
  static targets = [
    "canvas",
    "loading",
    "error",
    "empty",
    "nodesCount",
    "edgesCount",
    "truncated",
    "summaryFlaggedSize",
    "summaryConnectedIndividuals",
    "closestNodes",
    "selectedName",
    "selectedType",
    "selectedConnections",
    "selectedContracts",
    "selectedValue",
    "selectedEntities",
    "selectedFlagged",
    "selectedFlaggedSize",
    "selectedNodeLink",
    "dateFrom",
    "dateTo",
    "limit",
    "includePublicBodies",
    "includeCompanies",
    "includeIndividuals",
    "nodeSearch",
    "searchDropdown",
    "isolateNetwork",
    "dataSourceFilter"
  ]

  static values = {
    endpoint: String,
    searchEndpoint: String,
    defaultLimit: Number,
    defaultIncludeIndividuals: String,
    defaultMustIncludeEntityIds: String,
    defaultIsolateNetwork: String,
    publicBodyLabel: String,
    companyLabel: String,
    individualLabel: String,
    edgeAwardLabel: String,
    edgeEntityRoleLabel: String,
    entityPathTemplate: String,
    companyPathTemplate: String,
    openEntityLabel: String,
    openCompanyLabel: String,
    contractsLabel: String,
    flaggedLabel: String,
    sharedIndividualsLabel: String,
    yesLabel: String,
    noLabel: String,
    errorLabel: String,
    searchPlaceholder: String,
    searchNoResultsLabel: String,
    isolateNetworkLabel: String
  }

  connect() {
    this.graphData = null
    this.selectedNodeId = null
    this.pendingSelectNodeId = null
    this.forcedEntityIds = this.parseDefaultMustIncludeEntityIds()
    this.abortController = null
    this.resizeTimer = null
    this.navigationCleanup = null
    this.svgElement = null
    this.sceneElement = null
    this.currentNodes = []
    this.currentPositions = {}
    this.currentDimensions = { width: 0, height: 0 }
    this.viewTransform = this.defaultViewTransform()
    this.currencyFormatter = new Intl.NumberFormat(undefined, {
      style: "currency",
      currency: "EUR",
      maximumFractionDigits: 0
    })
    this.integerFormatter = new Intl.NumberFormat(undefined)

    this.boundResize = this.handleResize.bind(this)
    window.addEventListener("resize", this.boundResize)

    if (this.hasIncludePublicBodiesTarget) this.includePublicBodiesTarget.checked = true
    if (this.hasIncludeCompaniesTarget) this.includeCompaniesTarget.checked = true
    if (this.hasIncludeIndividualsTarget) {
      this.includeIndividualsTarget.checked = this.defaultIncludeIndividualsEnabled()
    }
    if (this.hasIsolateNetworkTarget) {
      this.isolateNetworkTarget.checked = this.defaultIsolateNetworkEnabled()
    }

    this.loadGraph()
  }

  disconnect() {
    window.removeEventListener("resize", this.boundResize)
    clearTimeout(this.resizeTimer)
    this.abortPendingRequest()
    this.teardownNavigation()
  }

  async applyFilters(event) {
    event.preventDefault()
    await this.loadGraph()
  }

  async resetFilters(event) {
    event.preventDefault()

    if (this.hasDateFromTarget) this.dateFromTarget.value = ""
    if (this.hasDateToTarget) this.dateToTarget.value = ""
    if (this.hasLimitTarget) this.limitTarget.value = this.defaultLimitValue || 120
    if (this.hasIncludePublicBodiesTarget) this.includePublicBodiesTarget.checked = true
    if (this.hasIncludeCompaniesTarget) this.includeCompaniesTarget.checked = true
    if (this.hasIncludeIndividualsTarget) {
      this.includeIndividualsTarget.checked = this.defaultIncludeIndividualsEnabled()
    }
    if (this.hasIsolateNetworkTarget) {
      this.isolateNetworkTarget.checked = this.defaultIsolateNetworkEnabled()
    }
    if (this.hasNodeSearchTarget) this.nodeSearchTarget.value = ""
    if (this.hasDataSourceFilterTargets) {
      this.dataSourceFilterTargets.forEach((cb) => { cb.checked = true })
    }
    this.forcedEntityIds = this.parseDefaultMustIncludeEntityIds()
    this.pendingSelectNodeId = null
    this.closeSearchDropdown()

    await this.loadGraph()
  }

  resetView(event) {
    event.preventDefault()
    this.viewTransform = this.defaultViewTransform()
    this.applySceneTransform()
  }

  zoomIn(event) {
    event.preventDefault()
    this.zoomBy(1.35)
  }

  zoomOut(event) {
    event.preventDefault()
    this.zoomBy(0.74)
  }

  handleResize() {
    if (!this.graphData) return

    clearTimeout(this.resizeTimer)
    this.resizeTimer = setTimeout(() => this.renderGraph(), 120)
  }

  async loadGraph() {
    this.abortPendingRequest()
    this.showState("loading")

    const controller = new AbortController()
    this.abortController = controller

    try {
      const response = await fetch(this.buildEndpointUrl(), {
        headers: { Accept: "application/json" },
        signal: controller.signal
      })

      if (!response.ok) {
        throw new Error(`HTTP ${response.status}`)
      }

      this.graphData = await response.json()
      if (this.pendingSelectNodeId) {
        const pendingId = this.pendingSelectNodeId
        this.pendingSelectNodeId = null
        const edges = this.graphData?.edges || []
        const edgeCount = edges.filter((e) => e.source === pendingId || e.target === pendingId).length
        if (edgeCount < 2 && this._pendingFallbackHref) {
          window.location.href = this._pendingFallbackHref
          this._pendingFallbackHref = null
          return
        }
        this._pendingFallbackHref = null
        this.selectedNodeId = pendingId
      } else {
        this.selectedNodeId = this.graphData?.nodes?.[0]?.id || null
      }
      this.viewTransform = this.defaultViewTransform()
      this.renderGraph()
      if (this.selectedNodeId) this.panToNode(this.selectedNodeId)
    } catch (error) {
      if (error.name === "AbortError") return
      this.showError()
    } finally {
      if (this.abortController === controller) {
        this.abortController = null
      }
    }
  }

  renderGraph() {
    const allNodes = Array.isArray(this.graphData?.nodes) ? this.graphData.nodes : []
    const allEdges = Array.isArray(this.graphData?.edges) ? this.graphData.edges : []

    this.updateSummary(this.graphData)

    if (allNodes.length === 0 || allEdges.length === 0) {
      this.teardownNavigation()
      this.canvasTarget.innerHTML = ""
      this.renderSelectedDetails(null)
      this.renderClosestNodes(null)
      this.showState("empty")
      return
    }

    let nodes = allNodes
    let edges = allEdges

    if (this.isIsolateNetworkEnabled() && this.selectedNodeId) {
      const neighborIds = new Set([this.selectedNodeId])
      allEdges.forEach((edge) => {
        if (edge.source === this.selectedNodeId) neighborIds.add(edge.target)
        if (edge.target === this.selectedNodeId) neighborIds.add(edge.source)
      })
      nodes = allNodes.filter((node) => neighborIds.has(node.id))
      edges = allEdges.filter((edge) => neighborIds.has(edge.source) && neighborIds.has(edge.target))
    }

    const { width, height } = this.measureCanvas()
    const positions = this.computeForcePositions(nodes, edges, width, height)
    this.currentNodes = nodes
    this.currentPositions = positions
    this.currentDimensions = { width, height }
    this.drawSvg(nodes, edges, positions, width, height)

    const selectedNode = this.findSelectedNode(nodes)
    this.renderSelectedDetails(selectedNode)
    this.showState("canvas")
  }

  updateSummary(data) {
    const nodes = Array.isArray(data?.nodes) ? data.nodes : []
    const edges = Array.isArray(data?.edges) ? data.edges : []
    const truncated = Boolean(data?.meta?.truncated)
    const summary = data?.meta?.summary || {}

    this.nodesCountTarget.textContent = this.formatInteger(nodes.length)
    this.edgesCountTarget.textContent = this.formatInteger(edges.length)
    this.truncatedTarget.textContent = truncated ? this.yesLabelValue : this.noLabelValue
    this.summaryFlaggedSizeTarget.textContent = this.formatCurrency(summary.total_flagged_value || 0)
    this.summaryConnectedIndividualsTarget.textContent = this.formatInteger(summary.connected_individual_count || 0)
  }

  renderSelectedDetails(node) {
    if (!node) {
      this.selectedNameTarget.textContent = "-"
      this.selectedTypeTarget.textContent = "-"
      this.selectedConnectionsTarget.textContent = "-"
      this.selectedContractsTarget.textContent = "-"
      this.selectedValueTarget.textContent = "-"
      this.selectedEntitiesTarget.textContent = "-"
      this.selectedFlaggedTarget.textContent = "-"
      this.selectedFlaggedSizeTarget.textContent = "-"
      this.renderClosestNodes(null)
      this.hideSelectedNodeLink()
      return
    }

    const metrics = node.metrics || {}
    const edges = Array.isArray(this.graphData?.edges) ? this.graphData.edges : []
    const connectedEdges = edges.filter((edge) => edge.source === node.id || edge.target === node.id)
    const isIndividual = node.node_type === "individual"

    this.selectedNameTarget.textContent = node.label || "-"
    this.selectedTypeTarget.textContent = this.nodeTypeLabel(node)
    this.selectedConnectionsTarget.textContent = this.formatInteger(connectedEdges.length)

    if (isIndividual) {
      this.selectedContractsTarget.textContent = this.formatInteger(metrics.involved_contract_count || 0)
      this.selectedValueTarget.textContent = this.formatCurrency(metrics.involved_total_value || 0)
      this.selectedEntitiesTarget.textContent = this.formatConnectedEntities(metrics.connected_entity_labels, metrics.connected_entity_count)
      this.selectedFlaggedTarget.textContent = this.formatInteger(metrics.risk_flagged_contract_count || 0)
      this.selectedFlaggedSizeTarget.textContent = this.formatCurrency(metrics.risk_flagged_total_value || 0)
      this.renderClosestNodes(node)
      this.hideSelectedNodeLink()
      return
    }

    this.selectedContractsTarget.textContent = this.formatInteger(metrics.contract_count || 0)
    this.selectedValueTarget.textContent = this.formatCurrency(metrics.total_value || 0)
    this.selectedEntitiesTarget.textContent = "-"
    this.selectedFlaggedTarget.textContent = this.formatInteger(metrics.flagged_contract_count || 0)
    this.selectedFlaggedSizeTarget.textContent = this.formatCurrency(metrics.flagged_total_value || 0)
    this.renderClosestNodes(node)
    this.showSelectedNodeLink(node)
  }

  renderClosestNodes(node) {
    if (!this.hasClosestNodesTarget) return

    this.closestNodesTarget.innerHTML = ""

    if (!node) {
      this.closestNodesTarget.appendChild(this.closestNodePlaceholder("-"))
      return
    }

    const connectedEdges = this.closestConnectionsFor(node)

    if (connectedEdges.length === 0) {
      this.closestNodesTarget.appendChild(this.closestNodePlaceholder("-"))
      return
    }

    connectedEdges.forEach(({ edges, node: connectedNode }) => {
      const item = document.createElement("li")
      item.className = "border border-white/6 rounded p-2 bg-white/[0.02]"

      const heading = document.createElement("div")
      heading.className = "flex items-start justify-between gap-2"

      const name = document.createElement("span")
      name.className = "text-[#e8e0d4] leading-snug"
      name.textContent = this.truncateLabel(connectedNode.label, 34)

      const sortMetrics = this.connectionSortMetrics(edges)

      const headingRight = document.createElement("div")
      headingRight.className = "shrink-0 flex items-center gap-1.5"

      if (sortMetrics.sharedIndividualCount > 0) {
        const individualCount = document.createElement("span")
        individualCount.className = "text-[#d8c27a] font-mono text-[9px]"
        individualCount.textContent = this.formatSharedIndividuals(sortMetrics.sharedIndividualCount)
        headingRight.appendChild(individualCount)
      }

      const type = document.createElement("span")
      type.className = "text-white/35"
      type.textContent = this.nodeTypeLabel(connectedNode)
      headingRight.appendChild(type)

      heading.appendChild(name)
      heading.appendChild(headingRight)

      const reason = document.createElement("div")
      reason.className = "mt-1 text-white/45 leading-snug"
      reason.textContent = this.connectionReason(edges)

      item.appendChild(heading)
      item.appendChild(reason)

      const href = this.nodePathFor(connectedNode)
      if (href) {
        const link = document.createElement("a")
        link.href = href
        link.className = "mt-1.5 inline-flex items-center gap-0.5 font-mono text-[9px] text-[#c8a84e] hover:text-[#e8e0d4] transition-colors"
        const label = connectedNode.node_type === "public_body" ? this.openEntityLabelValue : this.openCompanyLabelValue
        link.textContent = `↗ ${label}`
        item.appendChild(link)
      }

      this.closestNodesTarget.appendChild(item)
    })
  }

  closestConnectionsFor(node) {
    const nodesById = new Map((this.graphData?.nodes || []).map((candidate) => [candidate.id, candidate]))
    const connectedByNodeId = new Map()

    ;(this.graphData?.edges || []).forEach((edge) => {
      if (edge.source !== node.id && edge.target !== node.id) return

      const otherId = edge.source === node.id ? edge.target : edge.source
      const connectedNode = nodesById.get(otherId)
      if (!connectedNode) return

      const connection = connectedByNodeId.get(otherId) || { node: connectedNode, edges: [] }
      connection.edges.push(edge)
      connectedByNodeId.set(otherId, connection)
    })

    return Array.from(connectedByNodeId.values())
      .sort((a, b) => {
        const aMetrics = this.connectionSortMetrics(a.edges)
        const bMetrics = this.connectionSortMetrics(b.edges)

        return (
          bMetrics.contractCount - aMetrics.contractCount ||
          bMetrics.sharedIndividualCount - aMetrics.sharedIndividualCount ||
          bMetrics.flaggedTotalValue - aMetrics.flaggedTotalValue ||
          bMetrics.totalValue - aMetrics.totalValue
        )
      })
      .slice(0, 10)
  }

  connectionSortMetrics(edges) {
    return edges.reduce((memo, edge) => {
      const metrics = edge.metrics || {}
      memo.contractCount += Number(metrics.contract_count || 0)
      memo.sharedIndividualCount += Number(metrics.shared_individual_count || 0)
      memo.flaggedTotalValue += Number(metrics.flagged_total_value || 0)
      memo.totalValue += Number(metrics.total_value || 0)
      return memo
    }, {
      contractCount: 0,
      sharedIndividualCount: 0,
      flaggedTotalValue: 0,
      totalValue: 0
    })
  }

  closestNodePlaceholder(text) {
    const item = document.createElement("li")
    item.className = "text-white/35"
    item.textContent = text
    return item
  }

  drawSvg(nodes, edges, positions, width, height) {
    this.teardownNavigation()
    this.svgElement = null
    this.sceneElement = null

    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg")
    svg.setAttribute("viewBox", `0 0 ${width} ${height}`)
    svg.setAttribute("class", "w-full h-full")

    const scene = document.createElementNS("http://www.w3.org/2000/svg", "g")

    const selectedNodeId = this.selectedNodeId
    const maxRiskScore = Math.max(
      1,
      ...nodes
        .filter((node) => node.node_type !== "individual")
        .map((node) => this.riskScore(node))
    )
    const maxEdgeFlaggedValue = Math.max(
      1,
      ...edges.map((edge) => Number(edge.metrics?.flagged_total_value || 0))
    )

    edges.forEach((edge) => {
      const source = positions[edge.source]
      const target = positions[edge.target]
      if (!source || !target) return

      const isSelected = selectedNodeId && (edge.source === selectedNodeId || edge.target === selectedNodeId)
      const contractCount = edge.metrics?.contract_count || 0
      const sharedIndividualCount = edge.metrics?.shared_individual_count || 0
      const flaggedValue = Number(edge.metrics?.flagged_total_value || 0)
      const flaggedRatio = Math.max(0, Math.min(1, flaggedValue / maxEdgeFlaggedValue))
      const line = document.createElementNS("http://www.w3.org/2000/svg", "line")

      line.setAttribute("x1", source.x)
      line.setAttribute("y1", source.y)
      line.setAttribute("x2", target.x)
      line.setAttribute("y2", target.y)
      line.setAttribute("stroke", this.edgeStrokeColor(edge.edge_type, flaggedRatio))
      const strokeWidth = Math.min(8, 1 + contractCount * 0.1 + sharedIndividualCount * 0.35 + flaggedRatio * 3.5)
      line.setAttribute("stroke-width", String(strokeWidth))
      line.dataset.baseStrokeWidth = String(strokeWidth)
      line.setAttribute("opacity", isSelected || !selectedNodeId ? "0.9" : "0.32")
      if (edge.edge_type === "shared_individual_link") {
        line.setAttribute("stroke-dasharray", "4 4")
      }

      const title = document.createElementNS("http://www.w3.org/2000/svg", "title")
      title.textContent = this.edgeReason(edge)
      line.appendChild(title)

      scene.appendChild(line)
    })

    const labeled = nodes
      .filter((node) => node.node_type !== "individual")
      .sort((a, b) => (b.metrics?.contract_count || 0) - (a.metrics?.contract_count || 0))
      .slice(0, 18)
      .map((node) => node.id)

    nodes.forEach((node) => {
      const point = positions[node.id]
      if (!point) return

      const isSelected = node.id === selectedNodeId
      const isIndividual = node.node_type === "individual"
      const flaggedValue = Number(node.metrics?.flagged_total_value || 0)
      const riskScore = this.riskScore(node)
      const riskRatio = Math.max(0, Math.min(1, riskScore / maxRiskScore))
      const radius = this.nodeRadius(node, maxRiskScore)

      const fill = isIndividual
        ? "#a6b0bf"
        : (node.node_type === "public_body" ? "#44b7ff" : "#ff9f5b")
      const stroke = isSelected
        ? "#ffffff"
        : (isIndividual ? "rgba(255,255,255,0.25)" : this.mixHex("#2f3440", "#ff4444", riskRatio * 0.8))

      const circle = document.createElementNS("http://www.w3.org/2000/svg", "circle")
      circle.setAttribute("cx", point.x)
      circle.setAttribute("cy", point.y)
      circle.setAttribute("r", radius)
      circle.setAttribute("fill", fill)
      circle.setAttribute("stroke", stroke)
      circle.setAttribute("stroke-width", isSelected ? "2.5" : "1")
      circle.setAttribute("class", "cursor-pointer")
      circle.dataset.baseRadius = String(radius)
      circle.dataset.baseStrokeWidth = isSelected ? "2.5" : "1"

      circle.addEventListener("click", (event) => {
        event.stopPropagation()
        this.selectNode(node.id)
      })

      const title = document.createElementNS("http://www.w3.org/2000/svg", "title")
      title.textContent = `${node.label} · ${this.formatInteger(node.metrics?.contract_count || 0)} · Risk score ${this.formatInteger(riskScore)} · Flagged ${this.formatCurrency(flaggedValue)}`
      circle.appendChild(title)

      scene.appendChild(circle)

      if (labeled.includes(node.id)) {
        const label = document.createElementNS("http://www.w3.org/2000/svg", "text")
        label.setAttribute("x", point.x + radius + 6)
        label.setAttribute("y", point.y + 4)
        label.setAttribute("fill", "rgba(232,224,212,0.75)")
        label.setAttribute("font-size", "10")
        label.setAttribute("font-family", "ui-monospace, SFMono-Regular, Menlo, monospace")
        label.dataset.baseFontSize = "10"
        label.dataset.baseOffset = String(radius + 6)
        label.dataset.anchorX = String(point.x)
        label.textContent = this.truncateLabel(node.label, 20)
        scene.appendChild(label)
      }
    })

    svg.appendChild(scene)

    this.canvasTarget.innerHTML = ""
    this.canvasTarget.appendChild(svg)
    this.svgElement = svg
    this.sceneElement = scene
    this.enableNavigation(svg)
    this.applySceneTransform()
  }

  selectNode(nodeId) {
    this.selectedNodeId = nodeId
    this.renderGraph()
  }

  toggleIsolateNetwork() {
    this.renderGraph()
  }

  inputNodeSearch(event) {
    const query = event.target.value.trim()
    clearTimeout(this._searchTimer)
    if (query.length < 2) {
      this.closeSearchDropdown()
      return
    }
    this._searchTimer = setTimeout(() => this.fetchSearchResults(query), 220)
  }

  async fetchSearchResults(query) {
    if (!this.searchEndpointValue) return
    try {
      const url = new URL(this.searchEndpointValue, window.location.origin)
      url.searchParams.set("q", query)
      const response = await fetch(url.toString(), { headers: { Accept: "application/json" } })
      if (!response.ok) return
      const data = await response.json()
      const loadedNodeIds = new Set((this.graphData?.nodes || []).map((n) => n.id))
      this.renderSearchDropdown(data.results || [], loadedNodeIds)
    } catch {
      // silently ignore fetch errors in search
    }
  }

  blurNodeSearch() {
    setTimeout(() => this.closeSearchDropdown(), 200)
  }

  renderSearchDropdown(results, loadedNodeIds) {
    if (!this.hasSearchDropdownTarget) return
    this.searchDropdownTarget.innerHTML = ""
    this.searchDropdownTarget.classList.remove("hidden")

    if (results.length === 0) {
      const empty = document.createElement("div")
      empty.className = "px-3 py-2 font-mono text-[11px]"
      empty.style.color = "rgba(255,255,255,0.35)"
      empty.textContent = this.searchNoResultsLabelValue
      this.searchDropdownTarget.appendChild(empty)
      return
    }

    results.forEach((result) => {
      const inGraph = loadedNodeIds.has(result.node_id)
      const btn = document.createElement("button")
      btn.type = "button"
      btn.style.cssText = "width:100%;text-align:left;padding:8px 12px;display:flex;align-items:center;justify-content:space-between;gap:8px;cursor:pointer;"

      btn.addEventListener("mouseover", () => { btn.style.background = "rgba(255,255,255,0.06)" })
      btn.addEventListener("mouseout", () => { btn.style.background = "" })

      const left = document.createElement("span")
      left.style.cssText = "display:flex;flex-direction:column;gap:2px;min-width:0;"

      const name = document.createElement("span")
      name.style.cssText = "font-family:ui-monospace,monospace;font-size:11px;color:#e8e0d4;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;"
      name.textContent = result.name

      let typeLabel = this.companyLabelValue
      if (result.node_type === "public_body") typeLabel = this.publicBodyLabelValue
      if (result.node_type === "individual") typeLabel = this.individualLabelValue || "Individual"
      const type = document.createElement("span")
      type.style.cssText = "font-family:ui-monospace,monospace;font-size:10px;color:rgba(255,255,255,0.35);"
      const entityCount = Number(result.entity_count || 0)
      type.textContent = result.node_type === "individual" && entityCount > 0
        ? `${typeLabel} · ${this.formatInteger(entityCount)} links`
        : typeLabel

      left.appendChild(name)
      left.appendChild(type)

      const badge = document.createElement("span")
      const badgeStyle = inGraph
        ? "color:#c8a84e;background:rgba(200,168,78,0.12);border:1px solid rgba(200,168,78,0.25);"
        : "color:rgba(255,255,255,0.3);background:rgba(255,255,255,0.04);border:1px solid rgba(255,255,255,0.1);"
      badge.style.cssText = `font-family:ui-monospace,monospace;font-size:9px;white-space:nowrap;padding:2px 6px;border-radius:3px;flex-shrink:0;${badgeStyle}`
      badge.textContent = inGraph ? "↗ In map" : "↗ Open network"

      btn.appendChild(left)
      btn.appendChild(badge)

      btn.addEventListener("click", () => {
        if (this.hasNodeSearchTarget) this.nodeSearchTarget.value = result.name
        this.closeSearchDropdown()
        const isIndividual = result.node_type === "individual"

        if (isIndividual && this.hasIncludeIndividualsTarget && !this.includeIndividualsTarget.checked) {
          this.includeIndividualsTarget.checked = true
        }

        if (isIndividual) {
          const entityIds = Array.isArray(result.entity_ids) ? result.entity_ids : []
          entityIds.forEach((id) => {
            const parsedId = Number(id)
            if (!Number.isInteger(parsedId)) return
            if (!this.forcedEntityIds.includes(parsedId)) {
              this.forcedEntityIds.push(parsedId)
            }
          })

          this.pendingSelectNodeId = result.node_id
          this._pendingFallbackHref = null
          if (this.hasIsolateNetworkTarget) this.isolateNetworkTarget.checked = true
          this.loadGraph()
          return
        }

        if (inGraph) {
          this.selectNode(result.node_id)
          this.panToNode(result.node_id)
          if (this.hasIsolateNetworkTarget) this.isolateNetworkTarget.checked = true
          this.renderGraph()
        } else {
          if (!this.forcedEntityIds.includes(result.id)) {
            this.forcedEntityIds.push(result.id)
          }
          this.pendingSelectNodeId = result.node_id
          const isPublicBody = result.node_type === "public_body"
          const template = isPublicBody ? this.entityPathTemplateValue : this.companyPathTemplateValue
          const href = String(template || "").replace("__ID__", String(result.id))
          this._pendingFallbackHref = href && href !== template ? href : null
          if (this.hasIsolateNetworkTarget) this.isolateNetworkTarget.checked = true
          this.loadGraph()
        }
      })

      this.searchDropdownTarget.appendChild(btn)
    })
  }

  closeSearchDropdown() {
    if (!this.hasSearchDropdownTarget) return
    this.searchDropdownTarget.classList.add("hidden")
    this.searchDropdownTarget.innerHTML = ""
  }

  panToNode(nodeId) {
    const pos = this.currentPositions[nodeId]
    if (!pos || !this.currentDimensions.width) return
    const { width, height } = this.currentDimensions
    this.viewTransform.tx = width / 2 - pos.x * this.viewTransform.scale
    this.viewTransform.ty = height / 2 - pos.y * this.viewTransform.scale
    this.applySceneTransform()
  }

  isIsolateNetworkEnabled() {
    return this.hasIsolateNetworkTarget && this.isolateNetworkTarget.checked
  }

  nodePathFor(node) {
    if (!node?.entity_id || node.node_type === "individual") return null
    const isPublicBody = node.node_type === "public_body"
    const template = isPublicBody ? this.entityPathTemplateValue : this.companyPathTemplateValue
    const href = String(template || "").replace("__ID__", String(node.entity_id))
    return href && href !== template ? href : null
  }

  findSelectedNode(nodes) {
    if (!this.selectedNodeId) {
      return nodes[0] || null
    }

    return nodes.find((node) => node.id === this.selectedNodeId) || nodes[0] || null
  }

  computeForcePositions(nodes, edges, width, height) {
    const positions = {}
    const velocities = {}
    const margin = 24
    const centerX = width / 2
    const centerY = height / 2

    const entityNodes = nodes.filter((n) => n.node_type !== "individual")
    const individualNodes = nodes.filter((n) => n.node_type === "individual")
    const entityNodeIds = new Set(entityNodes.map((n) => n.id))

    // Initialise positions for entity nodes only
    entityNodes.forEach((node, index) => {
      const angle = (index / Math.max(entityNodes.length, 1)) * Math.PI * 2
      const ring = 60 + (index % 11) * 14
      positions[node.id] = {
        x: centerX + ring * Math.cos(angle),
        y: centerY + ring * Math.sin(angle)
      }
      velocities[node.id] = { x: 0, y: 0 }
    })

    // Run force simulation only on entity-to-entity edges (award_link + shared_individual_link)
    const entityEdges = edges.filter((e) => entityNodeIds.has(e.source) && entityNodeIds.has(e.target))

    const nodeCount = Math.max(entityNodes.length, 1)
    const area = width * height
    const k = Math.sqrt(area / nodeCount)

    for (let iteration = 0; iteration < 120; iteration += 1) {
      const displacements = {}
      entityNodes.forEach((node) => {
        displacements[node.id] = { x: 0, y: 0 }
      })

      for (let i = 0; i < entityNodes.length; i += 1) {
        for (let j = i + 1; j < entityNodes.length; j += 1) {
          const a = entityNodes[i]
          const b = entityNodes[j]
          const deltaX = positions[a.id].x - positions[b.id].x
          const deltaY = positions[a.id].y - positions[b.id].y
          const distance = Math.max(6, Math.hypot(deltaX, deltaY))
          const force = (k * k) / distance
          const x = (deltaX / distance) * force
          const y = (deltaY / distance) * force

          displacements[a.id].x += x
          displacements[a.id].y += y
          displacements[b.id].x -= x
          displacements[b.id].y -= y
        }
      }

      entityEdges.forEach((edge) => {
        const source = positions[edge.source]
        const target = positions[edge.target]
        if (!source || !target) return

        const deltaX = source.x - target.x
        const deltaY = source.y - target.y
        const distance = Math.max(6, Math.hypot(deltaX, deltaY))
        const force = (distance * distance) / Math.max(k, 1)
        const x = (deltaX / distance) * force
        const y = (deltaY / distance) * force

        displacements[edge.source].x -= x
        displacements[edge.source].y -= y
        displacements[edge.target].x += x
        displacements[edge.target].y += y
      })

      entityNodes.forEach((node) => {
        const toCenterX = (centerX - positions[node.id].x) * 0.015
        const toCenterY = (centerY - positions[node.id].y) * 0.015

        velocities[node.id].x = (velocities[node.id].x + displacements[node.id].x * 0.008 + toCenterX) * 0.78
        velocities[node.id].y = (velocities[node.id].y + displacements[node.id].y * 0.008 + toCenterY) * 0.78

        positions[node.id].x = Math.max(margin, Math.min(width - margin, positions[node.id].x + velocities[node.id].x))
        positions[node.id].y = Math.max(margin, Math.min(height - margin, positions[node.id].y + velocities[node.id].y))
      })
    }

    // Place individual nodes in Fibonacci spirals around their connected entities.
    // This avoids including them in the O(n²) repulsion loop while keeping them
    // visually anchored to their entity.
    if (individualNodes.length > 0) {
      const individualEntityLinks = new Map()
      edges.forEach((edge) => {
        if (edge.edge_type !== "entity_role_link") return
        const srcIsEntity = entityNodeIds.has(edge.source)
        const tgtIsEntity = entityNodeIds.has(edge.target)
        if (srcIsEntity === tgtIsEntity) return

        const entityId = srcIsEntity ? edge.source : edge.target
        const individualId = srcIsEntity ? edge.target : edge.source
        const list = individualEntityLinks.get(individualId) || []
        list.push(entityId)
        individualEntityLinks.set(individualId, list)
      })

      const entityIndividualCount = new Map()
      individualEntityLinks.forEach((entityIds) => {
        entityIds.forEach((entityId) => {
          entityIndividualCount.set(entityId, (entityIndividualCount.get(entityId) || 0) + 1)
        })
      })

      const entityIndividualIndex = new Map()
      const goldenAngle = 2.399963

      individualNodes.forEach((node) => {
        const entityIds = individualEntityLinks.get(node.id)
        if (!entityIds || entityIds.length === 0) {
          positions[node.id] = { x: centerX, y: centerY }
          return
        }

        const primaryEntityId = entityIds.reduce((best, id) =>
          (entityIndividualCount.get(id) || 0) > (entityIndividualCount.get(best) || 0) ? id : best
        , entityIds[0])

        const count = entityIndividualCount.get(primaryEntityId) || 1
        const idx = entityIndividualIndex.get(primaryEntityId) || 0
        entityIndividualIndex.set(primaryEntityId, idx + 1)

        let avgX = 0
        let avgY = 0
        entityIds.forEach((entityId) => {
          const pos = positions[entityId] || { x: centerX, y: centerY }
          avgX += pos.x
          avgY += pos.y
        })
        avgX /= entityIds.length
        avgY /= entityIds.length

        const r = Math.min(14 + idx * 1.6, 55)
        const theta = idx * goldenAngle

        positions[node.id] = {
          x: Math.max(margin, Math.min(width - margin, avgX + r * Math.cos(theta))),
          y: Math.max(margin, Math.min(height - margin, avgY + r * Math.sin(theta)))
        }
      })
    }

    return positions
  }

  measureCanvas() {
    const rect = this.canvasTarget.getBoundingClientRect()

    return {
      width: Math.max(420, Math.floor(rect.width || 860)),
      height: 520
    }
  }

  enableNavigation(svg) {
    let dragging = false
    let activePointerId = null
    let startClientX = 0
    let startClientY = 0
    let startTx = 0
    let startTy = 0
    let draggedDistance = 0

    const onPointerDown = (event) => {
      if (event.button !== 0) return

      dragging = true
      activePointerId = event.pointerId
      startClientX = event.clientX
      startClientY = event.clientY
      startTx = this.viewTransform.tx
      startTy = this.viewTransform.ty
      draggedDistance = 0

      svg.setPointerCapture(event.pointerId)
      svg.style.cursor = "grabbing"
      svg.style.userSelect = "none"
    }

    const onPointerMove = (event) => {
      if (!dragging || event.pointerId !== activePointerId) return

      const dx = event.clientX - startClientX
      const dy = event.clientY - startClientY
      draggedDistance = Math.max(draggedDistance, Math.hypot(dx, dy))
      this.viewTransform.tx = startTx + dx
      this.viewTransform.ty = startTy + dy
      this.applySceneTransform()
    }

    const endDrag = (event) => {
      if (!dragging || (event && event.pointerId !== activePointerId)) return

      dragging = false
      if (event) {
        try {
          svg.releasePointerCapture(event.pointerId)
        } catch {
          // no-op
        }
      }
      activePointerId = null
      svg.style.cursor = "grab"
      svg.style.userSelect = ""
    }

    const onWheel = (event) => {
      event.preventDefault()
      const factor = event.deltaY < 0 ? 1.12 : 0.89
      this.zoomAtPoint(factor, event.clientX, event.clientY, svg.getBoundingClientRect())
    }

    const onClick = (event) => {
      if (draggedDistance > 4) return

      this.selectNearestNode(event)
    }

    svg.style.cursor = "grab"
    svg.style.touchAction = "none"
    svg.addEventListener("pointerdown", onPointerDown)
    svg.addEventListener("pointermove", onPointerMove)
    svg.addEventListener("pointerup", endDrag)
    svg.addEventListener("pointercancel", endDrag)
    svg.addEventListener("pointerleave", endDrag)
    svg.addEventListener("wheel", onWheel, { passive: false })
    svg.addEventListener("click", onClick)

    this.navigationCleanup = () => {
      svg.removeEventListener("pointerdown", onPointerDown)
      svg.removeEventListener("pointermove", onPointerMove)
      svg.removeEventListener("pointerup", endDrag)
      svg.removeEventListener("pointercancel", endDrag)
      svg.removeEventListener("pointerleave", endDrag)
      svg.removeEventListener("wheel", onWheel)
      svg.removeEventListener("click", onClick)
      svg.style.touchAction = ""
      svg.style.cursor = ""
      svg.style.userSelect = ""
    }
  }

  defaultViewTransform() {
    return { scale: 1, tx: 0, ty: 0 }
  }

  applySceneTransform() {
    if (!this.sceneElement) return

    const { tx, ty, scale } = this.viewTransform
    this.sceneElement.setAttribute(
      "transform",
      `matrix(${scale.toFixed(4)}, 0, 0, ${scale.toFixed(4)}, ${tx.toFixed(2)}, ${ty.toFixed(2)})`
    )
    this.applyZoomDetailScale()
  }

  applyZoomDetailScale() {
    if (!this.sceneElement) return

    const scale = Math.max(this.viewTransform.scale || 1, 0.01)
    const nodeDetailScale = Math.min(1.35, 1 / Math.pow(scale, 2.2))
    const edgeDetailScale = Math.min(1.2, 1 / Math.pow(scale, 3.0))
    const labelDetailScale = Math.min(1.2, 1 / Math.pow(scale, 2.4))

    this.sceneElement.querySelectorAll("line[data-base-stroke-width]").forEach((line) => {
      const baseStrokeWidth = Number(line.dataset.baseStrokeWidth || 1)
      line.setAttribute("stroke-width", Math.max(0.15, baseStrokeWidth * edgeDetailScale).toFixed(3))
      if (line.getAttribute("stroke-dasharray")) {
        const dash = 4 * edgeDetailScale
        line.setAttribute("stroke-dasharray", `${dash.toFixed(2)} ${dash.toFixed(2)}`)
      }
    })

    this.sceneElement.querySelectorAll("circle[data-base-radius]").forEach((circle) => {
      const baseRadius = Number(circle.dataset.baseRadius || 1)
      const baseStrokeWidth = Number(circle.dataset.baseStrokeWidth || 1)
      circle.setAttribute("r", Math.max(1.15, baseRadius * nodeDetailScale).toFixed(3))
      circle.setAttribute("stroke-width", Math.max(0.2, baseStrokeWidth * edgeDetailScale).toFixed(3))
    })

    this.sceneElement.querySelectorAll("text[data-base-font-size]").forEach((label) => {
      const baseFontSize = Number(label.dataset.baseFontSize || 10)
      const baseOffset = Number(label.dataset.baseOffset || 12)
      const anchorX = Number(label.dataset.anchorX || label.getAttribute("x") || 0)
      label.setAttribute("font-size", Math.max(2, baseFontSize * labelDetailScale).toFixed(3))
      label.setAttribute("x", (anchorX + baseOffset * nodeDetailScale).toFixed(3))
    })
  }

  zoomBy(factor) {
    if (!this.svgElement) return

    const rect = this.svgElement.getBoundingClientRect()
    const centerX = rect.left + rect.width / 2
    const centerY = rect.top + rect.height / 2
    this.zoomAtPoint(factor, centerX, centerY, rect)
  }

  zoomAtPoint(factor, clientX, clientY, rect) {
    if (!this.svgElement) return

    const bounds = rect || this.svgElement.getBoundingClientRect()
    const { x: pointX, y: pointY } = this.svgPointFromClient(clientX, clientY, bounds)

    const previousScale = this.viewTransform.scale
    const nextScale = Math.min(4.0, Math.max(0.35, previousScale * factor))
    if (Math.abs(nextScale - previousScale) < 0.0001) return

    this.viewTransform.tx = pointX - ((pointX - this.viewTransform.tx) * (nextScale / previousScale))
    this.viewTransform.ty = pointY - ((pointY - this.viewTransform.ty) * (nextScale / previousScale))
    this.viewTransform.scale = nextScale
    this.applySceneTransform()
  }

  selectNearestNode(event) {
    if (!this.svgElement || !this.currentNodes.length) return

    const point = this.svgPointFromClient(event.clientX, event.clientY, this.svgElement.getBoundingClientRect())
    const sceneX = (point.x - this.viewTransform.tx) / this.viewTransform.scale
    const sceneY = (point.y - this.viewTransform.ty) / this.viewTransform.scale
    const maxRiskScore = Math.max(
      1,
      ...this.currentNodes
        .filter((node) => node.node_type !== "individual")
        .map((node) => this.riskScore(node))
    )

    let nearest = null
    let nearestDistance = Infinity

    this.currentNodes.forEach((node) => {
      const nodePoint = this.currentPositions[node.id]
      if (!nodePoint) return

      const distance = Math.hypot(sceneX - nodePoint.x, sceneY - nodePoint.y)
      const visibleRadius = this.nodeRadius(node, maxRiskScore) * Math.min(1.35, 1 / Math.pow(this.viewTransform.scale, 2.2))
      const threshold = Math.max(visibleRadius + 9 / this.viewTransform.scale, 18 / this.viewTransform.scale)
      if (distance <= threshold && distance < nearestDistance) {
        nearest = node
        nearestDistance = distance
      }
    })

    if (nearest) this.selectNode(nearest.id)
  }

  svgPointFromClient(clientX, clientY, rect) {
    const bounds = rect || this.svgElement.getBoundingClientRect()
    const width = this.currentDimensions.width || bounds.width || 1
    const height = this.currentDimensions.height || bounds.height || 1

    return {
      x: ((clientX - bounds.left) / Math.max(bounds.width, 1)) * width,
      y: ((clientY - bounds.top) / Math.max(bounds.height, 1)) * height
    }
  }

  teardownNavigation() {
    if (!this.navigationCleanup) return

    this.navigationCleanup()
    this.navigationCleanup = null
  }

  buildEndpointUrl() {
    const url = new URL(this.endpointValue, window.location.origin)

    if (this.hasDateFromTarget && this.dateFromTarget.value) {
      url.searchParams.set("date_from", this.dateFromTarget.value)
    }

    if (this.hasDateToTarget && this.dateToTarget.value) {
      url.searchParams.set("date_to", this.dateToTarget.value)
    }

    if (this.hasLimitTarget && this.limitTarget.value) {
      url.searchParams.set("limit", this.limitTarget.value)
    }

    if (this.hasIncludePublicBodiesTarget) {
      url.searchParams.set("include_public_bodies", this.includePublicBodiesTarget.checked ? "true" : "false")
    }

    if (this.hasIncludeCompaniesTarget) {
      url.searchParams.set("include_companies", this.includeCompaniesTarget.checked ? "true" : "false")
    }

    if (this.hasIncludeIndividualsTarget && this.includeIndividualsTarget.checked) {
      url.searchParams.set("include_individuals", "true")
    }

    if (this.hasIsolateNetworkTarget && this.isolateNetworkTarget.checked) {
      url.searchParams.set("isolate_network", "true")
    }

    if (this.hasDataSourceFilterTargets) {
      this.dataSourceFilterTargets
        .filter((cb) => cb.checked)
        .forEach((cb) => url.searchParams.append("data_source_ids[]", cb.value))
    }

    if (this.forcedEntityIds?.length) {
      this.forcedEntityIds.forEach((id) => url.searchParams.append("must_include_entity_ids[]", id))
    }

    return url.toString()
  }

  defaultIncludeIndividualsEnabled() {
    const raw = this.defaultIncludeIndividualsValue || this.element.getAttribute("data-network-map-graph-default-include-individuals-value")
    return this.truthy(raw)
  }

  defaultIsolateNetworkEnabled() {
    const raw = this.defaultIsolateNetworkValue || this.element.getAttribute("data-network-map-graph-default-isolate-network-value")
    return this.truthy(raw)
  }

  parseDefaultMustIncludeEntityIds() {
    const raw = this.defaultMustIncludeEntityIdsValue || this.element.getAttribute("data-network-map-graph-default-must-include-entity-ids-value")

    return String(raw || "")
      .split(",")
      .map((value) => Number.parseInt(String(value).trim(), 10))
      .filter((value) => Number.isInteger(value) && value > 0)
  }

  truthy(value) {
    const normalized = String(value || "").trim().toLowerCase()
    return ["true", "1", "yes", "sim"].includes(normalized)
  }

  abortPendingRequest() {
    if (this.abortController) {
      this.abortController.abort()
      this.abortController = null
    }
  }

  showState(state) {
    this.toggleOverlay(this.loadingTarget, state === "loading")
    this.toggleOverlay(this.errorTarget, state === "error")
    this.toggleOverlay(this.emptyTarget, state === "empty")
  }

  showError() {
    this.canvasTarget.innerHTML = ""
    this.renderSelectedDetails(null)
    this.errorTarget.textContent = this.errorLabelValue
    this.showState("error")
    this.updateSummary(null)
  }

  showSelectedNodeLink(node) {
    if (!this.hasSelectedNodeLinkTarget || !node?.entity_id) return

    const isPublicBody = node.node_type === "public_body"
    const template = isPublicBody ? this.entityPathTemplateValue : this.companyPathTemplateValue
    const label = isPublicBody ? this.openEntityLabelValue : this.openCompanyLabelValue
    const href = String(template || "").replace("__ID__", String(node.entity_id))

    if (!href || href === template) {
      this.hideSelectedNodeLink()
      return
    }

    this.selectedNodeLinkTarget.href = href
    this.selectedNodeLinkTarget.textContent = label
    this.selectedNodeLinkTarget.classList.remove("hidden")
    this.selectedNodeLinkTarget.classList.add("inline-flex")
  }

  hideSelectedNodeLink() {
    if (!this.hasSelectedNodeLinkTarget) return

    this.selectedNodeLinkTarget.href = "#"
    this.selectedNodeLinkTarget.classList.add("hidden")
    this.selectedNodeLinkTarget.classList.remove("inline-flex")
  }

  edgeTypeLabel(edgeType) {
    if (edgeType === "award_link") return this.edgeAwardLabelValue
    if (edgeType === "entity_role_link") return this.edgeEntityRoleLabelValue
    if (edgeType === "shared_individual_link") return this.sharedIndividualsLabelValue

    return edgeType
  }

  connectionReason(edges) {
    return edges.map((edge) => this.edgeReason(edge)).join(" / ")
  }

  edgeReason(edge) {
    const metrics = edge.metrics || {}
    const parts = [this.edgeTypeLabel(edge.edge_type)]

    if (metrics.role_label) parts.push(metrics.role_label)
    if (metrics.shared_individual_count) parts.push(this.formatSharedIndividuals(metrics.shared_individual_count))
    if (metrics.contract_count) parts.push(`${this.formatInteger(metrics.contract_count)} ${this.contractsLabelValue}`)
    if (metrics.total_value) parts.push(this.formatCurrency(metrics.total_value))
    if (metrics.flagged_total_value) parts.push(`${this.formatCurrency(metrics.flagged_total_value)} ${this.flaggedLabelValue}`)
    if (metrics.source_name) parts.push(metrics.source_name)

    return parts.join(" · ")
  }

  formatSharedIndividuals(value) {
    const count = Number(value || 0)
    return `${this.formatInteger(count)} ${this.sharedIndividualsLabelValue.toLowerCase()}`
  }

  nodeRadius(node, maxRiskScore) {
    if (node.node_type === "individual") return 5

    const score = this.riskScore(node)
    const scoreRatio = Math.max(0, Math.min(1, score / Math.max(maxRiskScore || 1, 1)))

    return 5 + scoreRatio * 16
  }

  riskScore(node) {
    return Number(node.metrics?.risk_total_score || node.metrics?.risk_score || 0)
  }

  nodeTypeLabel(node) {
    if (node.node_type === "individual") return this.individualLabelValue
    if (node.node_type === "public_body") return this.publicBodyLabelValue

    return this.companyLabelValue
  }

  truncateLabel(text, maxLength) {
    if (!text || text.length <= maxLength) return text

    return `${text.slice(0, maxLength - 1)}…`
  }

  formatInteger(value) {
    return this.integerFormatter.format(Number(value || 0))
  }

  formatCurrency(value) {
    return this.currencyFormatter.format(Number(value || 0))
  }

  formatConnectedEntities(labels, totalCount) {
    const list = Array.isArray(labels) ? labels : []
    if (list.length === 0) {
      return this.formatInteger(totalCount || 0)
    }

    const preview = list.slice(0, 2).join(", ")
    if (list.length <= 2) return preview

    return `${preview} +${list.length - 2}`
  }

  edgeStrokeColor(edgeType, flaggedRatio) {
    const baseColor = EDGE_COLORS[edgeType] || "#999999"
    if (!flaggedRatio || flaggedRatio <= 0) return baseColor

    return this.mixHex(baseColor, "#ff4444", Math.min(0.92, flaggedRatio * 0.9))
  }

  mixHex(startHex, endHex, amount) {
    const start = this.hexToRgb(startHex)
    const finish = this.hexToRgb(endHex)
    if (!start || !finish) return startHex

    const ratio = Math.max(0, Math.min(1, amount))
    const r = Math.round(start.r + (finish.r - start.r) * ratio)
    const g = Math.round(start.g + (finish.g - start.g) * ratio)
    const b = Math.round(start.b + (finish.b - start.b) * ratio)

    return `rgb(${r}, ${g}, ${b})`
  }

  hexToRgb(hex) {
    const normalized = String(hex || "").trim().replace("#", "")
    if (!/^[0-9a-fA-F]{6}$/.test(normalized)) return null

    return {
      r: parseInt(normalized.slice(0, 2), 16),
      g: parseInt(normalized.slice(2, 4), 16),
      b: parseInt(normalized.slice(4, 6), 16)
    }
  }

  toggleOverlay(target, visible) {
    target.classList.toggle("hidden", !visible)
    target.classList.toggle("flex", visible)
  }
}
