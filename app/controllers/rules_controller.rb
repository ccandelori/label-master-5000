# frozen_string_literal: true

class RulesController < ApplicationController
  def index
    @area = :rules
    @shared = Rules::Data.shared
    @commodities = Rules::Data::COMMODITIES.index_with { |c| Rules::Data.for(c) }
  end
end
