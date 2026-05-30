# frozen_string_literal: true

class GraphsController < ApplicationController
  def index
    @data_sources = DataSource.order(:name).all
  end
end
