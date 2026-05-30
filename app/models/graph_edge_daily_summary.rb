# frozen_string_literal: true

class GraphEdgeDailySummary < ApplicationRecord
  belongs_to :source_entity, class_name: "Entity"
  belongs_to :target_entity, class_name: "Entity"
  belongs_to :data_source, optional: true
end
