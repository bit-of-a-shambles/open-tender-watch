# frozen_string_literal: true

require "test_helper"

class GraphsControllerTest < ActionDispatch::IntegrationTest
  test "graph page renders successfully" do
    get graph_url

    assert_response :success
    assert_includes response.body, I18n.t("graphs.title")
    assert_includes response.body, "data-controller=\"network-map-graph\""
    assert_includes response.body, "data-network-map-graph-default-include-individuals-value=\"false\""
    assert_includes response.body, "data-action=\"click->network-map-graph#resetView\""
    assert_includes response.body, "data-action=\"click->network-map-graph#zoomOut\""
    assert_includes response.body, "data-action=\"click->network-map-graph#zoomIn\""
    assert_includes response.body, "data-network-map-graph-target=\"selectedNodeLink\""
    assert_includes response.body, "data-network-map-graph-shared-individuals-label-value"
    assert_includes response.body, "data-network-map-graph-entity-path-template-value"
    assert_includes response.body, "data-network-map-graph-company-path-template-value"
    assert_operator response.body.index("data-network-map-graph-target=\"selectedName\""),
      :<,
      response.body.index("data-network-map-graph-target=\"closestNodes\"")
    refute_includes response.body, "name=\"entity_id\""
    refute_includes response.body, I18n.t("graph.include_individuals")
    refute_includes response.body, I18n.t("graph.legend_individual")
  end

  test "graph page renders individual toggle for authenticated users" do
    post access_token_url, params: { token: access_tokens(:one).token }

    get graph_url

    assert_response :success
    assert_includes response.body, "data-network-map-graph-default-include-individuals-value=\"false\""
    assert_includes response.body, I18n.t("graph.include_individuals")
    assert_includes response.body, I18n.t("graph.legend_individual")
  end

  test "graph page serializes include_individuals default as boolean string" do
    get graph_url

    assert_response :success
    assert_match(/data-network-map-graph-default-include-individuals-value=\"(true|false)\"/, response.body)
    assert_includes response.body, "data-network-map-graph-yes-label-value=\"#{I18n.t('graph.yes')}\""
    assert_includes response.body, "data-network-map-graph-no-label-value=\"#{I18n.t('graph.no')}\""
    refute_includes response.body, "Yes\" data-entity-network-graph-no-label-value"
  end

  test "dashboard includes graph page link" do
    get dashboard_index_url

    assert_response :success
    assert_includes response.body, I18n.t("nav.graph")
    assert_includes response.body, graph_path
  end
end
