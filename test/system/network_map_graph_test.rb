require "application_system_test_case"

class NetworkMapGraphTest < ApplicationSystemTestCase
  test "network map nodes remain selectable after zoom and list closest linked nodes" do
    authority = Entity.create!(
      name: "Zoom Click Authority",
      tax_identifier: "590000101",
      country_code: "PT",
      is_public_body: true,
      is_company: false
    )
    supplier = Entity.create!(
      name: "Zoom Click Supplier",
      tax_identifier: "590000102",
      country_code: "PT",
      is_public_body: false,
      is_company: true
    )
    contract = Contract.create!(
      external_id: "zoom-click-contract",
      country_code: "PT",
      object: "Zoom click contract",
      contracting_entity: authority,
      publication_date: Date.new(2042, 4, 10),
      celebration_date: Date.new(2042, 4, 11),
      base_price: 1_200
    )
    ContractWinner.create!(contract: contract, entity: supplier, price_share: 1_200)
    person = Person.create!(name: "Zoom Shared Person", tax_identifier: "590000199", country_code: "PT")
    EntityPersonRole.create!(
      entity: authority,
      person: person,
      role_type: "manager",
      role_label: "Manager",
      source_name: "Registo Comercial",
      active: true
    )
    EntityPersonRole.create!(
      entity: supplier,
      person: person,
      role_type: "director",
      role_label: "Director",
      source_name: "Registo Comercial",
      active: true
    )

    visit graph_url

    dates = all("input[type='date']")
    dates[0].fill_in(with: "2042-04-01")
    dates[1].fill_in(with: "2042-04-30")
    click_button "Apply"

    assert_selector "[data-network-map-graph-target='closestNodes']", text: supplier.name
    assert_text "Contract relation"
    assert_text "1 contracts"
    assert_text "1 shared individuals"

    initial_scale = page.evaluate_script(<<~JS)
      (() => {
        const transform = document.querySelector("[data-network-map-graph-target='canvas'] svg g")
          .getAttribute("transform");
        return transform.match(/matrix\\(([^,]+)/)[1];
      })()
    JS
    initial_radius = page.evaluate_script(<<~JS)
      document.querySelector("[data-network-map-graph-target='canvas'] svg circle").getAttribute("r")
    JS
    find("button[aria-label='Zoom In']").click
    zoomed_scale = page.evaluate_script(<<~JS)
      (() => {
        const transform = document.querySelector("[data-network-map-graph-target='canvas'] svg g")
          .getAttribute("transform");
        return transform.match(/matrix\\(([^,]+)/)[1];
      })()
    JS
    zoomed_radius = page.evaluate_script(<<~JS)
      document.querySelector("[data-network-map-graph-target='canvas'] svg circle").getAttribute("r")
    JS
    assert_operator zoomed_scale.to_f, :>, initial_scale.to_f
    assert_operator zoomed_radius.to_f, :<, initial_radius.to_f

    page.execute_script(<<~JS, supplier.name)
      const supplierName = arguments[0];
      const svg = document.querySelector("[data-network-map-graph-target='canvas'] svg");
      const circle = Array.from(svg.querySelectorAll("circle")).find((candidate) => {
        return candidate.querySelector("title")?.textContent?.includes(supplierName);
      });
      const rect = circle.getBoundingClientRect();
      const event = new MouseEvent("click", {
        bubbles: true,
        clientX: rect.left + rect.width / 2,
        clientY: rect.top + rect.height / 2
      });
      svg.dispatchEvent(event);
    JS

    assert_selector "[data-network-map-graph-target='selectedName']", text: supplier.name
    assert_selector "[data-network-map-graph-target='closestNodes']", text: authority.name
  end
end
