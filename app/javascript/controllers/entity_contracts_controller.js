import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    this.observer = new MutationObserver(() => this.sync())
    this.observer.observe(this.element, {
      attributes: true,
      attributeFilter: ["busy"]
    })

    this.sync()
  }

  disconnect() {
    this.observer?.disconnect()
  }

  sync() {
    const isBusy = this.element.hasAttribute("busy")

    this.element.classList.toggle("opacity-60", isBusy)
    this.element.classList.toggle("pointer-events-none", isBusy)
  }
}
