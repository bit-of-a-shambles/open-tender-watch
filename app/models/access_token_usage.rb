# frozen_string_literal: true

class AccessTokenUsage < ApplicationRecord
  belongs_to :access_token

  validates :path, presence: true
end
