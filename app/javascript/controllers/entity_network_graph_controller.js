import { Controller } from "@hotwired/stimulus"

const EDGE_COLORS = {
  awarded_by_focus: "#ff8844",
  awarded_to_focus: "#44b7ff",
  bidirectional_award: "#c8a84e",
  peer_award_link: "#6ad7a8",
  entity_role_link: "#a6b0bf"
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
    "selectedName",
    "selectedType",
    "selectedContracts",
    "selectedValue",
    "selectedRelation",
    "selectedOutgoing",
    "selectedIncoming",
    "selectedEntities",
    "selectedFlagged",
    "selectedRiskScore",
    "dateFrom",
    "dateTo",
    "limit",
    "includeIndividuals"
  ]

  static values = {
    endpoint: String,
    defaultLimit: Number,
    defaultIncludeIndividuals: String,
    publicBodyLabel: String,
    companyLabel: String,
    individualLabel: String,
    focusLabel: String,
    edgeFromFocusLabel: String,
    edgeToFocusLabel: String,
    edgeBidirectionalLabel: String,
    edgePeerAwardLabel: String,
    edgeEntityRoleLabel: String,
    yesLabel: String,
    noLabel: String,
    errorLabel: String
  }

  connect() {
    this.graphData = null
    this.selectedNodeId = null
    this.abortController = null
    this.resizeTimer = null
    this.currencyFormatter = new Intl.NumberFormat(undefined, {
      style: "currency",
      currency: "EUR",
      maximumFractionDigits: 0
    })
    this.integerFormatter = new Intl.NumberFormat(undefined)

    this.boundResize = this.handleResize.bind(this)
    window.addEventListener("resize", this.boundResize)

    if (this.hasIncludeIndividualsTarget) {
      this.includeIndividualsTarget.checked = this.defaultIncludeIndividualsEnabled()
    }

    this.loadGraph()
  }

  disconnect() {
    window.removeEventListener("resize", this.boundResize)
    clearTimeout(this.resizeTimer)
    this.abortPendingRequest()
  }

  async applyFilters(event) {
    event.preventDefault()
    await this.loadGraph()
  }

  async resetFilters(event) {
    event.preventDefault()

    if (this.hasDateFromTarget) this.dateFromTarget.value = ""
    if (this.hasDateToTarget) this.dateToTarget.value = ""
    if (this.hasLimitTarget) this.limitTarget.value = this.defaultLimitValue || 50
    if (this.hasIncludeIndividualsTarget) this.includeIndividualsTarget.checked = this.defaultIncludeIndividualsEnabled()

    await this.loadGraph()
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
      const focusId = this.graphData?.meta?.focus_entity_id
      this.selectedNodeId = focusId ? `entity-${focusId}` : null
      this.renderGraph()
    } catch (error) {
      if (error.name === "AbortError") return
      this.showError(error)
    } finally {
      if (this.abortController === controller) {
        this.abortController = null
      }
    }
  }

  renderGraph() {
    const nodes = Array.isArray(this.graphData?.nodes) ? this.graphData.nodes : []
    const edges = Array.isArray(this.graphData?.edges) ? this.graphData.edges : []

    this.updateSummary(this.graphData)

    if (nodes.length <= 1 || edges.length === 0) {
      this.canvasTarget.innerHTML = ""
      this.renderSelectedDetails(null, null)
      this.showState("empty")
      return
    }

    const { width, height } = this.measureCanvas()
    const positions = this.computePositions(nodes, width, height)
    this.drawSvg(nodes, edges, positions, width, height)

    const selectedNode = this.findSelectedNode(nodes)
    const selectedEdge = this.findEdgeForNode(edges, selectedNode)

    this.renderSelectedDetails(selectedNode, selectedEdge)
    this.showState("canvas")
  }

  updateSummary(data) {
    const nodesCount = Array.isArray(data?.nodes) ? data.nodes.length : 0
    const edgesCount = Array.isArray(data?.edges) ? data.edges.length : 0
    const truncated = Boolean(data?.meta?.truncated)

    this.nodesCountTarget.textContent = this.formatInteger(nodesCount)
    this.edgesCountTarget.textContent = this.formatInteger(edgesCount)
    this.truncatedTarget.textContent = truncated ? this.yesLabelValue : this.noLabelValue
  }

  renderSelectedDetails(node, edge) {
    if (!node) {
      this.selectedNameTarget.textContent = "-"
      this.selectedTypeTarget.textContent = "-"
      this.selectedContractsTarget.textContent = "-"
      this.selectedValueTarget.textContent = "-"
      this.selectedRelationTarget.textContent = "-"
      this.selectedOutgoingTarget.textContent = "-"
      this.selectedIncomingTarget.textContent = "-"
      this.selectedEntitiesTarget.textContent = "-"
      this.selectedFlaggedTarget.textContent = "-"
      this.selectedRiskScoreTarget.textContent = "-"
      return
    }

    const nodeMetrics = node.metrics || {}
    const edgeMetrics = edge?.metrics || {}
    const isIndividual = node.node_type === "individual"

    this.selectedNameTarget.textContent = node.label || "-"
    this.selectedTypeTarget.textContent = this.nodeTypeLabel(node)

    if (isIndividual) {
      const severityBreakdown = nodeMetrics.risk_severity_breakdown || {}
      this.selectedContractsTarget.textContent = this.formatInteger(nodeMetrics.involved_contract_count || 0)
      this.selectedValueTarget.textContent = this.formatCurrency(nodeMetrics.involved_total_value || 0)
      this.selectedRelationTarget.textContent = edgeMetrics.role_label || nodeMetrics.role_label || this.edgeTypeLabel(edge?.edge_type)
      this.selectedOutgoingTarget.textContent = `H:${this.formatInteger(severityBreakdown.high || 0)} M:${this.formatInteger(severityBreakdown.medium || 0)}`
      this.selectedIncomingTarget.textContent = `C:${this.formatInteger(severityBreakdown.critical || 0)} L:${this.formatInteger(severityBreakdown.low || 0)}`
      this.selectedEntitiesTarget.textContent = this.formatConnectedEntities(nodeMetrics.connected_entity_labels, nodeMetrics.connected_entity_count)
      this.selectedFlaggedTarget.textContent = this.formatInteger(nodeMetrics.risk_flagged_contract_count || 0)
      this.selectedRiskScoreTarget.textContent = this.formatInteger(nodeMetrics.risk_total_score || 0)
      return
    }

    this.selectedContractsTarget.textContent = this.formatInteger(nodeMetrics.contract_count || 0)
    this.selectedValueTarget.textContent = this.formatCurrency(nodeMetrics.total_value || edgeMetrics.total_value || 0)
    this.selectedRelationTarget.textContent = edge ? this.edgeTypeLabel(edge.edge_type) : this.focusLabelValue
    this.selectedOutgoingTarget.textContent = this.formatInteger(edgeMetrics.outgoing_contract_count || nodeMetrics.outgoing_contract_count || 0)
    this.selectedIncomingTarget.textContent = this.formatInteger(edgeMetrics.incoming_contract_count || nodeMetrics.incoming_contract_count || 0)
    this.selectedEntitiesTarget.textContent = "-"
    this.selectedFlaggedTarget.textContent = "-"
    this.selectedRiskScoreTarget.textContent = "-"
  }

  drawSvg(nodes, edges, positions, width, height) {
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg")
    svg.setAttribute("viewBox", `0 0 ${width} ${height}`)
    svg.setAttribute("class", "w-full h-full")

    const selectedNodeId = this.selectedNodeId

    edges.forEach((edge) => {
      const source = positions[edge.source]
      const target = positions[edge.target]
      if (!source || !target) return

      const isSelected = selectedNodeId && (edge.source === selectedNodeId || edge.target === selectedNodeId)
      const contractCount = edge.metrics?.contract_count || 0
      const line = document.createElementNS("http://www.w3.org/2000/svg", "line")

      line.setAttribute("x1", source.x)
      line.setAttribute("y1", source.y)
      line.setAttribute("x2", target.x)
      line.setAttribute("y2", target.y)
      line.setAttribute("stroke", EDGE_COLORS[edge.edge_type] || "#999999")
      line.setAttribute("stroke-width", String(Math.min(6, 1 + contractCount * 0.15)))
      line.setAttribute("opacity", isSelected || !selectedNodeId ? "0.8" : "0.28")

      const title = document.createElementNS("http://www.w3.org/2000/svg", "title")
      title.textContent = `${this.edgeTypeLabel(edge.edge_type)} · ${this.formatInteger(contractCount)}`
      line.appendChild(title)

      svg.appendChild(line)
    })

    nodes.forEach((node, index) => {
      const point = positions[node.id]
      if (!point) return

      const isSelected = node.id === selectedNodeId
      const isIndividual = node.node_type === "individual"
      const radius = node.is_focus
        ? 16
        : (isIndividual ? 6 : Math.max(8, Math.min(14, 6 + (node.metrics?.contract_count || 0) * 0.3)))

      const fill = node.is_focus
        ? "#c8a84e"
        : (isIndividual ? "#a6b0bf" : (node.node_type === "public_body" ? "#44b7ff" : "#ff9f5b"))

      const circle = document.createElementNS("http://www.w3.org/2000/svg", "circle")
      circle.setAttribute("cx", point.x)
      circle.setAttribute("cy", point.y)
      circle.setAttribute("r", radius)
      circle.setAttribute("fill", fill)
      circle.setAttribute("stroke", isSelected ? "#ffffff" : "rgba(255,255,255,0.25)")
      circle.setAttribute("stroke-width", isSelected ? "2.5" : "1")
      circle.setAttribute("class", "cursor-pointer")

      circle.addEventListener("click", () => this.selectNode(node.id))

      const title = document.createElementNS("http://www.w3.org/2000/svg", "title")
      title.textContent = `${node.label} · ${this.formatInteger(node.metrics?.contract_count || 0)}`
      circle.appendChild(title)

      svg.appendChild(circle)

      if (node.is_focus || (!isIndividual && index <= 12)) {
        const label = document.createElementNS("http://www.w3.org/2000/svg", "text")
        label.setAttribute("x", point.x + (node.is_focus ? radius + 8 : 10))
        label.setAttribute("y", point.y + 4)
        label.setAttribute("fill", node.is_focus ? "#e8e0d4" : "rgba(232,224,212,0.78)")
        label.setAttribute("font-size", node.is_focus ? "12" : "10")
        label.setAttribute("font-family", "ui-monospace, SFMono-Regular, Menlo, monospace")
        label.textContent = this.truncateLabel(node.label, node.is_focus ? 28 : 18)
        svg.appendChild(label)
      }
    })

    this.canvasTarget.innerHTML = ""
    this.canvasTarget.appendChild(svg)
  }

  selectNode(nodeId) {
    this.selectedNodeId = nodeId
    this.renderGraph()
  }

  findSelectedNode(nodes) {
    if (!this.selectedNodeId) {
      return nodes.find((node) => node.is_focus) || nodes[0]
    }

    return nodes.find((node) => node.id === this.selectedNodeId) || nodes.find((node) => node.is_focus) || nodes[0]
  }

  findEdgeForNode(edges, node) {
    if (!node || node.is_focus) return null

    return edges.find((edge) => edge.source === node.id || edge.target === node.id) || null
  }

  computePositions(nodes, width, height) {
    const positions = {}
    const focusNode = nodes.find((node) => node.is_focus) || nodes[0]
    const neighbors = nodes
      .filter((node) => node.id !== focusNode.id)
      .sort((a, b) => (b.metrics?.contract_count || 0) - (a.metrics?.contract_count || 0))

    const centerX = width / 2
    const centerY = height / 2
    const radius = Math.max(95, Math.min(width, height) * 0.34)

    positions[focusNode.id] = { x: centerX, y: centerY }

    neighbors.forEach((node, index) => {
      const angle = (index / Math.max(neighbors.length, 1)) * Math.PI * 2 - Math.PI / 2
      positions[node.id] = {
        x: centerX + radius * Math.cos(angle),
        y: centerY + radius * Math.sin(angle)
      }
    })

    return positions
  }

  measureCanvas() {
    const rect = this.canvasTarget.getBoundingClientRect()

    return {
      width: Math.max(320, Math.floor(rect.width || 680)),
      height: 430
    }
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

    if (this.hasIncludeIndividualsTarget && this.includeIndividualsTarget.checked) {
      url.searchParams.set("include_individuals", "true")
    }

    return url.toString()
  }

  defaultIncludeIndividualsEnabled() {
    const raw = this.defaultIncludeIndividualsValue || this.element.getAttribute("data-entity-network-graph-default-include-individuals-value")
    return this.truthy(raw)
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
    this.renderSelectedDetails(null, null)
    this.errorTarget.textContent = this.errorLabelValue
    this.showState("error")
    this.updateSummary(null)
  }

  edgeTypeLabel(edgeType) {
    if (edgeType === "awarded_by_focus") return this.edgeFromFocusLabelValue
    if (edgeType === "awarded_to_focus") return this.edgeToFocusLabelValue
    if (edgeType === "bidirectional_award") return this.edgeBidirectionalLabelValue
    if (edgeType === "peer_award_link") return this.edgePeerAwardLabelValue
    if (edgeType === "entity_role_link") return this.edgeEntityRoleLabelValue

    return edgeType
  }

  nodeTypeLabel(node) {
    if (node.is_focus) return this.focusLabelValue
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

  toggleOverlay(target, visible) {
    target.classList.toggle("hidden", !visible)
    target.classList.toggle("flex", visible)
  }
}
